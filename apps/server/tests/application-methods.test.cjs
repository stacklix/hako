const assert = require('node:assert/strict');
const {test} = require('node:test');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

function page(application) {
  const elements = new Map(), calls = [];
  function $(id) {
    if (!elements.has(id)) elements.set(id, {
      value: '', checked: false, disabled: false, children: [], events: {},
      addEventListener(name, fn) { this.events[name] = fn; },
      append(...nodes) { this.children.push(...nodes); },
      replaceChildren(...nodes) { this.children = nodes; },
      close() {}, showModal() {}, reset() {},
    });
    return elements.get(id);
  }
  const context = vm.createContext({$, messages: {}, csrf: 'test', currentPage: 'applications',
    date: x => x, notice() {}, empty() {}, confirm: () => true,
    node: (tag, text) => ({tag, text, children: [], append(...nodes) { this.children.push(...nodes); }}),
    action: (text, fn) => ({text, fn}),
    navigator: {clipboard: {writeText: async () => {}}},
    api: async (path, method, body) => {
      calls.push({path, method, body: body && JSON.parse(JSON.stringify(body))});
      if (method) return {application, clientSecret: method === 'POST' ? 'test' : undefined, configuration: ''};
      return {issuer: 'https://hako.example.com', applications: application ? [application] : []};
    },
  });
  vm.runInContext(readFileSync(new URL('../internal/server/web/applications.js', `file://${__filename}`), 'utf8'), context);
  return {$, context, calls};
}

test('application creation sends the three independent login choices', async () => {
  for (let mask = 0; mask < 8; mask++) {
    const {$, calls} = page();
    $('application-name').value = 'Cerno'; $('application-origin').value = 'https://cerno.example.com';
    $('application-qr').checked = !!(mask & 1); $('application-native').checked = !!(mask & 2);
    $('application-oidc').checked = !!(mask & 4);
    $('application-redirects').value = mask & 4 ? 'https://cerno.example.com/callback' : '';
    $('application-auth').value = 'client_secret_basic';
    await $('application-form').events.submit({preventDefault() {}});
    const request = calls[0];
    assert.equal(request.method, 'POST');
    assert.equal(request.body.qrEnabled, !!(mask & 1));
    assert.equal(request.body.nativeEnabled, !!(mask & 2));
    assert.equal(request.body.oidc?.enabled ?? false, !!(mask & 4));
  }
});

test('editing a native-only application does not require or enable OIDC', async () => {
  const application = {id: 'app_cerno', name: 'Cerno', origin: 'https://cerno.example.com', enabled: true,
    qrEnabled: false, nativeEnabled: true, createdAt: ''};
  const {$, context, calls} = page(application);
  await vm.runInContext('refreshApplications()', context);
  const buttons = $('application-list').children[0].children[1];
  await buttons.children.find(button => button.text === '配置登录方式').fn();
  assert.equal($('application-qr').checked, false);
  assert.equal($('application-native').checked, true);
  assert.equal($('application-oidc').checked, false);
  $('application-native').checked = false; $('application-qr').checked = true;
  await $('application-form').events.submit({preventDefault() {}});
  const request = calls.find(call => call.method === 'PATCH');
  assert.deepEqual(request.body, {qrEnabled: true, nativeEnabled: false});
});
