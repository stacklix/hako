'use strict';
const $ = id => document.getElementById(id);
const currentPage = window.location.pathname === '/admin/access-logs' ? 'access-logs' : 'agents';
function showPage() {
  const agents = currentPage === 'agents';
  $('agents-page').hidden = !agents;
  $('access-logs').hidden = agents;
  $('nav-' + currentPage).setAttribute('aria-current', 'page');
  $('page-title').textContent = agents ? '设备代理' : '访问日志';
  $('page-description').textContent = agents ? '管理设备、查看在线状态与调用设备能力。' : '查看 Caddy 访问统计、来源与请求排行。';
  document.title = $('page-title').textContent + ' · Hako 管理控制台';
}
let csrf = '', agentListing = null, selectedKey = null, refreshing = false;
let qrRequest = null, qrTimer = null, qrCountdown = null, qrGeneration = 0, qrStarting = false;
let requestAgentId = null;
const messages = {admin_login_required:'管理登录已到期，请重新扫码。',admin_not_configured:'请先在服务器手工配置 Console 公钥，然后重启服务。',login_request_expired:'二维码已过期，请刷新。',login_request_not_found:'登录请求已失效，请刷新二维码。',login_not_approved:'请先在 Console 核对确认码并批准。',approver_revoked:'批准此登录的 Console 会话已撤销，请重新扫码。',invalid_origin:'访问地址与服务器公开地址不一致，请通过配置的 HTTPS 地址访问。',invalid_csrf:'请求校验失败，请刷新页面后重试。',rate_limited:'请求过于频繁，请稍后重试。',duplicate_agent:'设备 ID 或公钥已经登记。',device_id_unavailable:'暂时无法分配设备 ID，请稍后重试。',agent_offline:'设备当前离线。',agent_disconnected:'设备连接已断开。',agent_timeout:'设备响应超时，动作可能仍在执行，请先确认结果。',agent_busy:'设备正在处理其他请求，请稍后重试。',unsupported_method:'设备不支持此能力或版本，请刷新设备状态。',too_many_requests:'并发请求过多，请稍后重试。',storage_unavailable:'保存失败，请检查服务端存储后重试。',too_many_admin_sessions:'管理会话过多，请稍后重试。'};
function notice(text, success = false) { $('notice').textContent = text; $('notice').className = success ? 'success' : ''; $('notice').hidden = !text; }
Object.assign(messages, {invalid_log_filter:'请选择有效的时间区间、域名和整点小时。',access_logs_disabled:'访问日志统计尚未启用，请在服务器配置日志目录。'});
function stopQr() { qrGeneration++; clearTimeout(qrTimer); clearInterval(qrCountdown); qrRequest = null; $('copy-login').disabled = true; }
function loggedIn(yes) { $('login-panel').hidden = yes; $('dashboard').hidden = !yes; $('account-bar').hidden = !yes; if (yes) { stopQr(); refreshAccessLogs(); } else { csrf = ''; resetAccessLogs(); agentListing = null; requestAgentId = null; $('request-dialog').close(); $('register-dialog').close(); $('key-dialog').close(); } }
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
async function invokeAgent(id, method, version, params) {
  return api('agents/' + encodeURIComponent(id) + '/requests', 'POST', {method,version,params});
}
function showCommands(agent) {
  if (!Array.isArray(agent.capabilities) || !agent.capabilities.length) { notice('设备尚未提供可调用的能力，请等待 Agent 连接后刷新状态。'); return; }
  requestAgentId = agent.id;
  $('request-agent').textContent = agent.name;
  $('request-method').replaceChildren(...agent.capabilities.map(method => {
    const option = node('option', `${method.name} · v${method.version}`); option.value = method.name; option.dataset.version = method.version; return option;
  }));
  $('request-params').value = '{}'; $('request-result').textContent = ''; $('request-error').hidden = true;
  $('request-dialog').showModal();
}
function drawAgents() {
  $('agent-list').replaceChildren();
  if (!agentListing.agents.length) { empty('agent-list','还没有设备代理，登记 Agent 导出的公钥即可开始。'); return; }
  for (const agent of agentListing.agents) {
    const row = node('div',undefined,'device'), info = node('div'), title = node('div',agent.name,'device-title');
    title.append(node('span',agent.online ? '在线' : '离线','badge' + (agent.online ? ' online' : '')));
    info.append(title,node('p',`${agent.id} · 最近活动 ${date(agent.lastSeen)}`,'device-meta'),node('p','公钥指纹 ' + agent.keyId,'device-meta'));
    info.append(node('p', Array.isArray(agent.capabilities) ? `已声明 ${agent.capabilities.length} 项能力` : '能力清单尚未获取', 'device-meta'));
    const actions = node('div',undefined,'device-actions');
    const invoke = action('调用能力', () => showCommands(agent));
    invoke.disabled = !agent.online || !Array.isArray(agent.capabilities) || !agent.capabilities.length;
    actions.append(invoke,action('公钥',() => showKey(agent.name,agent.publicKeyPem,agent.id + '.public.pem')),action('移除',async () => { if (!confirm(`移除「${agent.name}」？当前连接将立即断开。`)) return; await api('agents/' + encodeURIComponent(agent.id),'DELETE'); await refresh(); notice('Agent 已移除。',true); },'danger'));
    row.append(info,actions); $('agent-list').append(row);
  }
}
async function refresh() {
  if (currentPage !== 'agents' || refreshing || !csrf) return;
  refreshing = true;
  try {
    agentListing = await api('agents');
    $('online-count').textContent = agentListing.agents.filter(a => a.online).length;
    $('agent-count').textContent = agentListing.agents.length;
    $('updated').textContent = '状态更新于 ' + date(agentListing.updatedAt);
    drawAgents();
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
function register() { $('register-form').reset(); $('register-error').hidden = true; $('register-title').textContent = '登记设备代理'; $('key-hint').textContent = '请使用 Agent 导出的 RSA 公钥（2048–8192 位）。'; $('register-dialog').showModal(); }
$('open-agent').addEventListener('click',register);
$('close-register').addEventListener('click',() => $('register-dialog').close()); $('close-key').addEventListener('click',() => $('key-dialog').close());
$('public-key-file').addEventListener('change',async event => { try { const file = event.target.files[0]; if (!file) return; if (file.size > 16384) throw new Error('公钥文件过大。'); const text = await file.text(); if (/PRIVATE KEY/.test(text)) throw new Error('请选择公钥文件，不要上传私钥。'); $('register-form').elements.publicKeyPem.value = text; $('register-error').hidden = true; } catch (e) { $('register-error').textContent = e.message; $('register-error').hidden = false; } });
$('register-form').addEventListener('submit',async event => {
  event.preventDefault(); const form = event.currentTarget, button = form.querySelector('button[type=submit]'); button.disabled = true; $('register-error').hidden = true;
  try { const values = new FormData(form); const data = {name:values.get('name'),publicKeyPem:values.get('publicKeyPem')}; if (/PRIVATE KEY/.test(data.publicKeyPem)) throw new Error('请提供公钥，不要上传私钥。'); await api('agents','POST',data); $('register-dialog').close(); await refresh(); notice('公钥已登记，即时生效。',true); }
  catch (e) { $('register-error').textContent = e.message; $('register-error').hidden = false; } finally { button.disabled = false; }
});
$('download-key').addEventListener('click',() => { if (!selectedKey) return; const url = URL.createObjectURL(new Blob([selectedKey.pem],{type:'application/x-pem-file'})); const a = node('a'); a.href = url; a.download = selectedKey.filename; a.click(); setTimeout(() => URL.revokeObjectURL(url),1000); });
$('request-method').addEventListener('change', () => { $('request-params').value = '{}'; $('request-result').textContent = ''; $('request-error').hidden = true; });
$('close-request').addEventListener('click', () => $('request-dialog').close());
$('request-form').addEventListener('submit', async event => {
  event.preventDefault(); const button = $('execute-request'); button.disabled = true;
  $('request-error').hidden = true; $('request-result').textContent = '';
  const agentId = requestAgentId, method = $('request-method').value;
  try {
    const params = JSON.parse($('request-params').value);
    if (!params || typeof params !== 'object' || Array.isArray(params)) throw new Error('参数必须是 JSON 对象。');
    const version = Number($('request-method').selectedOptions[0]?.dataset.version);
    const result = await invokeAgent(agentId, method, version, params);
    $('request-result').textContent = JSON.stringify(result, null, 2);
  } catch (e) { $('request-error').textContent = e.message; $('request-error').hidden = false; }
  finally { button.disabled = false; }
});
setInterval(() => { if (!document.hidden && csrf) refresh().catch(e => notice(e.message)); },10000);
document.addEventListener('DOMContentLoaded', async () => { showPage(); try { const result = await api('session'); csrf = result.csrfToken; $('account').textContent = result.username; loggedIn(true); await refresh(); } catch (e) { loggedIn(false); if (e.message !== messages.admin_login_required) notice(e.message); await startQr(); } }, {once:true});
