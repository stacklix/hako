// Executed against the production bundle by remote_ui_browser_test.py.
// Requests are in-memory fixtures: tests never send SMS, dial, or access a device.
const testSnapshot = {
  permissions: { sms: true, phone: true },
  simCards: [{ subscriptionId: 1, displayName: '中国移动 · SIM 1', number: '13800008000' }],
  remoteControlStatus: { isRunning: true, port: 18080, ipAddresses: ['192.168.1.108'] },
  config: {
    forwarding: { selectedSmsSim: '中国移动 · SIM 1 · 13800008000', smsTargets: [{ value: '13800008000' }], emailTargets: [{ value: 'notify@example.com' }], httpTargets: [{ value: 'https://example.com/hooks/nami' }], smtp: { host: 'smtp.example.com', port: '465', fromEmail: 'doppel@example.com', username: 'doppel@example.com', password: 'fixture' } },
    commands: { callEnabled: true, smsEnabled: true, trustedNumbers: [{ number: '13800008000' }] },
    remoteControl: { enabled: true, port: '18080', password: 'fixture', token: 'fixture' },
  },
  events: [{ type: 'sms_received', from: '13800008000', content: '用于界面验证的短信内容。', timestamp: new Date().toISOString() }, { type: 'sms_pipeline_debug', detail: '内部事件不应出现在业务日志', timestamp: new Date().toISOString() }],
};
let testAgent = { enabled: true, server: 'https://hako.example.com', username: 'admin', allowSms: false, allowCalls: false, publicKey: window.__testPublicKey, keyId: 'rVcQ9Ax9Q7C7yIBr-EIBCxURCkvUtWO7Dp6ATB9HpTc', status: { state: 'connected', agentId: 'doppel-android-test', message: '已连接 Sora' } };
let session = false, failNext = '', requests = [];
function merge(target, source) { for (const [key, value] of Object.entries(source)) { if (value && typeof value === 'object' && !Array.isArray(value)) merge(target[key] ||= {}, value); else target[key] = value; } }
window.fetch = async (path, options = {}) => {
  const body = options.body ? JSON.parse(options.body) : {};
  requests.push({ path, body });
  let status = 200, result;
  if (failNext === path) { failNext = ''; status = 500; result = { message: '测试保存失败，请重试' }; }
  else if (path === '/login') { session = body.password === 'test'; status = session ? 200 : 401; result = { error: 'invalid_password' }; }
  else if (path === '/logout') { session = false; result = { ok: true }; }
  else if (!session) { status = 401; result = { error: 'unauthorized' }; }
  else if (path === '/api/snapshot') result = testSnapshot;
  else if (path === '/api/config') { merge(testSnapshot.config, body.config); result = { snapshot: testSnapshot }; }
  else if (path === '/api/agent/settings') { if (options.method === 'POST') { testAgent = { ...testAgent, ...body, status: { state: 'connecting', message: '正在连接 Sora' } }; } result = testAgent; }
  else if (path === '/api/agent/key') { testAgent.publicKey = window.__testPublicKey; result = testAgent; }
  else if (path === '/api/sms/send' || path === '/api/call/start') result = { message: '操作已提交' };
  else { status = 404; result = { error: 'not_found' }; }
  return { ok: status === 200, status, json: async () => structuredClone(result) };
};
window.addEventListener('error', (event) => { window.__browserError = event.message; });
window.addEventListener('unhandledrejection', (event) => { window.__browserError = String(event.reason); });

window.addEventListener('load', async () => {
  const checks = [], $ = (s) => document.querySelector(s);
  const tick = () => new Promise((resolve) => setTimeout(resolve, 20));
  const wait = async (condition) => { for (let i = 0; i < 100; i++) { if (condition()) return; await tick(); } throw new Error('等待界面超时'); };
  const assert = (ok, label) => { if (!ok) throw new Error(label); checks.push(label); };
  const button = (label, scope = document) => [...scope.querySelectorAll('button')].find((node) => node.textContent.trim() === label && node.getClientRects().length);
  const click = async (node) => { if (!node) throw new Error('缺少操作按钮'); node.focus(); node.click(); await tick(); };
  const fill = (selector, value) => { const node = $(selector); if (!node) throw new Error('缺少字段 ' + selector); const prototype = node.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype; Object.getOwnPropertyDescriptor(prototype, 'value').set.call(node, value); node.dispatchEvent(new Event('input', { bubbles: true })); };
  const submit = async () => { $('.dp-modal form').dispatchEvent(new Event('submit', { bubbles: true, cancelable: true })); await tick(); };
  const close = async () => click($('.dp-modal [aria-label="关闭"]'));
  const go = async (label) => { if (!$('.dp-sidebar').getClientRects().length) await click($('[aria-label="收起或展开侧栏"]')); await click(button(label, $('.dp-sidebar'))); };
  const noOverflow = (label) => assert(document.documentElement.scrollWidth <= innerWidth, label);
  try {
    await wait(() => $('.dp-login'));
    assert(innerWidth === window.__requestedWidth, '使用实际指定的视口宽度');
    assert(!$('.dp-nav'), '未登录隐藏管理菜单');
    fill('[name="password"]', 'wrong'); await click(button('登录'));
    assert($('.dp-login [role="alert"]')?.textContent.includes('管理密码错误'), '错误密码有明确提示');
    fill('[name="password"]', 'test'); await click(button('登录'));
    await wait(() => $('h1'));
    assert($('h1').textContent === '首页', '登录后进入首页');
    assert($('.dp-metrics').children.length === 4, '首页四项统计');
    noOverflow('首页窄屏不溢出');
    const capture = new URL(location.href).searchParams.get('capture');
    if (capture === 'overview') { document.activeElement?.blur(); return; }
    await go('连接配置'); await wait(() => button('查看公钥'));
    assert($('h1').textContent === '连接配置', '连接配置在配置二级菜单');
    assert($('.dp-body').innerText.includes('https://hako.example.com'), '显示实际 Hako 地址');
    assert(!$('.dp-body input:not([type="checkbox"])'), '连接与认证默认为显示态');
    noOverflow('连接配置窄屏不溢出');
    if (capture === 'connection') { document.activeElement?.blur(); return; }
    await click(button('查看公钥'));
    assert($('.dp-modal textarea').value === window.__testPublicKey, '公钥完整显示');
    assert($('.dp-modal textarea').readOnly, '公钥只读');
    assert(!$('.dp-modal').innerText.includes('演示公钥'), '生产界面没有演示公钥标记');
    if (capture === 'key') return;
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: undefined });
    document.execCommand = () => false;
    await click(button('复制公钥'));
    assert($('.dp-key-copy-status').textContent.includes('手动复制'), '复制受限时提供手动复制提示');
    document.execCommand = () => true; await click(button('复制公钥'));
    assert($('.dp-key-copy-status').textContent === '公钥已复制', 'HTTP 复制使用选区方式');
    assert(document.activeElement === $('.dp-modal textarea'), '复制选中完整公钥');
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); await tick();
    assert(!$('.dp-modal'), 'Escape 关闭弹窗');
    assert(document.activeElement === button('查看公钥'), '关闭恢复入口焦点');
    await click(button('编辑')); fill('[name="username"]', 'cancelled'); await click(button('取消'));
    assert(!$('.dp-body').innerText.includes('cancelled'), '取消连接编辑不改变配置');
    await click(button('编辑')); fill('[name="server"]', 'https://example.com/path'); await submit();
    assert($('.dp-dialog-error').textContent.includes('不包含路径'), '校验 Hako 基础地址');
    fill('[name="server"]', 'https://updated.example.com'); fill('[name="username"]', 'new-admin'); await submit();
    assert(!$('.dp-modal') && $('.dp-body').innerText.includes('new-admin'), '连接配置保存回显');
    assert(testAgent.server === 'https://updated.example.com', '连接配置提交真实接口');
    await click($('[aria-label="允许远程发送短信"]'));
    assert(testAgent.allowSms && !testAgent.allowCalls, 'Hako 权限独立保存');
    await go('转发配置');
    await click(button('添加手机号')); fill('[name="target"]', '138-0000-8000'); await submit();
    assert($('.dp-dialog-error').textContent.includes('已存在'), '手机号去空格连字符查重');
    fill('[name="target"]', 'abcd'); await submit(); assert($('.dp-dialog-error').textContent.includes('有效'), '手机号格式校验');
    fill('[name="target"]', '13900009000'); failNext = '/api/config'; await submit();
    assert($('.dp-modal') && $('[name="target"]').value === '13900009000', '保存失败保留弹窗草稿');
    assert($('.dp-dialog-error').textContent.includes('测试保存失败'), '保存失败显示接口错误');
    await submit(); assert(!$('.dp-modal') && $('.dp-body').innerText.includes('13900009000'), '手机号添加并回显');
    await click($('[aria-label="删除13900009000"]')); assert(!$('.dp-body').innerText.includes('13900009000'), '手机号删除保存');
    await click(button('添加手机号')); fill('[name="target"]', '13700007000'); await click(button('取消'));
    assert(!testSnapshot.config.forwarding.smsTargets.some((item) => item.value === '13700007000'), '取消添加不提交');
    await click(button('切换')); assert($('.dp-modal select').options.length === 1, 'SIM 来自快照'); await submit();
    await click(button('邮箱')); await click(button('添加邮箱')); fill('[name="target"]', 'new@example.com'); await submit();
    assert(testSnapshot.config.forwarding.emailTargets.length === 2, '邮箱弹窗添加');
    await click(button('编辑')); fill('[name="host"]', 'smtp.updated.example.com'); await submit();
    assert(testSnapshot.config.forwarding.smtp.host === 'smtp.updated.example.com' && testSnapshot.config.forwarding.smtp.password === 'fixture', 'SMTP 弹窗保存且空密码保留');
    await click(button('HTTP 地址')); await click(button('添加 HTTP 地址')); fill('[name="target"]', 'ftp://example.com'); await submit();
    assert($('.dp-dialog-error').textContent.includes('HTTP'), '推送地址限制 HTTP 协议');
    fill('[name="target"]', 'https://example.com/new'); await submit(); assert(testSnapshot.config.forwarding.httpTargets.length === 2, 'HTTP 地址弹窗添加');
    noOverflow('转发页窄屏不溢出');
    await go('指令配置');
    assert(button('短信指令') && button('HTTP 指令'), '两种指令保留同页');
    await click(button('添加可信号码')); fill('[name="number"]', '138 0000 8000'); await submit();
    assert($('.dp-dialog-error').textContent.includes('已存在'), '可信号码重复校验');
    fill('[name="number"]', '13600006000'); await submit(); assert(testSnapshot.config.commands.trustedNumbers.length === 2, '可信号码弹窗保存');
    await click($('[aria-label="远程打电话"]')); assert(!testSnapshot.config.commands.callEnabled && testSnapshot.config.commands.smsEnabled, '短信指令开关独立保存');
    await click(button('HTTP 指令')); assert(!$('.dp-body input'), 'HTTP 认证默认为显示态');
    await click(button('编辑')); fill('[name="port"]', '80'); await submit(); assert($('.dp-dialog-error').textContent.includes('1024'), 'HTTP 端口范围校验');
    fill('[name="port"]', '19080'); await submit(); assert(testSnapshot.config.remoteControl.port === '19080' && testSnapshot.config.remoteControl.password === 'fixture' && testSnapshot.config.remoteControl.token === 'fixture', 'HTTP 配置保存且空凭据保留');
    await go('日志'); assert(!$('.dp-body').innerText.includes('内部事件'), '日志排除内部流水线事件'); await click(button('详情'));
    assert($('.dp-message').textContent.includes('用于界面验证'), '事件弹窗显示全文'); await close();
    await go('操作'); fill('[name="to"]', '13900009000'); fill('[name="message"]', '测试消息');
    const smsSim = $('[name="sim"]').value;
    failNext = '/api/sms/send'; await click(button('发送短信', $('.dp-form')));
    assert($('[name="message"]').value === '测试消息' && $('[name="to"]').value === '13900009000', '短信提交失败保留消息和号码');
    await click(button('发送短信', $('.dp-form')));
    assert(requests.some((request) => request.path === '/api/sms/send' && request.body.message === '测试消息'), '发送短信接口正确');
    assert($('.dp-notice').textContent === '操作已提交', '操作提示区分提交与送达');
    assert($('[name="message"]').value === '', '短信提交成功清空消息框');
    assert($('[name="to"]').value === '13900009000' && $('[name="sim"]').value === smsSim, '短信提交成功保留号码和 SIM 卡');
    await click(button('发起拨号')); fill('[name="number"]', '13900009000'); await click(button('发起拨号', $('.dp-form')));
    assert(requests.some((request) => request.path === '/api/call/start'), '拨号接口正确');
    await click(button('操作历史')); assert($('.dp-table tbody').children.length === 3, '操作历史保留失败和提交记录');
    await go('首页'); await go('操作'); await click(button('操作历史')); assert($('.dp-table tbody').children.length === 3, '切换页面不丢本会话历史');
    await go('连接配置'); testAgent = { ...testAgent, publicKey: '', keyId: '' }; await click(button('刷新')); await wait(() => button('生成设备密钥'));
    await click(button('生成设备密钥')); assert(button('查看公钥'), '缺少密钥时可生成并查看');
    if (!$('.dp-sidebar').getClientRects().length) await click($('[aria-label="收起或展开侧栏"]'));
    await click($('[aria-label="退出登录"]')); await click(button('取消')); assert($('h1'), '取消退出保留会话');
    await click($('[aria-label="退出登录"]')); await click(button('退出')); assert($('.dp-login'), '退出返回登录界面');
    fill('[name="password"]', 'test'); await click(button('登录')); await go('首页');
    session = false; await click(button('刷新')); assert($('.dp-login'), '会话失效返回登录界面');
    noOverflow('登录窄屏不溢出');
    assert(!window.__browserError, '无浏览器运行错误');
    const result = parent.document.createElement('pre'); result.id = 'qa-result'; result.textContent = JSON.stringify({ ok: true, width: innerWidth, checks }); parent.document.body.append(result);
  } catch (error) {
    const result = parent.document.createElement('pre'); result.id = 'qa-result'; result.textContent = JSON.stringify({ ok: false, width: innerWidth, error: error.message, browserError: window.__browserError, checks }); parent.document.body.append(result);
  }
});
