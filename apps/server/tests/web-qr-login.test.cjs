const assert = require('node:assert/strict');
const {test} = require('node:test');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

function loginPage() {
  let now = Date.parse('2026-11-03T12:00:00Z'), nextTimer = 0, requests = 0;
  const nodes = new Map(), intervals = new Map(), timeouts = new Map();
  const get = id => {
    if (!nodes.has(id)) nodes.set(id, {hidden: false, disabled: false, events: {}, textContent: '',
      addEventListener(event, handler) { this.events[event] = handler; },
      focus() { document.activeElement = this; }});
    return nodes.get(id);
  };
  const document = {getElementById: get, addEventListener() {}, activeElement: null};
  get('dashboard').hidden = true; get('login-qr').hidden = true; get('qr-overlay').hidden = true;
  class Clock extends Date { static now() { return now; } }
  const context = vm.createContext({document, window: {location: {pathname: '/admin/'}}, Date: Clock, AbortSignal,
    setInterval(fn, ms) { const id = ++nextTimer; intervals.set(id, {fn, ms}); return id; },
    clearInterval(id) { intervals.delete(id); },
    setTimeout(fn) { const id = ++nextTimer; timeouts.set(id, fn); return id; },
    clearTimeout(id) { timeouts.delete(id); },
    fetch: async () => ({ok: true, json: async () => ({id: String(++requests), confirmationCode: '123456',
      expiresAt: new Date(now + 5000).toISOString(), pollIntervalMs: 1000, qrPayload: 'preview'})})
  });
  vm.runInContext(readFileSync(new URL('../internal/server/web/app.js', `file://${__filename}`), 'utf8'), context);
  return {context, get, intervals, timeouts, requests: () => requests,
    expire() { now += 6000; for (const {fn, ms} of [...intervals.values()]) if (ms === 1000) fn(); }};
}

test('expired QR remains visible under a refresh overlay and refresh waits for the new image', async () => {
  const p = loginPage();
  await p.context.startQr();
  p.get('login-qr').onload();
  assert.equal(p.get('qr-overlay').hidden, true);
  const oldSource = p.get('login-qr').src, oldLoad = p.get('login-qr').onload;
  p.expire();
  assert.equal(p.get('login-qr').hidden, false);
  assert.equal(p.get('login-qr').src, oldSource);
  assert.equal(p.get('qr-overlay').hidden, false);
  assert.equal(p.get('qr-overlay-message').textContent, '二维码已过期');
  assert.equal(p.get('copy-login').disabled, true);
  assert.equal(p.timeouts.size, 0);
  assert.equal([...p.intervals.values()].filter(t => t.ms === 1000).length, 0);
  oldLoad();
  assert.equal(p.get('qr-overlay').hidden, false, 'Late image loads must not uncover an expired code');
  const refreshing = p.get('refresh-qr-overlay').events.click();
  assert.equal(p.get('refresh-qr-overlay').disabled, true);
  await Promise.all([refreshing, p.context.startQr()]);
  assert.equal(p.requests(), 2, 'Repeated clicks must coalesce');
  assert.notEqual(p.get('login-qr').src, oldSource);
  assert.equal(p.get('qr-overlay').hidden, false);
  p.get('login-qr').onload();
  assert.equal(p.get('qr-overlay').hidden, true);
  assert.equal(p.get('copy-login').disabled, false);
});

test('server expiration uses the same overlay', async () => {
  const p = loginPage(); await p.context.startQr(); p.get('login-qr').onload();
  p.context.fetch = async () => ({ok: false, status: 410, json: async () => ({error: 'login_request_expired'})});
  await [...p.timeouts.values()][0]();
  assert.equal(p.get('qr-overlay-message').textContent, '二维码已过期');
  assert.equal(p.get('qr-overlay').hidden, false);
  assert.equal(p.get('login-qr').hidden, false);
  assert.equal(p.get('refresh-qr-overlay').disabled, false);
});

test('late poll responses cannot overwrite the expired state', async () => {
  const p = loginPage(); await p.context.startQr(); p.get('login-qr').onload();
  let respond;
  p.context.fetch = () => new Promise(resolve => { respond = resolve; });
  const pending = [...p.timeouts.values()][0]();
  p.expire();
  respond({ok: true, json: async () => ({status: 'scanned'})});
  await pending;
  assert.equal(p.get('qr-status').textContent, '二维码已过期');
  assert.equal(p.get('qr-overlay').hidden, false);
  assert.equal(p.timeouts.size, 0);
});

test('generation and image failures leave an enabled retry button', async () => {
  const p = loginPage();
  const originalFetch = p.context.fetch;
  p.context.fetch = async () => { throw new Error('network unavailable'); };
  await p.context.startQr();
  assert.equal(p.get('qr-overlay').hidden, false);
  assert.equal(p.get('refresh-qr-overlay').disabled, false);
  p.context.fetch = originalFetch;
  await p.get('refresh-qr-overlay').events.click();
  p.get('login-qr').onerror();
  assert.equal(p.get('qr-overlay-message').textContent, '二维码加载失败');
  assert.equal(p.get('refresh-qr-overlay').disabled, false);
  assert.equal(p.get('copy-login').disabled, true);
  await p.get('refresh-qr-overlay').events.click(); p.get('login-qr').onload();
  assert.equal(p.get('qr-overlay').hidden, true);
});
