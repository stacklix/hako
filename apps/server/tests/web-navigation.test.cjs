const assert = require('node:assert/strict');
const {test} = require('node:test');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

async function openPage(pathname, logs = {status: {enabled: false}}, recordPages = [], investmentData) {
  const elements = new Map(), calls = [], timers = [];
  let ready;
  class TestNode {
    constructor() { this.hidden = false; this.value = ''; this.attributes = {}; this.children = []; this.dataset = {}; }
    addEventListener() {}
    setAttribute(name, value) { this.attributes[name] = value; }
    append(...children) { this.children.push(...children); }
    replaceChildren(...children) { this.children = children; }
    get firstChild() { return this.children[0]; }
    close() {}
  }
  function element() { return new TestNode(); }
  const document = {
    hidden: false,
    body: {classList: {toggle() {}}},
    getElementById(id) {
      if (!elements.has(id)) elements.set(id, element());
      return elements.get(id);
    },
    createElement: element,
    createElementNS(namespaceURI) { return Object.assign(element(), {namespaceURI}); },
    createTextNode(text) { const result = element(); result.textContent = text; return result; },
    querySelectorAll() { return []; },
    addEventListener(event, callback) { if (event === 'DOMContentLoaded') ready = callback; }
  };
  document.getElementById('logs-range').value = '24';
  const context = vm.createContext({document, window: {location: {pathname}},
    AbortSignal, URLSearchParams, Node: TestNode, clearTimeout() {}, clearInterval() {},
    setInterval(callback) { timers.push(callback); },
    fetch: async url => {
      calls.push(url);
      if (url.startsWith('/admin/api/access-logs/records?')) {
        assert.ok(recordPages.length, 'unexpected records request');
        return {ok: true, json: async () => recordPages.shift()};
      }
      if (url.startsWith('/admin/api/investment/') && investmentData) {
        return {ok: true, json: async () => investmentData};
      }
      const responses = {
        '/admin/api/system/databases': {expectedVersion: 2, databases: [
          {name: '服务端主库', file: 'hako.db', status: 'available', schema: {
            version: 2, tables: [{name: 'state', sql: 'CREATE TABLE state(id INTEGER PRIMARY KEY)'}]
          }},
          {name: '访问日志', file: 'hako.db.access.db', status: 'not_created'}
        ]},
        '/admin/api/session': {csrfToken: 'test', username: 'Admin'},
        '/admin/api/agents': {agents: [], updatedAt: '2026-10-30T12:00:00Z'},
        '/admin/api/applications': {applications: []},
        '/admin/api/access-logs?rangeHours=24': logs
      };
      if (url.startsWith('/admin/api/access-logs/rankings?')) {
        return {ok: true, json: async () => ({visits: 12, success: 10, nonSuccess: 2, topURLs: [], successURLs: [{value: '/domain-success', count: 10}], topClients: [{value: '192.0.2.1', count: 12, userAgents: [], urls: [{value: '/legacy-combined', count: 12}], successURLs: [{value: '/ok', count: 10}], nonSuccessURLs: [{value: '/missing', count: 2}]}], nonSuccessPages: [], nonSuccessIPs: [], nonSuccessUserAgents: []})};
      }
      assert.ok(url in responses, `unexpected request: ${url}`);
      return {ok: true, json: async () => responses[url]};
    }
  });
  for (const file of ['app.js', 'access-logs.js', 'applications.js', 'investment.js']) {
    vm.runInContext(readFileSync(new URL(`../internal/server/web/${file}`, `file://${__filename}`), 'utf8'), context);
  }
  await ready();
  await new Promise(setImmediate);
  return {document, calls, timers, context};
}

test('access logs show rankings without a duplicate domain table or an hour filter', async () => {
  const from = '2026-11-01T00:00:00Z', to = '2026-11-02T00:00:00Z';
  const {document, calls} = await openPage('/admin/access-logs', {
    status: {enabled: true, timezone: 'Asia/Shanghai', scanIntervalSeconds: 60, retentionDays: 7},
    rangeHours: 24, from, to, domains: ['a.test'],
    totals: [{domain: 'a.test', visits: 12, success: 10, nonSuccess: 2}],
    hours: [{domain: 'a.test', hour: from, visits: 777, success: 777, nonSuccess: 0}]
  });
  assert.equal(calls.length, 3);
  const request = new URL(calls[2], 'https://hako.test');
  assert.equal(request.pathname, '/admin/api/access-logs/rankings');
  assert.equal(request.searchParams.get('domain'), 'a.test');
  assert.equal(request.searchParams.get('from'), from);
  assert.equal(request.searchParams.get('to'), to);
  assert.equal(request.searchParams.has('hour'), false);
  function text(node) { return [node.textContent || '', ...node.children.map(text)].join(' '); }
  assert.equal(document.getElementById('logs-domain-title').textContent, 'a.test');
  assert.match(document.getElementById('logs-domain-count').textContent, /访问量 12 次 · 正常响应 10 次 · 异常响应 2 次/);
  const rankings = text(document.getElementById('logs-rankings'));
  assert.match(rankings, /正常响应 URL · Top 10/);
  assert.match(rankings, /异常响应 URL · Top 10/);
  assert.doesNotMatch(rankings, /4xx/);
  assert.match(rankings, /\/domain-success/);
  assert.match(rankings, /\/ok/);
  assert.match(rankings, /\/missing/);
  assert.doesNotMatch(rankings, /legacy-combined/);
  assert.equal(text(document.getElementById('logs-empty')).trim(), '');
  const html = readFileSync(new URL('../internal/server/web/index.html', `file://${__filename}`), 'utf8');
  assert.doesNotMatch(html, /logs-domains|点击查看排行/);
  assert.equal(document.getElementById('logs-detail').hidden, false);
});

test('record queries combine filters and load every page with a fixed window', async () => {
  const from = '2026-11-02T00:00:00Z', to = '2026-11-02T01:00:00Z';
  const row = {time: from, domain: 'a.test', ip: '192.0.2.1', path: '/a+b', status: 404, userAgent: 'UA', count: 2};
  const {document, calls, context} = await openPage('/admin/access-logs', undefined, [
    {from, to, timezone: 'UTC', requests: 3, totalRows: 2, rows: [row], hasMore: true},
    {from, to, timezone: 'UTC', requests: 3, totalRows: 2, rows: [{...row, time: to, count: 1}], hasMore: false}
  ]);
  for (const [key, value] of Object.entries({domain: 'a.test', ip: '192.0.2.1', path: '/a+b', status: '404', from: '2026-11-02T08:00:00', to: '2026-11-02T09:00:00'})) {
    document.getElementById('logs-query-' + key).value = value;
  }
  await vm.runInContext('queryLogRecords()', context);
  assert.equal(document.getElementById('logs-query-more').hidden, false);
  document.getElementById('logs-query-status').value = '200';
  await vm.runInContext('queryLogRecords(true)', context);
  const queries = calls.filter(url => url.includes('/records?')).map(url => new URL(url, 'https://hako.test').searchParams);
  assert.equal(queries.length, 2);
  assert.equal(queries[0].get('path'), '/a+b');
  assert.equal(queries[0].get('ip'), '192.0.2.1');
  assert.equal(queries[1].get('status'), '404');
  assert.equal(queries[1].get('offset'), '1');
  assert.equal(queries[1].get('from'), from);
  assert.equal(queries[1].get('to'), to);
  assert.match(document.getElementById('logs-query-summary').textContent, /已显示 2\/2 条记录/);
  assert.equal(document.getElementById('logs-query-more').hidden, true);
  vm.runInContext('resetAccessLogs()', context);
  assert.equal(document.getElementById('logs-query-results').children.length, 0);
  assert.equal(document.getElementById('logs-query-summary').textContent, '');
});

for (const [path, page, title] of [
  ['/admin/', 'agents', '设备代理'],
  ['/admin/agents', 'agents', '设备代理'],
  ['/admin/access-logs', 'access-logs', '访问日志'],
  ['/admin/applications', 'applications', '应用管理']
]) {
  test(`${path} opens only its page and refreshes only its data`, async () => {
    const {document, calls, timers, context} = await openPage(path);
    const get = id => document.getElementById(id);
    assert.equal(get('dashboard').hidden, false);
    assert.equal(get('agents-page').hidden, page !== 'agents');
    assert.equal(get('access-logs').hidden, page !== 'access-logs');
    assert.equal(get('applications-page').hidden, page !== 'applications');
    assert.equal(get(`nav-${page}`).attributes['aria-current'], 'page');
    assert.equal(get('page-title').textContent, title);
    assert.equal(document.title, `${title} · Hako 管理控制台`);
    const endpoint = page === 'agents' ? '/admin/api/agents' : page === 'applications' ? '/admin/api/applications' : '/admin/api/access-logs?rangeHours=24';
    assert.deepEqual(calls, ['/admin/api/session', endpoint]);
    timers.forEach(callback => callback());
    await new Promise(setImmediate);
    if (page === 'applications') {
      assert.deepEqual(calls, ['/admin/api/session', endpoint], 'application credentials are refreshed on demand');
      await context.refreshApplications();
    }
    assert.deepEqual(calls, ['/admin/api/session', endpoint, endpoint]);
    context.loggedIn(false);
    assert.equal(get('dashboard').hidden, true);
    assert.equal(get('login-panel').hidden, false);
    timers.forEach(callback => callback());
    await new Promise(setImmediate);
    assert.equal(calls.length, 3, 'logout stops page polling');
  });
}

test('notification gateway opens the requested second-level menu after Hako login', async () => {
  const {document, calls, context} = await openPage('/admin/notifications/webhooks');
  const get = id => document.getElementById(id);
  assert.equal(get('notification-subnav').hidden, false);
  assert.equal(get('notifications-page').hidden, false);
  assert.equal(get('nav-notifications-webhooks').attributes['aria-current'], 'page');
  assert.equal(get('notifications-frame').attributes.src, '/admin/notifications-ui/?view=webhooks');
  assert.deepEqual(calls, ['/admin/api/session']);
  context.loggedIn(false);
  assert.equal(get('notifications-frame').attributes.src, 'about:blank');
});

const investmentData = {tables: {
  investment_accounts: [{id: 'bank', name: '测试银行', account_type: 'deposits', currency: 'CNY', sort_order: '0'}],
  investment_assets: [
    {id: 'deposit', name: '测试存单', asset_type: 'certificate', quote_currency: 'CNY'},
    {id: 'watch', name: '测试股票', symbol: '600519', asset_type: 'stock', instrument_id: 'stock', quote_currency: 'CNY'}
  ],
  investment_events: [{id: '1', account_id: 'bank', asset_id: 'deposit', event_type: 'income',
    effective_date: '2026-11-09', sequence: '0', amount: '20', settled_amount: '400'}],
  investment_daily_snapshots: [
    {snapshot_date: '2026-11-08', total_cny: '990', total_usd: '139', cumulative_gain_cny: '90', status: 'complete'},
    {snapshot_date: '2026-11-09', total_cny: '1000', total_usd: '140', cumulative_gain_cny: '100', daily_gain_cny: '10', status: 'complete'}
  ],
  investment_account_daily_snapshots: [{account_id: 'bank', snapshot_date: '2026-11-09', cash_native: '600', holdings_native: '400', gain_native: '100'}],
  investment_watchlist: [{asset_id: 'watch', instrument_id: 'stock', sort_order: '0'}],
  market_daily_prices: [
    {instrument_id: 'stock', session_date: '2026-11-02', price: '50', is_final: '1', source: '测试行情'},
    {instrument_id: 'stock', session_date: '2026-11-09', price: '55', is_final: '1', source: '测试行情'}
  ],
  investment_balance_accounts: [{id: 'cash', category: 'cash', name: '现金钱包', currency: 'CNY', sort_order: '0'}],
  investment_balance_records: [{balance_account_id: 'cash', amount: '50', recorded_at: '2026-11-09T01:00:00Z'}],
  investment_month_snapshots: [{snapshot_date: '2026-10-31', total_cny: '950'}]
}};

for (const [view, title, contents] of [
  ['overview', '总览', [/日终总览.*1,000\.00/, /资产变化曲线/, /盈亏日历/, /测试银行/]],
  ['accounts', '账户', [/测试银行.*1,000\.00/, /测试存单/, /支取利息.*20\.00.*400\.00/]],
  ['watchlist', '关注', [/测试股票.*600519/, /近1周.*近1年/, /55 CNY.*\+10%/]],
  ['balance-sheet', '资产负债', [/总资产.*1,050\.00/, /较上月底.*\+[^\d]*100\.00/, /资产构成/, /资产趋势.*净资产趋势/, /资产月历.*11 月.*1,050\.00/,
    /现金钱包/, /2026-10-31.*950\.00/]]
]) {
  test(`investment ${view} displays saved values under its read-only menu`, async () => {
    const path = view === 'overview' ? '/admin/investment' : '/admin/investment/' + view;
    const {document, calls, context} = await openPage(path, undefined, [], investmentData);
    const get = id => document.getElementById(id);
    const text = node => [node.textContent || '', ...node.children.map(text)].join(' ');
    assert.deepEqual(calls, ['/admin/api/session', '/admin/api/investment/' + view]);
    assert.equal(get('investment-subnav').hidden, false);
    assert.equal(get('investment-page').hidden, false);
    assert.equal(get('nav-investment-' + view).attributes['aria-current'], 'page');
    assert.equal(get('page-title').textContent, '投资记账 · ' + title);
    assert.match(get('investment-status').textContent, /只读/);
    for (const pattern of contents) assert.match(text(get('investment-content')), pattern);
    context.loggedIn(false);
    assert.equal(get('investment-content').children.length, 0);
  });
}

test('balance charts align recorded balances to Beijing dates and leave missing valuation days open', async () => {
  const {context} = await openPage('/admin/investment/balance-sheet', undefined, [], investmentData);
  const {points, monthEnds} = vm.runInContext(`investmentBalanceHistory(
    [{balance_account_id: 'cash', amount: '50', recorded_at: '2026-10-31T16:15:00Z'}],
    new Map([['cash', {category: 'cash'}]]),
    [{snapshot_date: '2026-11-01', total_cny: '1000'}, {snapshot_date: '2026-11-02', status: 'missing'}],
    [{snapshot_date: '2026-10-31', total_cny: '950'}], '1000', true)`, context);
  assert.equal(monthEnds[0].day, '2026-10-31');
  assert.equal(monthEnds[0].assets, '950');
  assert.equal(points.find(point => point.day === '2026-11-01').assets, '1050');
  assert.equal(monthEnds.at(-1).net, undefined);
  const deficit = vm.runInContext(`investmentBalanceTotals({cash: '50', fixed: '0', receivables: '0', liabilities: '10'}, '-80')`, context);
  assert.equal(deficit.assets, '50');
  assert.equal(deficit.liabilities, '90');
  assert.equal(deficit.net, '-40');
});

test('system configuration loads database versions and table definitions', async () => {
  const {document, calls} = await openPage('/admin/system');
  assert.deepEqual(calls, ['/admin/api/session', '/admin/api/system/databases']);
  assert.equal(document.getElementById('system-page').hidden, false);
  assert.equal(document.getElementById('nav-system').attributes['aria-current'], 'page');
  assert.equal(document.getElementById('page-title').textContent, '系统配置');
  const text = node => [node.textContent || '', ...node.children.map(text)].join(' ');
  const content = text(document.getElementById('system-databases'));
  assert.match(content, /版本已就绪.*hako.db · 版本 2.*CREATE TABLE state/);
  assert.match(content, /尚未创建/);
});
