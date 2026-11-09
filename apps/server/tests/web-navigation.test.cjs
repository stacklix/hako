const assert = require('node:assert/strict');
const {test} = require('node:test');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

async function openPage(pathname, logs = {status: {enabled: false}}, recordPages = []) {
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
      const responses = {
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
  for (const file of ['app.js', 'access-logs.js', 'applications.js']) {
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
