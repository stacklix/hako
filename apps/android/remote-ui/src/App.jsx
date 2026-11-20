import { useCallback, useEffect, useRef, useState } from 'react';
import { AlertCircle, CheckCircle2, ChevronDown, LayoutDashboard, Link2, LogOut, PanelLeft, RefreshCw, ScrollText, Send, SlidersHorizontal, Smartphone } from 'lucide-react';
import { api, post } from './api.js';
import { Actions, Logs, Overview } from './ActivityPages.jsx';
import { Commands, Connection, Forwarding } from './ConfigPages.jsx';
import { Button, DialogProvider, Field, SaveForm, useDialog } from './ui.jsx';

const pages = {
  overview: ['首页', 'OVERVIEW', '短信、来电与指令，随时掌握当前运行状态。'],
  forwarding: ['转发配置', 'FORWARDING', '将收到的消息，转发到你需要的地方。'],
  commands: ['指令配置', 'COMMANDS', '管理短信指令与 HTTP 指令的访问方式。'],
  connection: ['连接配置', 'CONNECTION', '管理此设备与 Sora 服务端的连接。'],
  actions: ['操作', 'ACTIONS', '通过当前设备发送短信或发起拨号。'],
  logs: ['日志', 'ACTIVITY LOG', '查看设备最近发生的业务事件。'],
};
const configPages = ['forwarding', 'commands', 'connection'];

export function App() {
  return <div id="doppel-app"><DialogProvider><Application /></DialogProvider></div>;
}

function Application() {
  const [authenticated, setAuthenticated] = useState(null), [snapshot, setSnapshot] = useState({});
  const [agent, setAgent] = useState(null), [agentError, setAgentError] = useState('');
  const [page, setPage] = useState('overview'), [notice, setNotice] = useState(null);
  const [loadError, setLoadError] = useState(''), [pending, setPending] = useState(false);
  const [history, setHistory] = useState([]);
  const timer = useRef(null), mutation = useRef(false);
  const { close } = useDialog();
  const notify = useCallback((type, text) => { setNotice({ type, text }); clearTimeout(timer.current); timer.current = setTimeout(() => setNotice(null), 6500); }, []);
  const refresh = useCallback(async () => { const value = await api('/api/snapshot'); setSnapshot(value); setAuthenticated(true); setLoadError(''); }, []);
  const refreshAgent = useCallback(async () => {
    try { const value = await api('/api/agent/settings'); setAgent(value); setAgentError(''); }
    catch (error) { setAgentError(error.message); }
  }, []);
  useEffect(() => {
    refresh().catch((error) => { if (error.status !== 401) setLoadError(error.message); else setAuthenticated(false); });
    const expired = () => { close(); setAuthenticated(false); setAgent(null); setSnapshot({}); setHistory([]); };
    window.addEventListener('nami-session-expired', expired);
    return () => { clearTimeout(timer.current); window.removeEventListener('nami-session-expired', expired); };
  }, [refresh]);
  useEffect(() => { if (authenticated && page === 'connection') { refreshAgent(); const poll = setInterval(refreshAgent, 3000); return () => clearInterval(poll); } }, [authenticated, page, refreshAgent]);
  useEffect(() => {
    if (!authenticated || page !== 'logs') return;
    const read = () => refresh().catch((error) => { if (error.status === 401) setAuthenticated(false); });
    read(); const poll = setInterval(read, 5000); return () => clearInterval(poll);
  }, [authenticated, page, refresh]);
  const perform = async (task) => { try { await task(); } catch (error) { notify('error', error.message); } };
  const mutate = async (task) => {
    if (mutation.current) throw new Error('正在保存，请稍后重试');
    mutation.current = true; setPending(true);
    try { return await task(); } finally { mutation.current = false; setPending(false); }
  };
  const saveConfig = (partial, message = '保存成功') => mutate(async () => {
    const data = await post('/api/config', { config: partial });
    if (data.snapshot) setSnapshot(data.snapshot); notify('ok', message);
  });
  const saveAgent = (values) => mutate(async () => { const value = await post('/api/agent/settings', values); setAgent(value); notify('ok', 'Hako 配置已保存'); });
  const generateKey = () => mutate(async () => { const value = await post('/api/agent/key', {}); setAgent(value); notify('ok', '设备密钥已生成，请查看公钥并登记到 Sora'); });
  const navigate = (value) => { setPage(value); setNotice(null); };
  const logout = async () => { await post('/logout', {}); setAuthenticated(false); setSnapshot({}); setAgent(null); setHistory([]); setPage('overview'); setNotice(null); };
  const props = { snapshot, saveConfig, perform, pending };
  return <Shell page={page} navigate={navigate} authenticated={authenticated === true} snapshot={snapshot} logout={logout}>
    {authenticated === null ? <div className="dp-empty">{loadError ? <><p role="alert">加载失败：{loadError}</p><Button onClick={() => perform(refresh)}>重试</Button></> : '加载中…'}</div> : !authenticated ? <Login onLogin={refresh} /> : <>
      <div className="dp-pagehead"><div><p className="dp-eyebrow">{pages[page][1]}</p><h1>{pages[page][0]}</h1><p className="dp-description">{pages[page][2]}</p></div>{['overview', 'logs', 'connection'].includes(page) && <div className="dp-page-actions"><Button busy={pending} onClick={() => perform(() => mutate(async () => { await refresh(); if (page === 'connection') await refreshAgent(); }))}><RefreshCw />刷新</Button></div>}</div>
      {notice && <div className={`dp-notice ${notice.type === 'error' ? 'error' : ''}`} role={notice.type === 'error' ? 'alert' : 'status'}>{notice.type === 'error' ? <AlertCircle /> : <CheckCircle2 />}{notice.text}</div>}
      {page === 'overview' && <Overview snapshot={snapshot} navigate={navigate} />}
      {page === 'forwarding' && <Forwarding {...props} />}
      {page === 'commands' && <Commands {...props} />}
      {page === 'connection' && (agentError ? <div className="dp-notice error" role="alert">读取 Hako 配置失败：{agentError}<Button onClick={refreshAgent}>重试</Button></div> : agent ? <Connection agent={agent} saveAgent={saveAgent} generateKey={generateKey} perform={perform} pending={pending} /> : <div className="dp-empty">读取连接配置…</div>)}
      {page === 'actions' && <Actions snapshot={snapshot} notify={notify} history={history} setHistory={setHistory} />}
      {page === 'logs' && <Logs snapshot={snapshot} />}
    </>}
  </Shell>;
}

function Shell({ children, page, navigate, authenticated, snapshot, logout }) {
  const [expanded, setExpanded] = useState(true), [collapsed, setCollapsed] = useState(false), [mobile, setMobile] = useState(false);
  const { open } = useDialog();
  const isConfig = configPages.includes(page);
  const go = (value) => { navigate(value); setMobile(false); if (configPages.includes(value)) setExpanded(true); };
  const menu = (key, label, Icon) => <button type="button" title={label} className={`dp-navitem ${page === key ? 'active' : ''}`} aria-current={page === key ? 'page' : undefined} onClick={() => go(key)}><Icon /><span>{label}</span></button>;
  return <div className={`dp-shell ${collapsed ? 'collapsed' : ''} ${mobile ? 'mobile-menu' : ''}`}>
    <aside className="dp-sidebar" aria-label="主菜单"><div className="dp-brand"><span className="dp-mark" aria-hidden="true"><svg viewBox="0 0 36 36" aria-hidden="true"><path d="M8 12C12 12 12 17 17 17S22 8 26 12M8 23C12 23 12 28 17 28S22 19 26 23" fill="none" stroke="currentColor" strokeWidth="3.5" /></svg></span><strong>Nami<span>远程控制</span></strong></div><div className="dp-workspace">工作空间<span>个人</span></div>{authenticated && <><nav className="dp-nav">{menu('overview', '首页', LayoutDashboard)}<button type="button" title="配置" className={`dp-navitem ${isConfig ? 'active' : ''}`} aria-expanded={expanded} onClick={() => { if (collapsed) { setCollapsed(false); setExpanded(true); } else setExpanded(!expanded); }}><SlidersHorizontal /><span>配置</span><ChevronDown className="dp-chevron" /></button><div className="dp-subnav" hidden={!expanded}>{configPages.map((key) => <button type="button" key={key} className={page === key ? 'active' : ''} aria-current={page === key ? 'page' : undefined} onClick={() => go(key)}>{pages[key][0]}</button>)}</div>{menu('actions', '操作', Send)}{menu('logs', '日志', ScrollText)}</nav><div className="dp-sidebar-bottom"><div className="dp-side-status"><span className="dp-dot" />{snapshot.remoteControlStatus?.isRunning ? 'HTTP 服务运行中' : 'HTTP 服务未运行'}</div><div className="dp-session"><span className="dp-session-icon"><Smartphone /></span><div><strong>当前设备</strong><small>Nami · Android</small></div><Button icon aria-label="退出登录" onClick={() => open('退出远程控制', <SaveForm submit="退出" onSave={logout}><p>退出当前管理会话？</p></SaveForm>)}><LogOut /></Button></div></div></>}</aside>
    {mobile && <button type="button" className="dp-menu-scrim" aria-label="关闭菜单" onClick={() => setMobile(false)} />}
    <div className="dp-main"><header className="dp-topbar"><div><Button icon aria-label="收起或展开侧栏" aria-expanded={window.innerWidth <= 660 ? mobile : !collapsed} onClick={() => { if (window.innerWidth <= 660) { setCollapsed(false); setMobile(!mobile); } else setCollapsed(!collapsed); }}><PanelLeft /></Button><span className="dp-top-brand">工作空间</span><span className="dp-slash">/</span><strong>{authenticated ? `${isConfig ? '配置 / ' : ''}${pages[page][0]}` : '登录'}</strong></div><span className="dp-demo">Nami · Android</span></header><main className="dp-body">{children}<footer className="dp-footer"><span><Link2 />Nami · 让你的手机，始终在身边</span><span>远程控制</span></footer></main></div>
  </div>;
}

function Login({ onLogin }) {
  const [pending, setPending] = useState(false), [error, setError] = useState('');
  return <div className="dp-login"><span className="dp-badge">Nami 远程控制</span><h2>欢迎回来</h2><p>输入管理密码，连接你的手机。</p><form onSubmit={async (event) => {
    event.preventDefault(); if (pending) return; const { password } = Object.fromEntries(new FormData(event.currentTarget));
    setPending(true); setError(''); try { await post('/login', { password }); await onLogin(); } catch (failure) { setError(failure.message); } finally { setPending(false); }
  }}><Field label="管理密码" name="password" type="password" autoComplete="current-password" required /><Button type="submit" primary busy={pending}>登录</Button>{error && <div className="dp-dialog-error" role="alert">{error}</div>}</form></div>;
}
