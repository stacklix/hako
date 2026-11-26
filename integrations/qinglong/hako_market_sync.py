#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Hako 行情同步（Python 3.10+，仅标准库；Linux 需有时区数据库）
cron: 0 */5 * * * *
new Env('Hako 行情同步');

必填：HAKO_URL、HAKO_CLIENT_ID、HAKO_CLIENT_SECRET
美股另填：TWELVE_DATA_API_KEY。详细用法见同目录 README.md。
"""

import argparse
import csv
import io
import json
import os
import re
import socket
import ssl
import sys
import tempfile
import time
from contextlib import contextmanager
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP, localcontext
from hashlib import sha256
from http.client import HTTPException, RemoteDisconnected
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

UTC = timezone.utc
DAY = timedelta(days=1)
BODY_LIMIT = 15_000  # Hako currently limits these request bodies to 16 KiB.


class SyncError(Exception):
    """Only sanitized messages belong here; never include a URL or response body."""


class ProviderDeferred(SyncError):
    """A provider domain is temporarily paused; other providers can continue."""


def transport_failure(error):
    # Exception text may contain a URL, query or credentials. Emit only fixed hints,
    # exception type and numeric system codes, never str(error) or str(reason).
    cause = error.reason if isinstance(error, URLError) else error
    if isinstance(cause, socket.gaierror):
        hint = 'DNS 解析失败'
    elif isinstance(cause, ssl.SSLError):
        hint = 'TLS 连接或证书校验失败'
    elif isinstance(cause, TimeoutError):
        hint = '连接或读取超时'
    elif isinstance(cause, (RemoteDisconnected, ConnectionResetError, BrokenPipeError)):
        hint = '连接被对端断开，未取得完整响应'
    elif isinstance(cause, HTTPException):
        hint = 'HTTP 响应传输不完整或格式异常'
    else:
        hint = '网络连接失败'
    code = getattr(cause, 'errno', None)
    system = f'，系统码 {code}' if isinstance(code, int) else ''
    return f'{hint}（{type(cause).__name__}{system}）'


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # Never forward Hako or provider credentials to a redirect.


def log(message):
    print(time.strftime('%H:%M:%S'), message, flush=True)


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode('utf-8')


def number(value):
    try:
        result = Decimal(str(value))
        if not result.is_finite() or result <= 0:
            raise ValueError()
        return result
    except (InvalidOperation, ValueError):
        raise SyncError('行情源返回无效或非正数价格') from None


def price(value):
    # The wire protocol permits four decimal places. Round explicitly, not via float.
    try:
        with localcontext() as ctx:
            ctx.prec = 50
            rounded = number(value).quantize(Decimal('0.0001'), rounding=ROUND_HALF_UP)
        if rounded <= 0:
            raise SyncError('价格低于接口四位小数精度，未写入零值')
        return format(rounded, 'f').rstrip('0').rstrip('.')
    except InvalidOperation:
        raise SyncError('价格超出可处理的十进制范围') from None


def stamp(value=None):
    return (value or datetime.now(UTC)).astimezone(UTC).isoformat(timespec='seconds').replace('+00:00', 'Z')


def day_start(value, zone=UTC):
    return datetime.combine(date.fromisoformat(value), datetime.min.time(), tzinfo=zone)


def observation(day, value, observed=None):
    date.fromisoformat(day)
    return {'date': day, 'value': price(value), 'observedAt': stamp(observed)}


def bounded_env(name, default, low, high):
    try:
        value = int(os.getenv(name, str(default)))
        if low <= value <= high:
            return value
    except ValueError:
        pass
    raise SyncError(f'{name} 必须为 {low}–{high} 的整数')


class HTTP:
    def __init__(self, deadline, timeout=25):
        proxies = ProxyHandler() if os.getenv('HAKO_MARKET_USE_PROXY') == '1' else ProxyHandler({})
        self.opener = build_opener(proxies, NoRedirect())
        self.deadline, self.timeout = deadline, timeout
        self.next_request = {}
        self.blocked_hosts = {}

    def request(self, label, url, *, query=None, body=None, headers=None, json_result=True):
        host = urlsplit(url).hostname or ''
        blocked = self.blocked_hosts.get(host, 0) - time.monotonic()
        if blocked > 0:
            raise ProviderDeferred(f'{label} {host} 连接异常，暂停该域名，约 {int(blocked) + 1} 秒后可重试')
        if query:
            url += '?' + urlencode(query)
        intervals = {'hako': 0.6, 'twelve': 8.0, 'tushare': 1.3, 'eastmoney': 0.4, 'binance': 0.25, 'ecb': 0.4}
        payload = None if body is None else encode(body)
        request_headers = {'User-Agent': 'HakoMarketSync/1.0', 'Accept': 'application/json', **(headers or {})}
        if payload is not None:
            request_headers['Content-Type'] = 'application/json'
        for attempt in range(3):
            wait = max(0, self.next_request.get(label, 0) - time.monotonic())
            if time.monotonic() + wait + 1 >= self.deadline:
                raise SyncError('本次运行达到时间上限，剩余任务留到下次执行')
            if wait:
                time.sleep(wait)
            self.next_request[label] = time.monotonic() + intervals.get(label, 0.5)
            started = time.monotonic()
            try:
                request = Request(url, data=payload, headers=request_headers)
                timeout = max(1, min(self.timeout, self.deadline - time.monotonic()))
                with self.opener.open(request, timeout=timeout) as response:
                    data = response.read(16 * 1024 * 1024 + 1)
                    if len(data) > 16 * 1024 * 1024:
                        raise SyncError(f'{label} 响应过大')
                if not json_result:
                    return data.decode('utf-8-sig')
                return json.loads(data, parse_float=Decimal)
            except HTTPError as error:
                status = error.code
                retry_after = error.headers.get('Retry-After', '')
                if label == 'twelve' and status == 400:
                    # Documented "no data on specified dates" is a business
                    # response. The provider validates its exact code and symbol.
                    try:
                        data = error.read(64 * 1024)
                        result = json.loads(data, parse_float=Decimal)
                        if isinstance(result, dict) and result.get('code') == 400:
                            return result
                    except (ValueError, OSError):
                        pass
                    finally:
                        error.close()
                error.close()
                if attempt < 2 and (status == 429 or status >= 500):
                    seconds = max(60 if status == 429 else 2 ** attempt,
                                  int(retry_after) if retry_after.isdigit() else 0)
                    self.next_request[label] = time.monotonic() + seconds
                    log(f'{label} HTTP {status}，稍后重试')
                    continue
                hint = {401: '凭据无效', 403: '权限不足或来源访问受限', 404: '接口未部署或标的不存在',
                        413: '请求正文超限', 429: '请求频率超限'}.get(status, '请求失败')
                raise SyncError(f'{label} HTTP {status}：{hint}') from None
            except (URLError, TimeoutError, OSError, HTTPException) as error:
                reason = transport_failure(error)
                elapsed = time.monotonic() - started
                if attempt < 2:
                    seconds = 2 ** attempt
                    self.next_request[label] = time.monotonic() + seconds
                    log(f'{label} {host} 第 {attempt + 1}/3 次请求失败，耗时 {elapsed:.2f} 秒：{reason}；{seconds} 秒后重试')
                    continue
                pause = ''
                if label == 'eastmoney':
                    self.blocked_hosts[host] = time.monotonic() + 60
                    pause = '；该域名暂停 60 秒，其余标的延后处理'
                raise SyncError(f'{label} {host} 3 次请求均失败：{reason}{pause}') from None
            except (ValueError, UnicodeError):
                raise SyncError(f'{label} 响应格式无效') from None


class Providers:
    def __init__(self, http, twelve_key='', tushare_token=''):
        self.http, self.twelve_key, self.tushare_token = http, twelve_key, tushare_token
        self.cache = {}

    def fetch(self, target):
        if target['kind'] == 'fx':
            return self.fx(target)
        market = target.get('exchange', '').upper()
        symbol = target.get('symbol', '').upper()
        if market in ('BINANCE',):
            return self.crypto(target)
        if target.get('priceType') == 'nav' and symbol.endswith('.OF'):
            return self.fund(target)
        if target.get('currency') == 'CNY' and market not in ('HK_CONNECT', 'XHKG', 'HKEX', 'HK'):
            base, _, suffix = symbol.partition('.')
            if re.fullmatch(r'\d{6}', base) and (suffix or market) in ('SH', 'SZ', 'BJ', 'SSE', 'SZSE', 'BSE', 'XSHG', 'XSHE', 'XBSE'):
                return self.tushare(target)
        if target.get('currency') == 'CNY' or market in ('HK_CONNECT', 'XHKG', 'HKEX', 'HK'):
            return self.eastmoney(target)
        us_markets = {'US', 'NASDAQ', 'NYSE', 'AMEX', 'XNAS', 'XNYS', 'XASE', 'ARCX', 'BATS',
                      'BATY', 'EDGA', 'EDGX', 'XNGS', 'XNMS', 'XNCM', 'XOTC', 'OTCM', 'IEXG', 'MEMX'}
        if target.get('currency') == 'USD' and market in us_markets:
            return self.twelve(target)
        raise SyncError('该标的尚无匹配的行情源，未写入数据')

    def tushare(self, target):
        if not self.tushare_token:
            raise SyncError('A 股和场内 ETF 需要配置 TUSHARE_TOKEN')
        kind = target.get('assetType')
        if kind not in ('stock', 'etf'):
            raise SyncError('Tushare 股票/ETF 任务缺少明确的 assetType，请更新 Hako 服务端')
        base, _, suffix = target['symbol'].upper().partition('.')
        aliases = {'XSHG': 'SH', 'SSE': 'SH', 'XSHE': 'SZ', 'SZSE': 'SZ', 'XBSE': 'BJ', 'BSE': 'BJ'}
        venue = aliases.get(suffix or target.get('exchange', '').upper(), suffix or target.get('exchange', '').upper())
        if not re.fullmatch(r'\d{6}', base) or venue not in ('SH', 'SZ', 'BJ'):
            raise SyncError('Tushare 标的代码或交易所无效')
        symbol = base + '.' + venue
        latest = target['kind'] == 'latest'
        api = ('rt_etf_k' if kind == 'etf' else 'rt_k') if latest else ('fund_daily' if kind == 'etf' else 'daily')
        params = {'ts_code': symbol}
        if not latest:
            params.update(start_date=target['fromDate'].replace('-', ''), end_date=target['throughDate'].replace('-', ''))
        date_field = 'trade_time' if latest else 'trade_date'
        fields = ['ts_code', date_field, 'close']
        payload = self.http.request('tushare', 'https://api.tushare.pro/',
            body={'api_name': api, 'token': self.tushare_token, 'params': params, 'fields': ','.join(fields)})
        if not isinstance(payload, dict) or payload.get('code') != 0:
            code = payload.get('code') if isinstance(payload, dict) else None
            if code == 429:
                self.http.next_request['tushare'] = time.monotonic() + 60
            safe_code = str(code) if isinstance(code, int) else 'unknown'
            raise SyncError(f'Tushare {api} 业务错误，代码 {safe_code}；请检查 Token、积分及该接口权限')
        data = payload.get('data')
        if not isinstance(data, dict) or not isinstance(data.get('fields'), list) or not isinstance(data.get('items'), list):
            raise SyncError('Tushare 响应缺少字段或记录列表')
        columns, items = data['fields'], data['items']
        if not set(fields).issubset(columns) or len(set(columns)) != len(columns) or len(items) >= 6000 or (latest and len(items) > 1):
            raise SyncError('Tushare 响应字段无效或结果被截断')
        try:
            zone = ZoneInfo('Asia/Shanghai')
        except ZoneInfoNotFoundError:
            raise SyncError('缺少时区数据库，请在青龙 Python 依赖中安装 tzdata') from None
        rows = []
        for item in items:
            if not isinstance(item, list) or len(item) != len(columns):
                raise SyncError('Tushare 行情记录格式无效')
            row = dict(zip(columns, item))
            if row['ts_code'] != symbol:
                raise SyncError('Tushare 返回了其他标的，未写入数据')
            if latest:
                try:
                    published = datetime.fromisoformat(str(row[date_field]))
                except ValueError:
                    raise SyncError('Tushare 实时行情缺少有效的实际报价时间') from None
                published = published.replace(tzinfo=zone) if published.tzinfo is None else published.astimezone(zone)
                day = published.date().isoformat()
                if not self.within(target, day):
                    continue
                if published > datetime.now(UTC) + timedelta(minutes=5):
                    raise SyncError('Tushare 实际报价时间在未来')
            else:
                raw = row[date_field]
                if not isinstance(raw, str) or not re.fullmatch(r'\d{8}', raw):
                    raise SyncError('Tushare 交易日期无效')
                day = datetime.strptime(raw, '%Y%m%d').date().isoformat()
                if not self.within(target, day):
                    raise SyncError('Tushare 返回了查询范围外的日期')
                published = day_start(day, zone) + timedelta(hours=15)
            rows.append(observation(day, row['close'], published))
        return sorted(rows, key=lambda row: row['date']), not latest

    @staticmethod
    def within(target, day):
        return target['fromDate'] <= day <= target['throughDate']

    @staticmethod
    def secid(target):
        symbol, market = target['symbol'].upper(), target.get('exchange', '').upper()
        base, _, suffix = symbol.partition('.')
        aliases = {'XSHG': 'SH', 'XSHE': 'SZ', 'XBSE': 'BJ', 'SHFE': 'SHF', 'CZCE': 'ZCE', 'CFFEX': 'CFX', 'GFEX': 'GFE'}
        venue = aliases.get(suffix or market, suffix or market)
        if market in ('HK_CONNECT', 'XHKG', 'HKEX', 'HK'):
            if re.fullmatch(r'\d{1,5}', base):
                return '116.' + base.zfill(5), False
            raise SyncError('港股代码格式无效')
        if venue in ('SH', 'SZ', 'BJ') and re.fullmatch(r'\d{6}', base):
            return {'SH': '1.', 'SZ': '0.', 'BJ': '0.'}[venue] + base, False
        venues = {'SHF': '113', 'DCE': '114', 'ZCE': '115', 'CFX': '220', 'INE': '142', 'GFE': '225'}
        if venue in venues and re.fullmatch(r'[A-Z]+\d{3,4}', base):
            prefix, digits = re.fullmatch(r'([A-Z]+)(\d{3,4})', base).groups()
            if venue == 'ZCE' and len(digits) == 4:
                digits = digits[1:]
            if venue in ('SHF', 'DCE', 'INE', 'GFE'):
                prefix = prefix.lower()
            return venues[venue] + '.' + prefix + digits, True
        raise SyncError('国内标的需要明确的交易所代码；此脚本暂不采集期权')

    def eastmoney(self, target):
        secid, future = self.secid(target)
        query = {'secid': secid, 'klt': 101, 'fqt': 0, 'lmt': 10000,
                 'beg': target['fromDate'].replace('-', ''), 'end': target['throughDate'].replace('-', ''),
                 'fields1': 'f1,f2,f3,f4,f5,f6', 'fields2': 'f51,f52,f53,f54,f55,f56'}
        if future:
            query.update(iscca=1, forcect=1)
        payload = self.http.request('eastmoney', 'https://push2his.eastmoney.com/api/qt/stock/kline/get',
                                    query=query, headers={'Referer': 'https://quote.eastmoney.com/'})
        data = payload.get('data') or {}
        normalize = lambda value: str(value).replace('-', '').upper()
        if payload.get('rc') != 0 or normalize(data.get('code')) != normalize(secid.split('.')[1]) or str(data.get('market')) != secid.split('.')[0]:
            raise SyncError('东方财富标的校验失败或暂不可用')
        bars = data.get('klines')
        if not isinstance(bars, list) or len(bars) >= 10000:
            raise SyncError('东方财富日线字段缺失或结果被截断')
        rows = []
        for bar in bars:
            fields = bar.split(',')
            if len(fields) < 3:
                raise SyncError('东方财富日线格式无效')
            if self.within(target, fields[0]):
                rows.append(observation(fields[0], fields[2]))
        return rows, target['kind'] != 'latest'

    def fund(self, target):
        code = target['symbol'].upper().removesuffix('.OF')
        if not re.fullmatch(r'\d{6}', code):
            raise SyncError('基金代码格式无效')
        rows, count, previous = [], 0, None
        for page in range(1, 101):
            payload = self.http.request('eastmoney', 'https://api.fund.eastmoney.com/f10/lsjz',
                query={'fundCode': code, 'pageIndex': page, 'pageSize': 100,
                       'startDate': target['fromDate'], 'endDate': target['throughDate']},
                headers={'Referer': 'https://fundf10.eastmoney.com/'})
            data = payload.get('Data') or {}
            if payload.get('ErrCode') != 0 or str(data.get('FundType')) == '005' or '万份' in str(data.get('SYType', '')):
                raise SyncError('基金净值不可用或返回了每万份收益，未作为净值写入')
            bars = data.get('LSJZList')
            if not isinstance(bars, list):
                raise SyncError('基金净值响应缺少列表')
            if payload.get('PageIndex') is not None and int(payload['PageIndex']) != page:
                raise SyncError('基金分页编号不匹配')
            if bars and bars[0].get('FSRQ') == previous:
                raise SyncError('基金分页未前进')
            previous = bars[0].get('FSRQ') if bars else previous
            for bar in bars:
                if self.within(target, bar['FSRQ']):
                    rows.append(observation(bar['FSRQ'], bar['DWJZ']))
            count += len(bars)
            if not bars or len(bars) < 100 or (payload.get('TotalCount') is not None and count >= int(payload['TotalCount'])):
                return rows, target['kind'] != 'latest'
        raise SyncError('基金净值分页超过上限')

    def twelve(self, target):
        if not self.twelve_key:
            raise SyncError('美股需要配置 TWELVE_DATA_API_KEY')
        symbol = target['symbol'].upper().removesuffix('.US')
        market = target.get('exchange', '').upper()
        query = {'symbol': symbol, 'apikey': self.twelve_key, 'country': 'United States'}
        if market in ('XNAS', 'NASDAQ'):
            query['exchange'] = 'NASDAQ'
        elif market and market != 'US':
            query['mic_code'] = {'NYSE': 'XNYS', 'AMEX': 'XASE'}.get(market, market)
        latest = target['kind'] == 'latest'
        if not latest:
            query.update(interval='1day', start_date=target['fromDate'], end_date=target['throughDate'],
                         outputsize=5000, adjust='none')
        payload = self.http.request('twelve', 'https://api.twelvedata.com/' + ('quote' if latest else 'time_series'), query=query)
        if (payload.get('code') == 400 and payload.get('meta', {}).get('symbol', '').upper() == symbol
                and str(payload.get('message', '')).startswith('No data is available on the specified dates.')):
            return [], not latest
        if payload.get('status') == 'error' or payload.get('code'):
            if str(payload.get('code')) == '429':
                self.http.next_request['twelve'] = time.monotonic() + 60
            # Raw provider errors can contain the API key, so print only the code.
            code = str(payload.get('code', 'unknown'))
            raise SyncError('Twelve Data 业务错误，代码 ' + (code if code.isdigit() and len(code) <= 8 else 'unknown'))
        meta = payload if latest else payload.get('meta', {})
        expected = {'XNAS', 'XNMS', 'XNGS', 'XNCM'} if market in ('XNAS', 'NASDAQ') else {query.get('mic_code')}
        if meta.get('symbol', '').upper() != symbol or meta.get('currency', '').upper() != target['currency'].upper():
            raise SyncError('Twelve Data 标的或币种不匹配')
        if market and market != 'US' and meta.get('mic_code', '').upper() not in expected:
            raise SyncError('Twelve Data 交易所不匹配')
        if latest:
            day = str(payload.get('datetime', ''))[:10]
            if not self.within(target, day):
                return [], False  # Never label the prior session as today's quote.
            raw_time = payload.get('last_quote_at')
            if not raw_time:
                raise SyncError('Twelve Data 最新报价缺少实际报价时间')
            return [observation(day, payload['close'], datetime.fromtimestamp(int(raw_time), UTC))], False
        bars = payload.get('values')
        if not isinstance(bars, list) or len(bars) >= 5000:
            raise SyncError('Twelve Data 历史数据缺失或被截断')
        return [observation(bar['datetime'][:10], bar['close']) for bar in bars
                if self.within(target, bar['datetime'][:10])], True

    def crypto(self, target):
        if target.get('currency') != 'USD':
            raise SyncError('当前加密资产采集只支持美元估值')
        code = target['symbol'].upper()
        if code.endswith('USDT') and code != 'USDT':
            code = code[:-4]
        if not re.fullmatch(r'[A-Z0-9]{1,20}', code):
            raise SyncError('加密资产代码格式无效')
        latest = target['kind'] == 'latest'
        if code == 'USDT':
            start, end = day_start(target['fromDate']), day_start(target['throughDate'])
            last = day_start(datetime.now(UTC).date().isoformat())
            if not latest:
                last -= DAY
            rows = []
            while start <= min(end, last):
                rows.append(observation(start.date().isoformat(), '1'))
                start += DAY
            return rows, not latest
        if latest:
            if target['throughDate'] != datetime.now(UTC).date().isoformat():
                return [], False
            pair = code + 'USDT'
            data = self.http.request('binance', 'https://data-api.binance.vision/api/v3/ticker/price', query={'symbol': pair})
            if data.get('symbol') != pair:
                raise SyncError('Binance 交易对不匹配')
            return [observation(target['throughDate'], data['price'])], False
        data = self.http.request('binance', 'https://data-api.binance.vision/api/v3/klines',
            query={'symbol': code + 'USDT', 'interval': '1d', 'timeZone': '0', 'limit': 1000,
                   'startTime': int(day_start(target['fromDate']).timestamp() * 1000),
                   'endTime': int((day_start(target['throughDate']) + DAY).timestamp() * 1000) - 1})
        if not isinstance(data, list) or len(data) >= 1000:
            raise SyncError('Binance 日线数据无效或被截断')
        rows = []
        for bar in data:
            opening = datetime.fromtimestamp(int(bar[0]) / 1000, UTC)
            day = opening.date().isoformat()
            if opening.time() != datetime.min.time() or not self.within(target, day):
                raise SyncError('Binance 日线日期无效')
            if int(bar[6]) >= int(datetime.now(UTC).timestamp() * 1000):
                continue
            rows.append(observation(day, bar[4]))
        return sorted(rows, key=lambda row: row['date']), True

    def fx(self, target):
        base, quote = target['baseCurrency'], target['quoteCurrency']
        codes = sorted({base, quote} - {'EUR'})
        key = ('fx', tuple(codes), target['fromDate'], target['throughDate'])
        if key not in self.cache:
            text = self.http.request('ecb', 'https://data-api.ecb.europa.eu/service/data/EXR/D.' + '+'.join(codes) + '.EUR.SP00.A',
                query={'startPeriod': target['fromDate'], 'endPeriod': target['throughDate'], 'format': 'csvdata', 'detail': 'dataonly'},
                json_result=False, headers={'Accept': 'text/csv'})
            reader, values = csv.DictReader(io.StringIO(text)), {}
            if not {'CURRENCY', 'TIME_PERIOD', 'OBS_VALUE'}.issubset(reader.fieldnames or []):
                raise SyncError('ECB 汇率响应缺少必要字段')
            for row in reader:
                if row['CURRENCY'] in codes and self.within(target, row['TIME_PERIOD']):
                    values.setdefault(row['TIME_PERIOD'], {'EUR': Decimal(1)})[row['CURRENCY']] = number(row['OBS_VALUE'])
            self.cache[key] = values
        rows = []
        try:
            zone = ZoneInfo('Europe/Berlin')
        except ZoneInfoNotFoundError:
            raise SyncError('缺少时区数据库，请在青龙 Python 依赖中安装 tzdata') from None
        for day, values in sorted(self.cache[key].items()):
            if base in values and quote in values:
                published = day_start(day, zone) + timedelta(hours=16)
                rows.append(observation(day, values[quote] / values[base], published))
        return rows, True


class Hako:
    def __init__(self, http, url, client, secret):
        self.http, self.url = http, url.rstrip('/')
        parsed = urlsplit(self.url)
        if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise SyncError('HAKO_URL 必须为不含账号、查询参数的 HTTPS 地址')
        if any(c in client + secret for c in '\r\n'):
            raise SyncError('HAKO_CLIENT_ID 或 HAKO_CLIENT_SECRET 格式无效')
        self.headers = {'X-Hako-Client': client, 'Authorization': 'Bearer ' + secret}

    def call(self, path, **options):
        headers = self.headers if options.get('body') is not None else {}
        return self.http.request('hako', self.url + '/api/v1/market/' + path, headers=headers, **options)

    def targets(self):
        cursor, seen = '', set()
        while True:
            result = self.call('update-targets', query={'limit': 100, 'cursor': cursor})
            targets = result.get('targets')
            if not isinstance(targets, list):
                raise SyncError('Hako 未返回行情清单，请确认服务端已部署 0.9.0 或更新版本')
            if not cursor:
                missing = result.get('calendarRequests', [])
                labels = [f"{item['market']} {item['year']} 年" for item in missing
                          if isinstance(item, dict) and item.get('market') in ('CN_A', 'US', 'HK')
                          and isinstance(item.get('year'), int) and 1970 <= item['year'] <= 2100]
                if labels:
                    log('交易日历待更新：' + '、'.join(labels) + '；未知交易日期不会生成行情任务')
            yield targets
            cursor = result.get('nextCursor')
            if not cursor:
                return
            if cursor in seen:
                raise SyncError('Hako 清单分页没有前进')
            seen.add(cursor)

    def upload(self, target, quotes, complete):
        if not self.headers['X-Hako-Client'] or self.headers['Authorization'] == 'Bearer ':
            raise SyncError('写入行情需要配置 HAKO_CLIENT_ID 和 HAKO_CLIENT_SECRET，并开启写入权限')
        # Split around the actual encoded body size, not just the row count.
        chunks, chunk = [], []
        for row in quotes:
            trial = {'items': [{'targetId': target['targetId'], 'quotes': chunk + [row], 'complete': False}]}
            if len(encode(trial)) > BODY_LIMIT:
                if not chunk:
                    raise SyncError('单条行情或 targetId 过大')
                chunks.append(chunk)
                chunk = []
            chunk.append(row)
        if chunk or not chunks:
            chunks.append(chunk)
        written = 0
        for chunk in chunks:
            if int(target['expiresAt']) <= time.time() + 5:
                raise SyncError('行情目标已过期，已成功写入的部分保留，下次重新查询')
            # A split upload cannot claim that its last chunk contains the full range.
            body = {'items': [{'targetId': target['targetId'], 'quotes': chunk, 'complete': bool(complete and len(chunks) == 1)}]}
            if len(encode(body)) > BODY_LIMIT:
                raise SyncError('请求超过 Hako 正文上限')
            result = self.call('quote-batches', body=body)
            results = result.get('results', [])
            if len(results) != 1 or results[0].get('targetId') != target['targetId']:
                raise SyncError('Hako 写入结果无法确认；下次重试同一日期，不重复创建记录')
            item = results[0]
            if item.get('status') not in ('updated', 'unchanged'):
                # Only known error codes, never arbitrary server text.
                allowed = {'invalid_or_expired_target', 'instrument_removed', 'invalid_quote_or_precision',
                           'invalid_quote', 'too_many_quotes', 'duplicate_quote'}
                code = item.get('error')
                raise SyncError('Hako 拒绝行情：' + (code if code in allowed else 'unknown_error'))
            written += int(item.get('count', 0))
        return written


@contextmanager
def single_instance(identity):
    path = Path(tempfile.gettempdir()) / ('hako-market-' + sha256(identity.encode()).hexdigest()[:20] + '.lock')
    handle = path.open('a+b')
    try:
        if os.name == 'nt':
            import msvcrt
            handle.seek(0, 2)
            if handle.tell() == 0:
                handle.write(b'0'); handle.flush()
            handle.seek(0)
            try:
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError:
                raise SyncError('已有相同 Hako 应用的同步任务运行，本次跳过') from None
        else:
            import fcntl
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise SyncError('已有相同 Hako 应用的同步任务运行，本次跳过') from None
        yield
    finally:
        handle.close()  # The OS releases the lock; do not unlink a lock another process may have opened.


def run(hako, providers, *, check=False, dry_run=False, rounds=10):
    seen, failed, written, found, deferred = set(), 0, 0, 0, 0
    for _ in range(rounds):
        fresh = 0
        for page in hako.targets():
            for target in page:
                fingerprint = (target.get('key'), target.get('fromDate'), target.get('throughDate'))
                if fingerprint in seen:
                    continue
                seen.add(fingerprint)
                fresh += 1; found += 1
                name = target.get('symbol') or (target.get('baseCurrency', '') + '/' + target.get('quoteCurrency', ''))
                start, end = target.get('fromDate'), target.get('throughDate')
                dates = start if start == end else f'{start} 至 {end}（含首尾）'
                kind = {'latest': '最新价', 'daily_close': '历史行情', 'fx': '汇率'}.get(target.get('kind'), target.get('kind'))
                label = f'{name} · {kind} · 查询日期：{dates}'
                try:
                    if target.get('kind') not in ('latest', 'daily_close', 'fx'):
                        raise SyncError('不支持的任务类型')
                    if not target.get('targetId') or int(target.get('expiresAt', 0)) <= time.time() + 5:
                        raise SyncError('任务缺少授权目标或已过期')
                    date.fromisoformat(target['fromDate']); date.fromisoformat(target['throughDate'])
                    if check:
                        log('待更新 ' + label)
                        continue
                    if target.get('priceType') == 'nav':
                        log(f'开始查询基金净值 · 基金代码：{name} · 净值日期：{dates}')
                    quotes, complete = providers.fetch(target)
                    days = [row['date'] for row in quotes]
                    if len(set(days)) != len(days) or any(not Providers.within(target, day) for day in days):
                        raise SyncError('行情返回重复或越界日期')
                    if target.get('priceType') == 'nav':
                        returned = '、'.join(sorted(days)) if days else '无'
                        log(f'基金净值查询结果 · 基金代码：{name} · 查询日期：{dates} · 数据源返回净值日期：{returned}')
                    if dry_run:
                        log(f'预演 {label}：{len(quotes)} 条，不写入')
                    elif quotes or complete:
                        count = hako.upload(target, quotes, complete)
                        written += count
                        if not quotes and target.get('priceType') == 'nav':
                            log('该查询范围未返回基金净值，稍后重查 · ' + label)
                        else:
                            log(f'完成 {label}：取得 {len(quotes)} 条，实际变更 {count} 条')
                    else:
                        log('暂无该日期已发布报价 ' + label)
                except ProviderDeferred as error:
                    deferred += 1
                    log(f'延后 {label}：{error}')
                except SyncError as error:
                    failed += 1
                    log(f'失败 {label}：{error}')
                except (KeyError, TypeError, ValueError, InvalidOperation):
                    failed += 1
                    log('失败 ' + label + '：响应字段无效，未确认的范围不标记完成')
        if not fresh or check or dry_run:
            break
    log(f'结束：检查 {found} 个目标，写入变更 {written} 条，失败 {failed} 个，延后 {deferred} 个')
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description='从 Hako 查询需求并同步行情；凭据只通过环境变量提供')
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--check', action='store_true', help='仅验证 Hako 读取权限并列出清单，不查询行情源、不写入')
    modes.add_argument('--dry-run', action='store_true', help='采集行情并验证格式，全部跳过写入')
    args = parser.parse_args()
    try:
        url = os.getenv('HAKO_URL', '').strip()
        client = os.getenv('HAKO_CLIENT_ID', '').strip()
        secret = os.getenv('HAKO_CLIENT_SECRET', '').strip()
        timeout = bounded_env('HAKO_MARKET_TIMEOUT', 25, 5, 60)
        budget = bounded_env('HAKO_MARKET_MAX_SECONDS', 600, 30, 3600)
        rounds = bounded_env('HAKO_MARKET_MAX_ROUNDS', 10, 1, 100)
        http = HTTP(time.monotonic() + budget, timeout)
        hako = Hako(http, url, client, secret)
        providers = Providers(http, os.getenv('TWELVE_DATA_API_KEY', '').strip(), os.getenv('TUSHARE_TOKEN', '').strip())
        with single_instance(hako.url + '|' + client):
            return run(hako, providers, check=args.check, dry_run=args.dry_run, rounds=rounds)
    except SyncError as error:
        log(str(error)); return 1
    except KeyboardInterrupt:
        log('已取消；已确认写入的数据保留，下次只补剩余缺口'); return 130
    except Exception:
        # Untrusted HTTP/provider exceptions may contain complete credential URLs.
        log('执行失败：环境或响应格式异常；未输出可能含密钥的异常详情'); return 1


if __name__ == '__main__':
    sys.exit(main())
