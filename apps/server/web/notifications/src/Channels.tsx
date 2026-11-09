import { useEffect, useState } from 'react';
import { FileText, MessageSquare, Play, QrCode, RefreshCw, ShieldCheck, Unplug } from 'lucide-react';
import type { Bot, BotLog, LoginSession } from '../shared/types';
import type { Navigate } from './App';
import { api, post, remove } from './api';
import { PushSettings } from './PushSettings';
import { Button, ErrorLine, Loading, Modal, Status, fullTime, relative, useResource } from './ui';

export interface WechatChannel { connection: Bot | null }

interface Props {
  wechat: Bot | null;
  wechatReady: boolean;
  revision: number;
  refresh: () => void;
  notify: (message: string) => void;
  navigate: Navigate;
}

export function ChannelsPage({ wechat, wechatReady, revision, refresh, notify, navigate }: Props) {
  const [loginId, setLoginId] = useState<string | null>(null);
  const [showLogs, setShowLogs] = useState(false);
  const [confirmation, setConfirmation] = useState<'disconnect' | 'clear' | null>(null);
  const [error, setError] = useState(''), [busy, setBusy] = useState(false);
  const connected = wechat && ['online', 'connecting', 'reconnecting'].includes(wechat.status);
  const needsLogin = !wechat?.hasCredentials || wechat.status === 'expired';
  const canConfigure = !wechat || ['stopped', 'pending', 'expired'].includes(wechat.status);
  const logs = useResource<BotLog[]>(showLogs && wechat ? `/bots/${wechat.id}/logs` : null, revision);

  async function updateConnection() {
    if (busy || !wechatReady) return;
    if (connected) {
      setConfirmation('disconnect');
      return;
    }
    if (!canConfigure) return;
    setBusy(true);
    setError('');
    try {
      if (needsLogin) {
        const connection = wechat ?? (await api<WechatChannel>('/channels/wechat', { method: 'PUT', body: '{}' })).connection;
        if (!connection) throw new Error('暂时无法初始化微信渠道，请重试。');
        setLoginId(connection.id);
      } else {
        await post(`/bots/${wechat.id}/connect`);
      }
      refresh();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return <div className="page-content settings-stack">
    <section className="panel">
      <div className="panel-header">
        <div><h2>微信</h2><p>通过微信扫码绑定一个账号，收发文本和图片通知</p></div>
        <MessageSquare size={21} />
      </div>
      <div className="settings-form">
        {wechatReady && <div className="webhook-target-hint">
          {wechat?.accountId ? <>
            <strong>已绑定账号</strong>
            <p className="break-all">{wechat.accountId} · 最近同步 {relative(wechat.lastSeenAt)}</p>
          </> : <p>尚未绑定微信账号。扫码成功后，在微信中发一条消息即可建立会话。</p>}
          {wechat && <Status status={wechat.status} bot />}
        </div>}
        <ErrorLine error={error || wechat?.lastError || ''} />
        <div className="inline-actions">
          <Button busy={busy} disabled={!wechatReady || (!connected && !canConfigure)} icon={connected ? Unplug : needsLogin ? QrCode : Play} onClick={updateConnection}>
            {connected ? '断开连接' : !canConfigure ? '正在扫码绑定' : needsLogin ? '扫码绑定微信' : '启动连接'}
          </Button>
          {canConfigure && wechat?.hasCredentials && !needsLogin && <Button variant="secondary" disabled={busy} icon={QrCode} onClick={() => setLoginId(wechat.id)}>重新配置</Button>}
          {wechat?.conversationId && <Button variant="secondary" icon={MessageSquare} onClick={() => navigate('messages', wechat.id)}>查看会话</Button>}
          {wechat && <Button variant="ghost" icon={FileText} onClick={() => setShowLogs(true)}>连接记录</Button>}
          {canConfigure && wechat?.hasCredentials && <Button variant="ghost" disabled={busy} icon={Unplug} onClick={() => setConfirmation('clear')}>清除授权</Button>}
        </div>
      </div>
    </section>
    <PushSettings revision={revision} refresh={refresh} notify={notify} />
    {confirmation && wechat && <ConnectionConfirmation key={`${wechat.id}:${wechat.accountId}:${confirmation}`} connection={wechat} action={confirmation}
      allowed={confirmation === 'disconnect' ? !!connected : canConfigure} onClose={() => setConfirmation(null)}
      onConfirmed={() => { setConfirmation(null); refresh(); notify(confirmation === 'disconnect' ? '微信连接已断开，可以重新配置' : '微信授权已清除'); }} />}
    {loginId && <LoginModal connectionId={loginId} onClose={() => { setLoginId(null); refresh(); }}
      onConnected={() => { refresh(); notify('微信授权成功，正在建立消息连接'); }}
      onMessages={() => navigate('messages', loginId)} />}
    {showLogs && <Modal title="微信连接记录" onClose={() => setShowLogs(false)} wide>
      <div className="settings-form">
        <ErrorLine error={logs.error} />
        {logs.loading && !logs.data ? <Loading /> : !logs.data?.length ? <p className="quiet">暂无连接记录。</p> :
          <div className="log-list">{logs.data.map(log => <div key={log.id}><span className={`log-dot ${log.level}`} /><p>{log.detail}<small>{fullTime(log.createdAt)}</small></p></div>)}</div>}
      </div>
    </Modal>}
  </div>;
}

function ConnectionConfirmation({ connection, action, allowed, onClose, onConfirmed }: {
  connection: Bot; action: 'disconnect' | 'clear'; allowed: boolean; onClose: () => void; onConfirmed: () => void;
}) {
  const [account, setAccount] = useState(''), [busy, setBusy] = useState(false), [error, setError] = useState('');
  const matches = !!connection.accountId && account === connection.accountId;
  const clearing = action === 'clear';
  return <Modal title={clearing ? '清除微信授权' : '断开微信连接'} onClose={() => { if (!busy) onClose(); }}>
    <form className="modal-form" onSubmit={async e => {
      e.preventDefault();
      if (busy || !allowed || !matches) return;
      setBusy(true); setError('');
      try {
        if (clearing) await remove(`/bots/${connection.id}/credentials`);
        else await post(`/bots/${connection.id}/disconnect`);
        onConfirmed();
      } catch (e) { setError((e as Error).message); }
      finally { setBusy(false); }
    }}>
      <p>{clearing ? '清除授权后，需要重新扫码才能恢复连接。' : '断开后将停止收发微信消息，排队中的消息会被标记为失败。断开成功后才能重新配置。'}</p>
      <p>请输入当前绑定账号 <strong className="break-all">{connection.accountId}</strong> 以确认操作。</p>
      <label>绑定账号<input autoFocus value={account} onChange={e => setAccount(e.target.value)} disabled={busy} autoComplete="off" spellCheck={false} required placeholder="输入完整的绑定账号" /></label>
      {account && !matches && <p className="quiet">输入的账号与当前绑定账号不一致。</p>}
      <ErrorLine error={error || (!allowed ? '连接状态已变化，请关闭弹窗后重试。' : '')} />
      <div className="modal-footer"><Button type="button" variant="secondary" disabled={busy} onClick={onClose}>取消</Button>
        <Button type="submit" variant="danger" busy={busy} disabled={!allowed || !matches}>{clearing ? '确认清除授权' : '确认断开连接'}</Button></div>
    </form>
  </Modal>;
}

function LoginModal({ connectionId, onClose, onConnected, onMessages }: {
  connectionId: string; onClose: () => void; onConnected: () => void; onMessages: () => void;
}) {
  const [session, setSession] = useState<LoginSession | null>(null), [error, setError] = useState('');
  const [busy, setBusy] = useState(true), [code, setCode] = useState(''), [generation, setGeneration] = useState(0);
  const loginPath = `/bots/${connectionId}/login-sessions`;
  useEffect(() => {
    let cancelled = false;
    setBusy(true); setError(''); setSession(null);
    post<LoginSession>(loginPath)
      .then(value => { if (!cancelled) setSession(value); })
      .catch(error => { if (!cancelled) setError(error.message); })
      .finally(() => { if (!cancelled) setBusy(false); });
    return () => { cancelled = true; };
  }, [loginPath, generation]);
  useEffect(() => {
    if (!session || ['confirmed', 'expired', 'verify_code_blocked', 'error'].includes(session.status)) return;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout>;
    const poll = async () => {
      try {
        const next = await api<LoginSession>(`${loginPath}/${session.id}`);
        if (cancelled) return;
        setSession(next);
        if (next.status === 'confirmed') onConnected();
        else if (!['expired', 'verify_code_blocked', 'error'].includes(next.status)) timer = setTimeout(poll, 1800);
      } catch (e) {
        if (cancelled) return;
        setError((e as Error).message);
        timer = setTimeout(poll, 3000);
      }
    };
    timer = setTimeout(poll, 1200);
    return () => { cancelled = true; clearTimeout(timer); };
  }, [loginPath, session?.id, generation]);
  const labels: Record<string, string> = {
    wait: '打开微信，扫描二维码', scaned: '已扫码，请在微信中确认授权', expired: '二维码已过期',
    need_verifycode: '请输入微信中显示的验证码', verify_code_blocked: '验证次数过多，请刷新二维码',
    error: '登录未完成', scaned_but_redirect: '已扫码，正在完成授权',
  };
  const renew = () => setGeneration(value => value + 1);
  return <Modal title="绑定微信" onClose={onClose}>
    <div className="qr-content">
      {busy ? <div className="qr-placeholder"><Loading /></div> : session?.status === 'confirmed' ?
        <div className="qr-success"><ShieldCheck size={53} /><h3>微信已绑定</h3><p>在微信里发一条消息，即可在消息中心看到会话。</p></div> : session && <>
          <div className="qr-frame">
            <img src={session.qrImage} width={240} height={240} alt="微信授权二维码" />
            {['expired', 'error', 'verify_code_blocked'].includes(session.status) &&
              <div className="qr-overlay"><Button icon={RefreshCw} onClick={renew}>刷新二维码</Button></div>}
          </div>
          <strong>{labels[session.status] || '正在等待微信授权'}</strong>
          <p className="quiet small">请使用支持微信 iLink 的账号扫码</p>
        </>}
      <ErrorLine error={error || session?.error || ''} />
      {session?.status === 'need_verifycode' && <form className="verify-form" onSubmit={async e => {
        e.preventDefault();
        setError('');
        try { await post(`${loginPath}/${session.id}/verify`, { code }); setCode(''); }
        catch (error) { setError((error as Error).message); }
      }}>
        <input value={code} onChange={e => setCode(e.target.value)} aria-label="验证码" placeholder="输入验证码" required maxLength={32} />
        <Button type="submit">提交</Button>
      </form>}
      {session?.status === 'confirmed' ? <Button icon={MessageSquare} onClick={onMessages}>进入消息中心</Button> :
        !busy && <Button variant="ghost" icon={RefreshCw} onClick={renew}>重新获取二维码</Button>}
    </div>
  </Modal>;
}
