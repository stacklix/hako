import importlib.util
import io
import json
import sys
import time
import unittest
from contextlib import redirect_stdout
from datetime import date, datetime, timedelta, timezone
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
        sync.Providers(http).fetch(target())
        self.assertEqual(http.calls[0][1], 'https://hako.example.com/prefix/api/v1/market/update-targets')
        self.assertEqual(http.calls[0][2]['headers']['Authorization'], 'Bearer hako-secret')
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
            sync.Providers(http).fetch(target())
        http.responses.append({'rc': 0, 'data': {'code': '000001', 'market': 0, 'klines': ['bad']}})
        with self.assertRaises(sync.SyncError):
            sync.Providers(http).fetch(target())

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

    def test_ecb_cross_rates_and_publication_time(self):
        text = 'CURRENCY,TIME_PERIOD,OBS_VALUE\nCNY,2025-01-02,7.6\nUSD,2025-01-02,1.0\n'
        http = FakeHTTP([text])
        t = target(kind='fx', baseCurrency='USD', quoteCurrency='CNY', fromDate='2025-01-02', throughDate='2025-01-02')
        rows, complete = sync.Providers(http).fetch(t)
        self.assertEqual(rows[0], {'date': '2025-01-02', 'value': '7.6', 'observedAt': '2025-01-02T15:00:00Z'})
        self.assertTrue(complete)

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
