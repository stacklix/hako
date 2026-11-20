export async function api(path, options = {}) {
  const response = await fetch(path, { ...options, headers: { 'Content-Type': 'application/json', ...options.headers } });
  const data = await response.json();
  if (!response.ok) {
    if (response.status === 401 && path !== '/login') window.dispatchEvent(new Event('nami-session-expired'));
    const error = new Error(data.message || ({ unauthorized: '登录已过期，请重新登录', invalid_password: '管理密码错误', too_many_attempts: '尝试次数过多，请稍后再试' })[data.error] || `请求失败（${response.status}）`);
    error.status = response.status; throw error;
  }
  return data;
}

export const post = (path, body) => api(path, { method: 'POST', body: JSON.stringify(body) });
export const simLabel = (sim) => sim ? `${sim.displayName || '未命名卡'} · ${sim.number || '未读取号码'}` : '';
export const phoneKey = (value) => value.replace(/[\s-]/g, '');
export function requirePhone(value) {
  if (!/^\+?\d{5,20}$/.test(phoneKey(value))) throw new Error('请输入有效的手机号');
}
export function requireEmail(value) {
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)) throw new Error('请输入有效的邮箱地址');
}
export function requireHttp(value) {
  try { const url = new URL(value); if (!['http:', 'https:'].includes(url.protocol) || !url.hostname) throw 0; }
  catch { throw new Error('请输入完整的 HTTP 或 HTTPS 地址'); }
}
export function requireOrigin(value) {
  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' || !url.hostname || url.username || url.password || !['', '/'].includes(url.pathname) || url.search || url.hash || url.port === '0') throw 0;
    return url.origin;
  } catch { throw new Error('请输入 HTTPS 服务器地址，不包含路径、账号或查询参数'); }
}
export function requirePort(value) {
  if (!/^\d+$/.test(value) || +value < 1024 || +value > 65535) throw new Error('端口应为 1024 到 65535 之间的整数');
}
