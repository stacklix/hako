import importlib.util
import io
import json
import socket
import ssl
import sys
import time
import unittest
from contextlib import redirect_stdout
from datetime import date, datetime, timedelta, timezone
from http.client import RemoteDisconnected, IncompleteRead
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError, URLError

spec = importlib.util.spec_from_file_location('hako_market_sync', Path(__file__).resolve().parents[1] / 'hako_market_sync.py')
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


def target(**extra):
    today = date.today().isoformat()
    return {'key': 'close|instrument', 'targetId': 'signed-target', 'expiresAt': int(time.time()) + 900,
            'kind': 'daily_close', 'symbol': '000001.SZ', 'exchange': '', 'currency': 'CNY',
            'priceType': 'close', 'fromDate': today, 'throughDate': today, **extra}


class FakeHTTP:
    def __init__(self, responses):
        self.responses, self.calls, self.next_request = list(responses), [], {}

    def request(self, label, url, **options):
        self.calls.append((label, url, options))
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


class MarketTests(unittest.TestCase):
    def test_log_keeps_multiline_entry_and_two_blank_lines_between_entries(self):
        output = io.StringIO()
        with patch.object(sync.time, 'strftime', return_value='16:00:00'), redirect_stdout(output):
            sync.log('完成 BTC\n报价日期：2026-11-26\n来源：Binance 现货')
            sync.log('结束')
        self.assertEqual(output.getvalue(),
            '16:00:00 完成 BTC\n报价日期：2026-11-26\n来源：Binance 现货\n\n\n16:00:00 结束\n\n\n')

    def test_quote_logs_distinguish_actual_time_from_retrieval_time(self):
        t = target(assetType='etf', symbol='159941.SZ', kind='latest',
                   fromDate='2026-11-25', throughDate='2026-11-25')
        http = FakeHTTP([{'code': 0, 'data': {'fields': ['ts_code', 'trade_time', 'close'],
                            'items': [['159941.SZ', '2026-11-25 13:05:00', '2']]}}])
        provider = sync.Providers(http, tushare_token='PRIVATE-TOKEN')
        rows, _ = provider.fetch(t)
        detail = sync.quote_log_details(t, rows, provider)
        self.assertIn('报价实际时间（UTC）：2026-11-25T05:05:00Z', detail)
        self.assertIn('来源：Tushare Pro · rt_etf_k', detail)
        self.assertIn('最终价：否（按临时报价处理）', detail)
        self.assertNotIn('PRIVATE-TOKEN', detail)
        t = target(kind='latest', symbol='BTC', exchange='BINANCE', currency='USD')
        provider = sync.Providers(FakeHTTP([{'symbol': 'BTCUSDT', 'price': '100'}]))
        rows, _ = provider.fetch(t)
        detail = sync.quote_log_details(t, rows, provider)
        self.assertIn('报价实际时间：数据源未提供', detail)
        self.assertNotIn(rows[0]['observedAt'], detail, 'Retrieval timestamp must not be presented as quote time')
        self.assertIn('来源：Binance 现货', detail)

    def test_quote_log_dates_fund_fx_and_empty_data(self):
        provider = sync.Providers(FakeHTTP([]))
        provider.quote_log_source = '测试行情源'
        rows = [sync.observation('2025-01-03', '2'), sync.observation('2025-01-02', '1')]
        t = target()
        detail = sync.quote_log_details(t, rows, provider)
        self.assertIn('报价日期：2025-01-02 至 2025-01-03', detail)
        self.assertIn('最终价：是（按日终价处理）', detail)
        self.assertNotIn('报价实际时间', detail)
        detail = sync.quote_log_details(target(priceType='nav'), rows, provider)
        self.assertIn('净值日期：2025-01-02 至 2025-01-03', detail)
        self.assertIn('状态：已发布净值', detail)
        self.assertNotIn('最终价', detail)
        detail = sync.quote_log_details(target(kind='fx'), rows, provider)
        self.assertIn('汇率日期：2025-01-02 至 2025-01-03', detail)
        self.assertIn('最终值：是（已发布中间价）', detail)
        empty = sync.quote_log_details(t, [], object())
        self.assertIn('来源：未知', empty)
        self.assertIn('状态：无返回报价', empty)
        self.assertNotIn('最终价：是', empty)

    def test_completed_quote_log_includes_metadata_and_change_count(self):
        t = target(kind='latest')
        class FakeHako:
            def targets(self): yield [t]
            def upload(self, *args): return 0
        class FakeProviders:
            quote_log_source = '测试行情源'
            quote_log_has_actual_time = True
            def fetch(self, item):
                return [sync.observation(t['fromDate'], '2', datetime(2026, 11, 25, 5, 5, tzinfo=timezone.utc))], False
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(sync.run(FakeHako(), FakeProviders()), 0)
        text = output.getvalue()
        self.assertIn('· 最新价 · 查询日期：', text)
        self.assertIn('\n来源：测试行情源\n最终价：否', text)
        self.assertIn('取得 1 条，实际变更 0 条\n\n\n', text)
        self.assertNotIn(t['targetId'], text)

    def test_tushare_routes_stock_and_etf_without_eastmoney(self):
        for kind, symbol, api in [('stock', '600000.SH', 'daily'), ('etf', '159941.SZ', 'fund_daily')]:
            with self.subTest(kind=kind):
                http = FakeHTTP([{'code': 0, 'data': {'fields': ['close', 'trade_date', 'ts_code'], 'items': [['2.34565', '20261125', symbol]]}}])
                t = target(assetType=kind, symbol=symbol, fromDate='2026-11-25', throughDate='2026-11-25')
                rows, complete = sync.Providers(http, tushare_token='PRIVATE-TOKEN').fetch(t)
                self.assertTrue(complete)
                self.assertEqual(rows[0]['value'], '2.3457')
                self.assertEqual(rows[0]['date'], '2026-11-25')
                self.assertEqual(rows[0]['observedAt'], '2026-11-25T07:00:00Z')
                label, url, options = http.calls[0]
                self.assertEqual((label, url), ('tushare', 'https://api.tushare.pro/'))
                self.assertEqual(options['body']['api_name'], api)
                self.assertEqual(options['body']['params']['ts_code'], symbol)
                self.assertNotIn('Authorization', options.get('headers', {}))

    def test_hong_kong_uses_tushare_and_preserves_dates(self):
        t = target(assetType='stock', symbol='00700.HK', exchange='HK_CONNECT', currency='HKD',
                   fromDate='2026-11-25', throughDate='2026-11-25')
        payload = {'code': 0, 'data': {'fields': ['ts_code', 'trade_date', 'close'], 'items': [['00700.HK', '20261125', 337.4]]}}
        http = FakeHTTP([payload])
        rows, complete = sync.Providers(http, tushare_token='key').fetch(t)
        self.assertTrue(complete)
        self.assertEqual(rows[0], {'date': '2026-11-25', 'value': '337.4', 'observedAt': '2026-11-25T08:00:00Z'})
        self.assertEqual(http.calls[0][2]['body']['api_name'], 'hk_daily')
        class Frozen(datetime):
            @classmethod
            def now(cls, tz=None):
                return cls(2026, 11, 25, 5, 5, tzinfo=timezone.utc)
        t['kind'] = 'latest'
        live = FakeHTTP([{'code': 0, 'data': {'fields': ['ts_code', 'close'], 'items': [['00700.HK', 341]]}}])
        with patch.object(sync, 'datetime', Frozen):
            rows, complete = sync.Providers(live, tushare_token='key').fetch(t)
        self.assertFalse(complete)
        self.assertEqual(rows[0]['observedAt'], '2026-11-25T05:05:00Z')
        self.assertEqual(live.calls[0][2]['body']['api_name'], 'rt_hk_k')
        self.assertEqual(live.calls[0][2]['body']['fields'], 'ts_code,close')
        t['kind'] = 'daily_close'
        limited = FakeHTTP([{'code': 40203}])
        with self.assertRaises(sync.ProviderDeferred):
            sync.Providers(limited, tushare_token='key').fetch(t)
        self.assertGreater(limited.next_request['tushare_hk_daily'], time.monotonic() + 59)
        t['kind'] = 'latest'
        for response in [{'code': 2002}, {'code': 0, 'data': {'fields': ['ts_code', 'close'], 'items': [['00001.HK', 1]]}}]:
            denied = FakeHTTP([response])
            with self.assertRaises(sync.SyncError):
                sync.Providers(denied, tushare_token='key').fetch(t)
            self.assertEqual(len(denied.calls), 1)

    def test_tushare_denial_and_mismatched_data_do_not_fall_back(self):
        t = target(assetType='stock', symbol='600000.SH', fromDate='2026-11-25', throughDate='2026-11-25')
        for response in [
            {'code': 2002, 'msg': 'PRIVATE-TOKEN'},
            {'code': 0, 'data': {'fields': ['ts_code', 'trade_date', 'close'], 'items': [['000001.SZ', '20261125', '1']]}},
            {'code': 0, 'data': {'fields': ['ts_code', 'trade_date', 'close'], 'items': [['600000.SH', '20261126', '1']]}},
        ]:
            http = FakeHTTP([response])
            with self.assertRaises(sync.SyncError) as failure:
                sync.Providers(http, tushare_token='PRIVATE-TOKEN').fetch(t)
            self.assertNotIn('PRIVATE-TOKEN', str(failure.exception))
            self.assertEqual(len(http.calls), 1)
        http = FakeHTTP([])
        with self.assertRaisesRegex(sync.SyncError, 'TUSHARE_TOKEN'):
            sync.Providers(http).fetch(t)
        self.assertFalse(http.calls)

    def test_tushare_realtime_keeps_actual_date_and_time(self):
        t = target(assetType='etf', symbol='159941.SZ', kind='latest', fromDate='2026-11-25', throughDate='2026-11-25')
        http = FakeHTTP([{'code': 0, 'data': {'fields': ['ts_code', 'trade_time', 'close'], 'items': [['159941.SZ', '2026-11-25 13:05:00', '2']]}}])
        rows, complete = sync.Providers(http, tushare_token='PRIVATE-TOKEN').fetch(t)
        self.assertFalse(complete)
        self.assertEqual(rows[0]['observedAt'], '2026-11-25T05:05:00Z')
        self.assertEqual(http.calls[0][2]['body']['api_name'], 'rt_etf_k')
        http.responses.append({'code': 0, 'data': {'fields': ['ts_code', 'trade_time', 'close'], 'items': [['159941.SZ', '2026-11-24 15:00:00', '2']]}})
        self.assertEqual(sync.Providers(http, tushare_token='PRIVATE-TOKEN').fetch(t), ([], False))

    def test_global_id_is_opaque_and_upload_uses_new_target_signature(self):
        t = target(instrumentId='ETF:US:QQQM:USD', key='close|ETF:US:QQQM:USD', targetId='new-signed-target')
        http = FakeHTTP([{'targets': [t], 'nextCursor': ''},
                         {'results': [{'targetId': t['targetId'], 'status': 'updated', 'count': 1}]}])
        hako = sync.Hako(http, 'https://hako.example.com', 'client', 'secret')
        self.assertEqual(list(hako.targets()), [[t]])
        self.assertEqual(hako.upload(t, [sync.observation(t['fromDate'], '100')], True), 1)
        body = http.calls[1][2]['body']
        self.assertEqual(body['items'][0]['targetId'], 'new-signed-target')
        self.assertNotIn('instrumentId', body['items'][0])
        self.assertNotIn('book_id', body['items'][0])

    def test_global_us_market_accepts_the_returned_trading_venue(self):
        t = target(instrumentId='ETF:US:QQQM:USD', symbol='QQQM', exchange='US', currency='USD',
                   fromDate='2025-01-02', throughDate='2025-01-02')
        http = FakeHTTP([{'meta': {'symbol': 'QQQM', 'currency': 'USD', 'mic_code': 'XNMS'},
                          'values': [{'datetime': '2025-01-02', 'close': '100'}]}])
        rows, complete = sync.Providers(http, 'key').fetch(t)
        self.assertTrue(complete)
        self.assertEqual(rows[0]['value'], '100')
        self.assertNotIn('mic_code', http.calls[0][2]['query'])
    def test_decimal_rounding_never_uses_binary_float_or_writes_zero(self):
        self.assertEqual(sync.price('100.0000'), '100')
        self.assertEqual(sync.price('12.34565'), '12.3457')
        self.assertEqual(sync.price('0.00005'), '0.0001')
        for value in ('0.00001', '0', '-1', 'NaN', 'Infinity', 'bad'):
            with self.subTest(value=value), self.assertRaises(sync.SyncError):
                sync.price(value)

    def test_single_upload_checks_business_status_and_keeps_complete(self):
        t = target()
        http = FakeHTTP([{'results': [{'targetId': t['targetId'], 'status': 'updated', 'count': 1}]}])
        hako = sync.Hako(http, 'https://hako.example.com', 'ak', 'sk')
        self.assertEqual(hako.upload(t, [sync.observation(t['fromDate'], '10')], True), 1)
        self.assertTrue(http.calls[0][2]['body']['items'][0]['complete'])
        http.responses.append({'results': [{'targetId': t['targetId'], 'status': 'rejected', 'error': 'invalid_or_expired_target'}]})
        with self.assertRaisesRegex(sync.SyncError, 'invalid_or_expired_target'):
            hako.upload(t, [], True)

    def test_large_history_splits_below_real_server_body_limit(self):
        class UploadHTTP(FakeHTTP):
            def request(self, label, url, **options):
                self.calls.append((label, url, options))
                item = options['body']['items'][0]
                return {'results': [{'targetId': item['targetId'], 'status': 'updated', 'count': len(item['quotes'])}]}
        t = target(targetId='a' * 1500)
        rows = [sync.observation((date(2025, 1, 1) + timedelta(days=i)).isoformat(), '123456.123456') for i in range(366)]
        http = UploadHTTP([])
        hako = sync.Hako(http, 'https://hako.example.com', 'ak', 'sk')
        self.assertEqual(hako.upload(t, rows, True), 366)
        self.assertGreater(len(http.calls), 1)
        self.assertTrue(all(len(sync.encode(call[2]['body'])) < 16384 for call in http.calls))
        self.assertTrue(all(not call[2]['body']['items'][0]['complete'] for call in http.calls))
        self.assertEqual([row for call in http.calls for row in call[2]['body']['items'][0]['quotes']], rows)

    def test_expired_targets_are_never_uploaded(self):
        hako = sync.Hako(FakeHTTP([]), 'https://hako.example.com', 'ak', 'sk')
        with self.assertRaisesRegex(sync.SyncError, '过期'):
            hako.upload(target(expiresAt=1), [], True)
        self.assertFalse(hako.http.calls)

    def test_credentials_only_go_to_hako(self):
        http = FakeHTTP([{'targets': [], 'nextCursor': ''}, {'rc': 0, 'data': {'code': '000001', 'market': 0, 'klines': []}}])
        hako = sync.Hako(http, 'https://hako.example.com/prefix/', 'hako-ak', 'hako-secret')
        list(hako.targets())
        sync.Providers(http).eastmoney(target())
        self.assertEqual(http.calls[0][1], 'https://hako.example.com/prefix/api/v1/market/update-targets')
        self.assertNotIn('Authorization', http.calls[0][2]['headers'])
        self.assertNotIn('Authorization', http.calls[1][2]['headers'])
        for url in ('http://host', 'https://ak:sk@host', 'https://host?key=x', 'https://host/#fragment'):
            with self.assertRaises(sync.SyncError):
                sync.Hako(http, url, 'ak', 'sk')

    def test_exchange_mapping_uses_explicit_venues_and_contracts(self):
        self.assertEqual(sync.Providers.secid(target()), ('0.000001', False))
        self.assertEqual(sync.Providers.secid(target(symbol='600000.SH')), ('1.600000', False))
        self.assertEqual(sync.Providers.secid(target(symbol='00700.HK', exchange='HK_CONNECT', currency='HKD')), ('116.00700', False))
        self.assertEqual(sync.Providers.secid(target(symbol='MA2609.ZCE')), ('115.MA609', True))
        self.assertEqual(sync.Providers.secid(target(symbol='CU2612.SHF')), ('113.cu2612', True))
        with self.assertRaises(sync.SyncError):
            sync.Providers.secid(target(symbol='CU2612C80000.SHF'))

    def test_eastmoney_does_not_mark_bad_or_truncated_data_complete(self):
        http = FakeHTTP([{'rc': 0, 'data': {'code': '600000', 'market': 1, 'klines': []}}])
        with self.assertRaises(sync.SyncError):
            sync.Providers(http).eastmoney(target())
        http.responses.append({'rc': 0, 'data': {'code': '000001', 'market': 0, 'klines': ['bad']}})
        with self.assertRaises(sync.SyncError):
            sync.Providers(http).eastmoney(target())

    def test_delayed_fund_nav_keeps_real_date_and_empty_response_remains_retryable(self):
        t = target(symbol='017302.OF', priceType='nav', fromDate='2026-11-23', throughDate='2026-11-25')
        http = FakeHTTP([{'ErrCode': 0, 'TotalCount': 1,
                          'Data': {'LSJZList': [{'FSRQ': '2026-11-23', 'DWJZ': '1.2345'}]}},
                         {'ErrCode': 0, 'TotalCount': 0, 'Data': {'LSJZList': []}}])
        provider = sync.Providers(http)
        rows, complete = provider.fetch(t)
        self.assertEqual([row['date'] for row in rows], ['2026-11-23'])
        self.assertTrue(complete)
        rows, complete = provider.fetch(t)
        self.assertEqual(rows, [])
        self.assertTrue(complete)  # Server only suppresses empty dates for 15 minutes.
        self.assertEqual(http.calls[0][2]['query']['endDate'], '2026-11-25')

    def test_fund_pagination_and_money_market_fund_rejection(self):
        today = date.today().isoformat()
        http = FakeHTTP([{'ErrCode': 0, 'PageIndex': 1, 'TotalCount': 1,
                          'Data': {'LSJZList': [{'FSRQ': today, 'DWJZ': '1.23456'}]}}])
        t = target(symbol='000001.OF', priceType='nav')
        rows, complete = sync.Providers(http).fetch(t)
        self.assertEqual(rows[0]['value'], '1.2346')
        self.assertTrue(complete)
        http.responses.append({'ErrCode': 0, 'Data': {'FundType': '005', 'LSJZList': []}})
        with self.assertRaises(sync.SyncError):
            sync.Providers(http).fetch(t)

    def test_twelve_never_relabels_yesterdays_quote_as_today(self):
        http = FakeHTTP([{'symbol': 'AAPL', 'currency': 'USD', 'mic_code': 'XNGS',
                          'datetime': '2025-01-01', 'close': '100', 'last_quote_at': 1}])
        t = target(symbol='AAPL', exchange='XNAS', currency='USD', kind='latest')
        self.assertEqual(sync.Providers(http, 'provider-key').fetch(t), ([], False))
        self.assertNotIn('Authorization', http.calls[0][2].get('headers', {}))
        self.assertEqual(http.calls[0][2]['query']['apikey'], 'provider-key')
        http.responses.append({'status': 'error', 'code': 429, 'message': 'SECRET-DO-NOT-PRINT'})
        with self.assertRaises(sync.SyncError) as failure:
            sync.Providers(http, 'provider-key').fetch(t)
        self.assertNotIn('SECRET', str(failure.exception))
        self.assertGreater(http.next_request['twelve'], time.monotonic() + 59)
        http.responses.append({'status': 'error', 'code': 'SECRET-IN-CODE'})
        with self.assertRaisesRegex(sync.SyncError, 'unknown') as failure:
            sync.Providers(http, 'provider-key').fetch(t)
        self.assertNotIn('SECRET', str(failure.exception))

    def test_binance_uses_usdt_parity_and_no_other_provider(self):
        http = FakeHTTP([{'symbol': 'BTCUSDT', 'price': '100'}])
        day = datetime.now(timezone.utc).date().isoformat()
        t = target(symbol='BTC', exchange='BINANCE', currency='USD', kind='latest', fromDate=day, throughDate=day)
        rows, complete = sync.Providers(http).fetch(t)
        self.assertEqual(rows[0]['value'], '100')
        self.assertEqual(len(http.calls), 1)
        self.assertTrue(all(call[0] == 'binance' for call in http.calls))
        self.assertFalse(complete)
        t['symbol'] = 'USDT'
        rows, complete = sync.Providers(http).fetch(t)
        self.assertEqual(rows[0]['value'], '1')
        self.assertEqual(len(http.calls), 1)

    def test_crypto_history_uses_completed_binance_candles_and_usdt_parity(self):
        opening = datetime(2025, 1, 1, tzinfo=timezone.utc)
        candle = [int(opening.timestamp()*1000), '0', '0', '0', '100.12345', '0', int((opening+timedelta(days=1)).timestamp()*1000)-1]
        http = FakeHTTP([[candle]])
        t = target(symbol='BTC', exchange='BINANCE', currency='USD', fromDate='2025-01-01', throughDate='2025-01-01')
        rows, complete = sync.Providers(http).fetch(t)
        self.assertEqual(rows[0]['value'], '100.1235')
        self.assertTrue(complete)
        self.assertEqual(len(http.calls), 1)
        t['symbol'] = 'USDT'
        rows, complete = sync.Providers(http).fetch(t)
        self.assertEqual(rows[0]['value'], '1')
        self.assertEqual(len(http.calls), 1)

    def test_twelve_explicit_empty_range_is_complete_but_other_errors_are_not(self):
        empty = {'code': 400, 'meta': {'symbol': 'AAPL'},
                 'message': 'No data is available on the specified dates. Please try another range.'}
        http = FakeHTTP([empty, {**empty, 'meta': {'symbol': 'OTHER'}}])
        providers = sync.Providers(http, 'key')
        t = target(symbol='AAPL', exchange='XNAS', currency='USD')
        self.assertEqual(providers.fetch(t), ([], True))
        with self.assertRaises(sync.SyncError):
            providers.fetch(t)

    def test_ambiguous_usd_asset_does_not_use_a_stock_with_the_same_symbol(self):
        http = FakeHTTP([])
        with self.assertRaises(sync.SyncError):
            sync.Providers(http, 'key').fetch(target(symbol='BTC', currency='USD', exchange=''))
        self.assertFalse(http.calls)

    def test_tushare_reference_rates_units_time_and_source(self):
        for currency, value, expected in [('USD', '670.96', '6.7096'), ('HKD', '85.582', '0.8558')]:
            http = FakeHTTP([{'code': 0, 'data': {'fields': ['ts_code', 'mid_rate', 'trade_date'],
                'items': [['CNY' + currency, value, '20261126']]}}])
            t = target(kind='fx', baseCurrency=currency, quoteCurrency='CNY', fromDate='2026-11-26', throughDate='2026-11-26')
            rows, complete = sync.Providers(http, tushare_token='PRIVATE').fetch(t)
            self.assertEqual(rows, [{'date': '2026-11-26', 'value': expected, 'observedAt': '2026-11-26T01:15:00Z'}])
            self.assertTrue(complete)
            self.assertEqual(http.calls[0][2]['body']['api_name'], 'fx_midrate')
            http = FakeHTTP([{'results': [{'targetId': t['targetId'], 'status': 'updated', 'count': 1}]}])
            sync.Hako(http, 'https://hako.example.com', 'ak', 'sk').upload(t, rows, complete)
            self.assertEqual(http.calls[0][2]['body']['items'][0]['source'], 'Tushare Pro')

    def test_tushare_reference_rates_empty_missing_key_and_wrong_currency(self):
        t = target(kind='fx', baseCurrency='USD', quoteCurrency='CNY', fromDate='2025-01-01', throughDate='2025-01-01')
        with self.assertRaises(sync.SyncError):
            sync.Providers(FakeHTTP([])).fetch(t)
        empty = {'code': 0, 'data': {'fields': ['ts_code', 'mid_rate', 'trade_date'], 'items': []}}
        self.assertEqual(sync.Providers(FakeHTTP([empty]), tushare_token='key').fetch(t), ([], True))
        wrong = {'code': 0, 'data': {'fields': ['ts_code', 'mid_rate', 'trade_date'], 'items': [['CNYHKD', 100, '20250101']]}}
        with self.assertRaises(sync.SyncError):
            sync.Providers(FakeHTTP([wrong]), tushare_token='key').fetch(t)

    def test_check_dry_run_and_partial_failure_never_write_unconfirmed_data(self):
        t = target()
        class FakeHako:
            def __init__(self): self.writes = []
            def targets(self): yield [t]
            def upload(self, *args): self.writes.append(args); return 1
        class FakeProviders:
            def __init__(self): self.calls = 0
            def fetch(self, item): self.calls += 1; return [], True
        hako, providers = FakeHako(), FakeProviders()
        with redirect_stdout(io.StringIO()):
            self.assertEqual(sync.run(hako, providers, check=True), 0)
            self.assertEqual(providers.calls, 0)
            self.assertEqual(sync.run(hako, providers, dry_run=True), 0)
        self.assertEqual(providers.calls, 1)
        self.assertFalse(hako.writes)
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(sync.run(hako, providers), 0)
        self.assertEqual(len(hako.writes), 1)  # Same range isn't repeated for all ten rounds.
        self.assertNotIn(t['targetId'], output.getvalue())

    def test_rejected_item_does_not_prevent_other_targets(self):
        class FakeHako:
            def targets(self): yield [target(key='bad'), target(key='good')]
            def upload(self, *args): return 1
        class FakeProviders:
            def fetch(self, item):
                if item['key'] == 'bad': raise sync.SyncError('invalid data')
                return [], True
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(sync.run(FakeHako(), FakeProviders()), 1)
        self.assertIn('写入变更 1 条，失败 1 个', output.getvalue())

    def test_transport_reports_safe_failure_types_without_raw_messages(self):
        cases = [(URLError(socket.gaierror(-2, 'SECRET')), 'DNS'),
                 (URLError(ssl.SSLCertVerificationError('SECRET')), 'TLS'),
                 (TimeoutError('SECRET'), '超时'),
                 (RemoteDisconnected('https://host?apikey=SECRET'), '对端断开'),
                 (IncompleteRead(b'SECRET', 20), '传输不完整'),
                 (URLError('https://host?apikey=SECRET'), '网络连接失败')]
        for error, hint in cases:
            with self.subTest(error=type(error).__name__):
                detail = sync.transport_failure(error)
                self.assertIn(hint, detail)
                self.assertNotIn('SECRET', detail)
                self.assertNotIn('https://', detail)

    def test_eastmoney_connection_failures_pause_only_that_domain(self):
        http = sync.HTTP(time.monotonic() + 120)
        calls = []
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, limit): return b'{"ErrCode":0}'
        class Opener:
            def open(self, request, timeout):
                calls.append(request)
                if 'push2his.eastmoney.com' in request.full_url:
                    raise RemoteDisconnected('SECRET')
                return Response()
        http.opener = Opener()
        output = io.StringIO()
        with patch.object(sync.time, 'sleep'), redirect_stdout(output):
            with self.assertRaisesRegex(sync.SyncError, '暂停 60 秒'):
                http.request('eastmoney', 'https://push2his.eastmoney.com/api/qt/stock/kline/get')
            self.assertEqual(len(calls), 3)
            with self.assertRaises(sync.ProviderDeferred):
                http.request('eastmoney', 'https://push2his.eastmoney.com/api/qt/stock/kline/get')
            self.assertEqual(len(calls), 3, 'A paused host must not receive another request')
            self.assertEqual(http.request('eastmoney', 'https://api.fund.eastmoney.com/f10/lsjz'), {'ErrCode': 0})
        self.assertIn('第 1/3 次请求失败', output.getvalue())
        self.assertNotIn('SECRET', output.getvalue())
        http.blocked_hosts['push2his.eastmoney.com'] = time.monotonic() - 1
        with patch.object(sync.time, 'sleep'), redirect_stdout(io.StringIO()):
            with self.assertRaises(sync.SyncError):
                http.request('eastmoney', 'https://push2his.eastmoney.com/api/qt/stock/kline/get')
        self.assertEqual(len(calls), 7, 'The host becomes retryable after cooldown')

    def test_deferred_targets_are_separate_from_actual_request_failures(self):
        class FakeHako:
            def targets(self): return [[target(key='paused')]]
            def upload(self, *args): raise AssertionError('A deferred request must not upload')
        class FakeProviders:
            def fetch(self, item): raise sync.ProviderDeferred('连接异常，稍后重试')
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(sync.run(FakeHako(), FakeProviders()), 0)
        self.assertIn('延后', output.getvalue())
        self.assertIn('失败 0 个，延后 1 个', output.getvalue())

    def test_transport_retries_exact_body_and_sanitizes_errors(self):
        http = sync.HTTP(time.monotonic() + 120)
        requests = []
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, limit): return b'{"results":[]}'
        class Opener:
            def open(self, request, timeout):
                requests.append(request)
                if len(requests) == 1: raise URLError('https://host?apikey=SECRET')
                return Response()
        http.opener = Opener()
        with patch.object(sync.time, 'sleep'), redirect_stdout(io.StringIO()):
            http.request('hako', 'https://host', body={'items': []})
        self.assertEqual(requests[0].data, requests[1].data)
        http.opener.open = lambda *a, **kw: (_ for _ in ()).throw(HTTPError('https://host?apikey=SECRET', 401, 'SECRET', {}, None))
        with self.assertRaises(sync.SyncError) as failure:
            http.request('twelve', 'https://host?apikey=SECRET')
        self.assertNotIn('SECRET', str(failure.exception))
        self.assertIsNone(sync.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://other'))


if __name__ == '__main__':
    unittest.main()
