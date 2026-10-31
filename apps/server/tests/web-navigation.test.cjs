const assert = require('node:assert/strict');
const {test} = require('node:test');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

async function openPage(pathname) {
  const elements = new Map(), calls = [], timers = [];
  let ready;
  function element() {
    return {hidden: false, value: '', attributes: {}, addEventListener() {},
      setAttribute(name, value) { this.attributes[name] = value; },
      replaceChildren() {}, close() {}};
  }
  const document = {
    hidden: false,
    getElementById(id) {
      if (!elements.has(id)) elements.set(id, element());
      return elements.get(id);
    },
    createElement: element,
    addEventListener(event, callback) { if (event === 'DOMContentLoaded') ready = callback; }
  };
  document.getElementById('logs-range').value = '24';
  const context = vm.createContext({document, window: {location: {pathname}},
    AbortSignal, URLSearchParams, clearTimeout() {}, clearInterval() {},
    setInterval(callback) { timers.push(callback); },
    fetch: async url => {
      calls.push(url);
      const responses = {
        '/admin/api/session': {csrfToken: 'test', username: 'Admin'},
        '/admin/api/agents': {agents: [], updatedAt: '2026-10-30T12:00:00Z'},
        '/admin/api/access-logs?rangeHours=24': {status: {enabled: false}}
      };
      assert.ok(url in responses, `unexpected request: ${url}`);
      return {ok: true, json: async () => responses[url]};
    }
  });
  for (const file of ['app.js', 'access-logs.js']) {
    vm.runInContext(readFileSync(new URL(`../internal/server/web/${file}`, `file://${__filename}`), 'utf8'), context);
  }
  await ready();
  await new Promise(setImmediate);
  return {document, calls, timers, context};
}

for (const [path, page, title] of [
  ['/admin/', 'agents', '设备代理'],
  ['/admin/agents', 'agents', '设备代理'],
  ['/admin/access-logs', 'access-logs', '访问日志']
]) {
  test(`${path} opens only its page and polls only its data`, async () => {
    const {document, calls, timers, context} = await openPage(path);
    const get = id => document.getElementById(id);
    assert.equal(get('dashboard').hidden, false);
    assert.equal(get('agents-page').hidden, page !== 'agents');
    assert.equal(get('access-logs').hidden, page !== 'access-logs');
    assert.equal(get(`nav-${page}`).attributes['aria-current'], 'page');
    assert.equal(get('page-title').textContent, title);
    assert.equal(document.title, `${title} · Hako 管理控制台`);
    const endpoint = page === 'agents' ? '/admin/api/agents' : '/admin/api/access-logs?rangeHours=24';
    assert.deepEqual(calls, ['/admin/api/session', endpoint]);
    timers.forEach(callback => callback());
    await new Promise(setImmediate);
    assert.deepEqual(calls, ['/admin/api/session', endpoint, endpoint]);
    context.loggedIn(false);
    assert.equal(get('dashboard').hidden, true);
    assert.equal(get('login-panel').hidden, false);
    timers.forEach(callback => callback());
    await new Promise(setImmediate);
    assert.equal(calls.length, 3, 'logout stops page polling');
  });
}
