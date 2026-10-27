'use strict';
const $ = id => document.getElementById(id);
let csrf = '', overview = null, selectedKey = null, refreshing = false;
let qrRequest = null, qrTimer = null, qrCountdown = null, qrGeneration = 0, qrStarting = false;
let requestAgentId = null;
const samples = new Map();
const messages = {admin_login_required:'管理登录已到期，请重新扫码。',admin_not_configured:'请先在服务器手工配置 Console 公钥，然后重启服务。',login_request_expired:'二维码已过期，请刷新。',login_request_not_found:'登录请求已失效，请刷新二维码。',login_not_approved:'请先在 Console 核对确认码并批准。',approver_revoked:'批准此登录的 Console 会话已撤销，请重新扫码。',invalid_origin:'访问地址与服务器公开地址不一致，请通过配置的 HTTPS 地址访问。',invalid_csrf:'请求校验失败，请刷新页面后重试。',rate_limited:'请求过于频繁，请稍后重试。',duplicate_agent:'设备 ID 或公钥已经登记。',agent_offline:'设备当前离线。',agent_disconnected:'设备连接已断开。',agent_timeout:'设备响应超时，动作可能仍在执行，请先确认结果。',agent_busy:'设备正在处理其他请求，请稍后重试。',unsupported_method:'设备不支持此动作，请刷新设备状态。',too_many_requests:'并发请求过多，请稍后重试。',storage_unavailable:'保存失败，请检查服务端存储后重试。',too_many_admin_sessions:'管理会话过多，请稍后重试。'};
function notice(text, success = false) { $('notice').textContent = text; $('notice').className = success ? 'success' : ''; $('notice').hidden = !text; }
function stopQr() { qrGeneration++; clearTimeout(qrTimer); clearInterval(qrCountdown); qrRequest = null; $('copy-login').disabled = true; }
function loggedIn(yes) { $('login-panel').hidden = yes; $('dashboard').hidden = !yes; $('account-bar').hidden = !yes; if (yes) stopQr(); else { csrf = ''; overview = null; samples.clear(); requestAgentId = null; $('request-dialog').close(); $('register-dialog').close(); $('key-dialog').close(); } }
async function api(path, method = 'GET', data) {
  const headers = { 'Content-Type':'application/json' };
  if (method !== 'GET' && csrf) headers['X-CSRF-Token'] = csrf;
  const response = await fetch('/admin/api/' + path, { method, headers, credentials:'same-origin', cache:'no-store', body:data === undefined ? undefined : JSON.stringify(data), signal:AbortSignal.timeout(20000) });
  const result = await response.json();
  if (!response.ok) { if (response.status === 401 && !path.startsWith('login/')) { loggedIn(false); if (path !== 'session') { notice(messages.admin_login_required); startQr(); } } throw new Error(messages[result.error] || result.message || '操作失败，请稍后重试。'); }
  return result;
}
function node(tag, text, className) { const el = document.createElement(tag); if (text !== undefined) el.textContent = text; if (className) el.className = className; return el; }
function action(text, fn, className = '') { const el = node('button', text, className); el.type = 'button'; el.addEventListener('click', async () => { el.disabled = true; try { await fn(); } catch (e) { notice(e.message); } finally { el.disabled = false; } }); return el; }
function date(text) { return text ? new Date(text).toLocaleString('zh-CN', { hour12:false }) : '尚未连接'; }
function empty(target, text) { $(target).replaceChildren(node('p', text, 'empty')); }
function showKey(name, pem, filename) { selectedKey = {name,pem,filename}; $('key-name').textContent = name; $('key-pem').textContent = pem; $('key-dialog').showModal(); }
async function invokeAgent(id, method, params) {
  const reply = await api('agents/' + encodeURIComponent(id) + '/requests', 'POST', {method,params});
  if (reply.error) throw new Error(reply.error.message || reply.error.code);
  if (!Object.hasOwn(reply, 'result')) throw new Error('设备未返回执行结果。');
  return reply.result;
}
function showActions(agent) {
  requestAgentId = agent.id;
  $('request-agent').textContent = agent.name;
  $('request-method').replaceChildren(...agent.methods.map(method => {
    const option = node('option', `${method.name} · v${method.version}`); option.value = method.name; return option;
  }));
  $('request-params').value = '{}'; $('request-result').textContent = ''; $('request-error').hidden = true;
  $('request-dialog').showModal();
}
function drawAgents() {
  $('agent-list').replaceChildren();
  if (!overview.agents.length) { empty('agent-list','还没有设备代理，登记 Windows 导出的公钥即可开始。'); return; }
  for (const agent of overview.agents) {
    const row = node('div',undefined,'device'), info = node('div'), title = node('div',agent.name,'device-title');
    title.append(node('span',agent.online ? '在线' : '离线','badge' + (agent.online ? ' online' : '')));
    info.append(title,node('p',`${agent.id} · 最近活动 ${date(agent.lastSeen)}`,'device-meta'),node('p','公钥指纹 ' + agent.keyId,'device-meta'));
    const sample = samples.get(agent.id);
    if (sample) info.append(node('div',`CPU ${sample.cpuUsagePercent.toFixed(1)}%　·　内存 ${sample.memoryUsagePercent.toFixed(1)}%（${(sample.memoryUsedBytes / 1073741824).toFixed(1)} / ${(sample.memoryTotalBytes / 1073741824).toFixed(1)} GiB）\n采样于 ${date(sample.sampledAt)}`,'metrics'));
    const actions = node('div',undefined,'device-actions');
    const query = action('查询指标',async () => {
      samples.delete(agent.id);
      const sample = await invokeAgent(agent.id, 'system.metrics', {});
      if (!sample || !['cpuUsagePercent','memoryUsagePercent','memoryUsedBytes','memoryTotalBytes'].every(key => Number.isFinite(sample[key])) || sample.cpuUsagePercent < 0 || sample.cpuUsagePercent > 100 || sample.memoryUsagePercent < 0 || sample.memoryUsagePercent > 100 || sample.memoryTotalBytes <= 0 || sample.memoryUsedBytes < 0 || sample.memoryUsedBytes > sample.memoryTotalBytes || !Number.isInteger(sample.sampleWindowMs) || sample.sampleWindowMs < 500 || sample.sampleWindowMs > 5000 || Math.abs(sample.memoryUsagePercent - sample.memoryUsedBytes / sample.memoryTotalBytes * 100) >= 0.1 || !Number.isFinite(Date.parse(sample.sampledAt))) throw new Error('设备返回的指标格式无效。');
      samples.set(agent.id,sample); drawAgents(); notice('已获取最新指标。',true);
    }); query.disabled = !agent.online || !agent.methods.some(method => method.name === 'system.metrics' && method.version === 1);
    const invoke = action('执行动作', () => showActions(agent)); invoke.disabled = !agent.online || !agent.methods.length;
    actions.append(query,invoke,action('公钥',() => showKey(agent.name,agent.publicKeyPem,agent.id + '.public.pem')),action('移除',async () => { if (!confirm(`移除「${agent.name}」？当前连接将立即断开。`)) return; await api('agents/' + encodeURIComponent(agent.id),'DELETE'); samples.delete(agent.id); await refresh(); notice('Agent 已移除。',true); },'danger'));
    row.append(info,actions); $('agent-list').append(row);
  }
}
function drawConsoles() {
  $('console-list').replaceChildren();
  if (!overview.consoles.length) { empty('console-list','还没有管理客户端，登记 iOS 导出的 P-256 公钥。'); return; }
  for (const console of overview.consoles) {
    const row = node('div',undefined,'device'), info = node('div'), actions = node('div',undefined,'device-actions');
    const count = overview.sessions.filter(s => s.deviceId === console.id).length;
    info.append(node('div',console.name,'device-title'),node('p',`设备 ID ${console.id}`,'device-meta'),node('p',`${count} 个登录会话`,'device-meta'));
    info.append(node('p','管理员 · 允许批准网页登录','device-meta'));
    actions.append(action('公钥',() => showKey(console.name,console.publicKeyPem,'console.public.pem')));
    row.append(info,actions); $('console-list').append(row);
  }
}
function drawSessions() {
  $('session-list').replaceChildren(); $('session-count').textContent = overview.sessions.length + ' 个会话';
  if (!overview.sessions.length) { empty('session-list','暂无 Console 登录会话。'); return; }
  for (const session of overview.sessions) {
    const row = node('div',undefined,'device'), info = node('div'), actions = node('div',undefined,'device-actions');
    const console = overview.consoles.find(c => c.id === session.deviceId);
    info.append(node('div',console ? console.name : 'Console','device-title'),node('p','登录于 ' + date(session.createdAt),'device-meta'),node('p','设备 ID ' + session.deviceId,'device-meta'));
    actions.append(action('撤销会话',async () => { if (!confirm('撤销此 Console 的登录会话？')) return; await api('sessions/' + encodeURIComponent(session.id),'DELETE'); await refresh(); notice('会话已撤销。',true); },'danger'));
    row.append(info,actions); $('session-list').append(row);
  }
}
async function refresh() {
  if (refreshing || !csrf) return;
  refreshing = true;
  try {
    overview = await api('overview');
    $('online-count').textContent = overview.agents.filter(a => a.online).length;
    $('agent-count').textContent = overview.agents.length; $('console-count').textContent = overview.consoles.length;
    $('updated').textContent = '状态更新于 ' + date(overview.updatedAt);
    drawAgents(); drawConsoles(); drawSessions();
  } finally { refreshing = false; }
}
async function startQr() {
  if (qrStarting || !$('dashboard').hidden) return;
  qrStarting = true; stopQr(); const generation = qrGeneration;
  $('refresh-qr').disabled = true; $('login-qr').hidden = true; $('qr-status').textContent = '正在准备二维码…'; $('qr-code').textContent = '— — — — — —'; $('qr-expiry').textContent = '';
  try {
    const request = await api('login/requests','POST',{}); if (generation !== qrGeneration) return;
    qrRequest = request; $('copy-login').disabled = false; $('qr-code').textContent = request.confirmationCode;
    $('login-qr').src = '/admin/api/login/requests/' + request.id + '/qr'; $('login-qr').hidden = false; $('qr-status').textContent = '等待 Console 扫码';
    const countdown = () => { const left = Math.max(0,Math.ceil((Date.parse(request.expiresAt) - Date.now()) / 1000)); $('qr-expiry').textContent = left ? `${left} 秒后过期` : '二维码已过期，请刷新。'; if (!left) { clearTimeout(qrTimer); clearInterval(qrCountdown); $('copy-login').disabled = true; $('qr-status').textContent = '二维码已过期'; $('login-qr').hidden = true; } };
    countdown(); qrCountdown = setInterval(countdown,1000);
    const poll = async () => {
      if (generation !== qrGeneration) return;
      try {
        const state = await api('login/requests/' + request.id); if (generation !== qrGeneration) return;
        if (state.status === 'denied') { $('qr-status').textContent = 'Console 已拒绝此次登录'; $('qr-expiry').textContent = '请刷新二维码后重新发起请求。'; clearInterval(qrCountdown); $('login-qr').hidden = true; $('copy-login').disabled = true; return; }
        if (state.status === 'approved') {
          $('refresh-qr').disabled = true; $('qr-status').textContent = '已批准，正在建立会话…';
          let result;
          try { result = await api('login/requests/' + request.id + '/complete','POST',{}); }
          catch (error) { try { result = await api('session'); } catch { throw error; } }
          if (generation !== qrGeneration) return;
          csrf = result.csrfToken; $('account').textContent = result.username; loggedIn(true); notice(''); await refresh(); return;
        }
        $('qr-status').textContent = state.status === 'scanned' ? '已扫码，请在 Console 核对确认码并批准' : '等待 Console 扫码';
        qrTimer = setTimeout(poll,request.pollIntervalMs);
      } catch (e) { if (generation === qrGeneration) { clearInterval(qrCountdown); $('qr-status').textContent = e.message; $('login-qr').hidden = true; $('copy-login').disabled = true; notice(e.message); } }
      finally { $('refresh-qr').disabled = false; }
    };
    qrTimer = setTimeout(poll,request.pollIntervalMs);
  } catch (e) { $('qr-status').textContent = '暂时无法生成二维码'; notice(e.message); }
  finally { qrStarting = false; $('refresh-qr').disabled = false; }
}
$('refresh-qr').addEventListener('click',startQr);
$('copy-login').addEventListener('click',async () => { if (!qrRequest) return; try { await navigator.clipboard.writeText(qrRequest.qrPayload); notice('已复制，请在 Console 中粘贴并核对确认码。',true); } catch { notice('无法访问剪贴板，请使用 Console 摄像头扫码。'); } });
$('logout').addEventListener('click',async () => { try { await api('logout','POST',{}); loggedIn(false); notice('已退出管理。',true); await startQr(); } catch (e) { notice(e.message); } });
$('refresh').addEventListener('click',() => refresh().catch(e => notice(e.message)));
function register() { $('register-form').reset(); $('register-error').hidden = true; $('register-title').textContent = '登记设备代理'; $('register-form').elements.id.required = true; $('key-hint').textContent = '请使用 Windows Agent 导出的 RSA 公钥（2048–8192 位）。'; $('register-dialog').showModal(); }
$('open-agent').addEventListener('click',register);
$('close-register').addEventListener('click',() => $('register-dialog').close()); $('close-key').addEventListener('click',() => $('key-dialog').close());
$('public-key-file').addEventListener('change',async event => { try { const file = event.target.files[0]; if (!file) return; if (file.size > 16384) throw new Error('公钥文件过大。'); const text = await file.text(); if (/PRIVATE KEY/.test(text)) throw new Error('请选择公钥文件，不要上传私钥。'); $('register-form').elements.publicKeyPem.value = text; $('register-error').hidden = true; } catch (e) { $('register-error').textContent = e.message; $('register-error').hidden = false; } });
$('register-form').addEventListener('submit',async event => {
  event.preventDefault(); const form = event.currentTarget, button = form.querySelector('button[type=submit]'); button.disabled = true; $('register-error').hidden = true;
  try { const values = new FormData(form); const data = {name:values.get('name'),publicKeyPem:values.get('publicKeyPem')}; if (/PRIVATE KEY/.test(data.publicKeyPem)) throw new Error('请提供公钥，不要上传私钥。'); data.id = values.get('id'); await api('agents','POST',data); $('register-dialog').close(); await refresh(); notice('公钥已登记，即时生效。',true); }
  catch (e) { $('register-error').textContent = e.message; $('register-error').hidden = false; } finally { button.disabled = false; }
});
$('download-key').addEventListener('click',() => { if (!selectedKey) return; const url = URL.createObjectURL(new Blob([selectedKey.pem],{type:'application/x-pem-file'})); const a = node('a'); a.href = url; a.download = selectedKey.filename; a.click(); setTimeout(() => URL.revokeObjectURL(url),1000); });
$('close-request').addEventListener('click', () => $('request-dialog').close());
$('request-form').addEventListener('submit', async event => {
  event.preventDefault(); const button = $('execute-request'); button.disabled = true;
  $('request-error').hidden = true; $('request-result').textContent = '';
  const agentId = requestAgentId, method = $('request-method').value;
  try {
    const params = JSON.parse($('request-params').value);
    if (!params || typeof params !== 'object' || Array.isArray(params)) throw new Error('参数必须是 JSON 对象。');
    const result = await invokeAgent(agentId, method, params);
    $('request-result').textContent = JSON.stringify(result, null, 2);
  } catch (e) { $('request-error').textContent = e.message; $('request-error').hidden = false; }
  finally { button.disabled = false; }
});
setInterval(() => { if (!document.hidden && csrf) refresh().catch(e => notice(e.message)); },10000);
(async () => { try { const result = await api('session'); csrf = result.csrfToken; $('account').textContent = result.username; loggedIn(true); await refresh(); } catch (e) { loggedIn(false); if (e.message !== messages.admin_login_required) notice(e.message); await startQr(); } })();
