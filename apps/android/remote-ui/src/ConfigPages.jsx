import { useRef, useState } from 'react';
import { Globe, Mail, MessageSquare, Plus, ShieldCheck, Trash2 } from 'lucide-react';
import { Badge, Button, Field, Note, Panel, SaveForm, SummaryRow, SwitchRow, Tabs, useDialog } from './ui.jsx';
import { phoneKey, requireEmail, requireHttp, requireOrigin, requirePhone, requirePort, simLabel } from './api.js';

export function SimSelect({ snapshot, name = 'sim', value, label = '发送 SIM 卡' }) {
  const cards = snapshot.simCards || [];
  const options = cards.map(simLabel);
  return <Field label={label}><select name={name} defaultValue={value || options[0] || ''} disabled={!cards.length}>{value && !options.includes(value) && <option value={value}>{value}（当前配置）</option>}{cards.length ? cards.map((sim) => <option key={sim.subscriptionId} value={simLabel(sim)}>{simLabel(sim)}</option>) : <option value="">默认发送卡</option>}</select></Field>;
}

const targetTypes = {
  sms: { title: '接收手机号', add: '添加手机号', label: '手机号', key: 'smsTargets', Icon: MessageSquare, type: 'tel', placeholder: '+86 13800138000', validate: requirePhone },
  email: { title: '邮箱收件人', add: '添加邮箱', label: '邮箱地址', key: 'emailTargets', Icon: Mail, type: 'email', placeholder: 'notify@example.com', validate: requireEmail },
  http: { title: 'HTTP 推送地址', add: '添加 HTTP 地址', label: '推送地址', key: 'httpTargets', Icon: Globe, type: 'url', placeholder: 'https://example.com/hooks/nami', validate: requireHttp },
};

export function Forwarding({ snapshot, saveConfig, perform, pending }) {
  const [tab, setTab] = useState('sms');
  const { open } = useDialog();
  const forwarding = snapshot.config?.forwarding || {};
  const c = targetTypes[tab], items = forwarding[c.key] || [];
  const selected = forwarding.selectedSmsSim || simLabel(snapshot.simCards?.[0]);
  const smtp = forwarding.smtp || {};
  const add = () => open(c.add, <SaveForm submit={c.add} description={`添加${c.label}后，收到的短信将转发到此目标。`} onSave={async ({ target }) => {
    const value = target.trim(); c.validate(value);
    const key = tab === 'sms' ? phoneKey : (v) => v;
    if (items.some((item) => key(item.value) === key(value))) throw new Error('此目标已存在，请勿重复添加');
    await saveConfig({ forwarding: { [c.key]: [...items, { value }] } }, '转发目标已添加');
  }}><Field label={c.label} name="target" type={c.type} placeholder={c.placeholder} autoComplete="off" required /></SaveForm>);
  const editSmtp = () => open('SMTP 发件配置', <SaveForm submit="保存 SMTP" onSave={async (form) => {
    const port = form.port.trim(); if (!/^\d+$/.test(port) || +port < 1 || +port > 65535) throw new Error('请输入有效的 SMTP 端口');
    requireEmail(form.fromEmail.trim());
    const next = { host: form.host.trim(), port, fromEmail: form.fromEmail.trim(), username: form.username.trim() };
    if (form.password) next.password = form.password;
    await saveConfig({ forwarding: { smtp: next } }, 'SMTP 已保存');
  }}><div className="dp-fields"><Field label="服务器" name="host" defaultValue={smtp.host || ''} placeholder="smtp.example.com" required /><Field label="端口" name="port" defaultValue={smtp.port || '465'} inputMode="numeric" required /><Field label="发件邮箱" name="fromEmail" type="email" defaultValue={smtp.fromEmail || ''} required /><Field label="用户名" name="username" defaultValue={smtp.username || ''} /></div><Field label="密码" name="password" type="password" autoComplete="new-password" hint={smtp.password ? '已配置；留空保持当前密码。' : '输入 SMTP 密码。'} /></SaveForm>);
  return <><Tabs items={Object.entries(targetTypes).map(([key, item]) => [key, key === 'sms' ? '手机号' : key === 'email' ? '邮箱' : 'HTTP 地址', item.Icon])} value={tab} onChange={setTab} />
    {tab === 'sms' && <Panel title="发送 SIM 卡" description="短信转发使用此 SIM 卡发送。"><div className="dp-inline-summary"><div><strong>{selected || '默认发送卡'}</strong><p>默认发送卡</p></div><Button onClick={() => open('切换发送 SIM 卡', <SaveForm onSave={({ sim }) => saveConfig({ forwarding: { selectedSmsSim: sim ?? selected ?? '' } }, '发送 SIM 卡已保存')}><SimSelect snapshot={snapshot} value={selected} /></SaveForm>)}>切换</Button></div></Panel>}
    {tab === 'email' && <Panel title="SMTP 发件配置" description="邮箱转发使用此发件人。"><div className="dp-inline-summary"><div><strong>{smtp.fromEmail || '未配置发件邮箱'}</strong><p>{smtp.host ? `${smtp.host}:${smtp.port || '465'}` : '配置 SMTP 后才能自动转发到邮箱'}</p></div><Button onClick={editSmtp}>编辑</Button></div></Panel>}
    <Panel title={c.title} description="管理接收转发消息的目标。" action={<Button primary onClick={add}><Plus />{c.add}</Button>}><div className="dp-form">{items.length ? items.map((item, index) => <div className="dp-target-row" key={`${item.value}-${index}`}><div><c.Icon /><span>{item.value}</span></div><Button icon className="dp-danger" aria-label={`删除${item.value}`} disabled={pending} onClick={() => perform(() => saveConfig({ forwarding: { [c.key]: items.filter((_, i) => i !== index) } }, '转发目标已删除'))}><Trash2 /></Button></div>) : <div className="dp-empty">暂无配置</div>}</div></Panel>
  </>;
}

export function Commands({ snapshot, saveConfig, perform, pending }) {
  const [tab, setTab] = useState('sms');
  const { open } = useDialog();
  const commands = snapshot.config?.commands || {}, remote = snapshot.config?.remoteControl || {}, status = snapshot.remoteControlStatus || {};
  const trusted = commands.trustedNumbers || [];
  const edit = () => open('编辑 HTTP 指令配置', <SaveForm description="修改 HTTP 指令服务的监听端口与访问凭据。" onSave={async (form) => {
    requirePort(form.port.trim());
    const next = { port: form.port.trim() };
    if (form.password) next.password = form.password;
    if (form.token) next.token = form.token;
    await saveConfig({ remoteControl: next }, 'HTTP 配置已保存；端口或凭据修改后，请使用新地址重新登录');
  }}><Field label="监听端口" name="port" defaultValue={remote.port || '18080'} inputMode="numeric" required /><Field label="管理密码" name="password" type="password" autoComplete="new-password" hint={remote.password ? '已配置；留空保持当前密码。' : '未配置'} /><Field label="接口 Token" name="token" type="password" autoComplete="off" hint={remote.token ? '已配置；留空保持当前 Token。' : '未配置'} /><Note>修改监听端口或管理密码后，当前页面可能需要重新连接。</Note></SaveForm>);
  return <><Tabs items={[[ 'sms', '短信指令', MessageSquare ], [ 'http', 'HTTP 指令', Globe ]]} value={tab} onChange={setTab} />{tab === 'sms' ? <>
    <Panel title="短信指令" description="只有可信号码发来的指令才会执行。"><div className="dp-form"><SwitchRow title="远程打电话" description="DOPPEL CALL 13800138000" checked={commands.callEnabled !== false} disabled={pending} onChange={(value) => perform(() => saveConfig({ commands: { callEnabled: value } }, '指令配置已保存'))} /><SwitchRow title="远程发短信" description="DOPPEL SMS 13800138000 你好" checked={commands.smsEnabled !== false} disabled={pending} onChange={(value) => perform(() => saveConfig({ commands: { smsEnabled: value } }, '指令配置已保存'))} /></div></Panel>
    <Panel title="可信号码" description="号码配置与指令开关分别管理。" action={<Button primary onClick={() => open('添加可信号码', <SaveForm submit="添加可信号码" description="只有此号码发来的短信指令才会执行。请添加你信任的手机号。" onSave={async ({ number }) => {
      const value = number.trim(); requirePhone(value);
      if (trusted.some((item) => phoneKey(item.number) === phoneKey(value))) throw new Error('此号码已存在，请勿重复添加');
      await saveConfig({ commands: { trustedNumbers: [...trusted, { number: value }] } }, '可信号码已添加');
    }}><Field label="可信号码" name="number" type="tel" placeholder="13800138000" autoComplete="off" required /></SaveForm>)}><Plus />添加可信号码</Button>}><div className="dp-form">{trusted.length ? trusted.map((item, index) => <div className="dp-target-row" key={`${item.number}-${index}`}><div><ShieldCheck /><span>{item.number}</span></div><Button icon className="dp-danger" aria-label={`删除可信号码${item.number}`} disabled={pending} onClick={() => perform(() => saveConfig({ commands: { trustedNumbers: trusted.filter((_, i) => i !== index) } }, '可信号码已删除'))}><Trash2 /></Button></div>) : <div className="dp-empty">暂无可信号码</div>}</div></Panel>
  </> : <>
    <Panel title="HTTP 服务状态" description="当前设备的 HTTP 指令服务。" action={<Badge neutral={!status.isRunning}>{status.isRunning ? '运行中' : '未运行'}</Badge>}><div className="dp-readonly"><div><small>当前 IP</small><strong>{status.ipAddresses?.join(', ') || '未检测到局域网 IP'}</strong></div><div><small>监听端口</small><strong>{status.port || remote.port || '18080'}</strong></div></div></Panel>
    <Panel title="连接与认证" description="管理 HTTP 指令的访问密码与接口 Token。" action={<Button onClick={edit}>编辑</Button>}><div className="dp-connection-details"><SummaryRow label="监听端口" description="HTTP 指令服务使用的端口">{remote.port || '18080'}</SummaryRow><SummaryRow label="管理密码" description="用于网页登录"><span className="dp-secret">••••••••</span><Badge neutral={!remote.password}>{remote.password ? '已配置' : '未配置'}</Badge></SummaryRow><SummaryRow label="接口 Token" description="用于外部 API 调用"><span className="dp-secret">••••••••</span><Badge neutral={!remote.token}>{remote.token ? '已配置' : '未配置'}</Badge></SummaryRow></div></Panel>
  </>}</>;
}

export function Connection({ agent, saveAgent, generateKey, perform, pending }) {
  const { open } = useDialog();
  const status = agent.status || {};
  const connected = agent.enabled && status.state === 'connected';
  const label = !agent.enabled ? '未启用' : ({ connected: '已连接', connecting: '连接中', authenticating: '认证中', authentication_failed: '认证失败', version_mismatch: '版本不兼容', configuration_error: '配置异常', start_blocked: '启动受限', retrying: '等待重连' })[status.state] || '等待连接';
  const edit = () => open('编辑 Sora 连接配置', <SaveForm submit="保存并应用" description="设置此设备要连接的 Sora 服务器与账号。" onSave={async (form) => {
    const enabled = form.enabled === 'on';
    const server = form.server.trim() ? requireOrigin(form.server.trim()) : '';
    const username = form.username.trim();
    if (enabled && (!server || !username)) throw new Error('请填写 Sora 服务器地址和账号');
    if (username.length > 128 || /[\r\n]/.test(username)) throw new Error('请输入有效的 Sora 账号');
    if (enabled && !agent.publicKey) throw new Error('请先生成设备密钥，并将公钥登记到 Sora');
    await saveAgent({ server, username, enabled, allowSms: !!agent.allowSms, allowCalls: !!agent.allowCalls });
  }}><Field label="Sora 服务器地址" name="server" type="url" defaultValue={agent.server || ''} placeholder="https://hako.example.com" hint="请输入 HTTPS 地址，不包含路径。" /><Field label="Sora 账号" name="username" defaultValue={agent.username || ''} placeholder="请输入账号" /><div className="dp-switchrow"><div><strong>启用 Agent</strong><p>保持与 Sora 连接</p></div><label className="dp-switch"><input name="enabled" type="checkbox" aria-label="启用 Agent" defaultChecked={!!agent.enabled} /><span /></label></div></SaveForm>);
  const permission = (key, value) => perform(() => saveAgent({ enabled: !!agent.enabled, server: agent.server || '', username: agent.username || '', allowSms: !!agent.allowSms, allowCalls: !!agent.allowCalls, [key]: value }));
  return <>
    <Panel title="Sora 连接状态" description="通过 Agent 连接到 Sora 服务端。" action={<Badge neutral={!connected}>{connected && <span className="dp-dot" />}{label}</Badge>}><div className="dp-readonly"><div><small>设备 ID</small><strong>{status.agentId || '尚未分配'}</strong></div><div><small>连接状态</small><strong>{label}</strong></div></div>{agent.enabled && !connected && status.message && <div className="dp-form"><Note>{status.message}</Note></div>}</Panel>
    <Panel title="连接与认证" description="Sora 服务器与账号配置，使用设备密钥认证。" action={<Button onClick={edit}>编辑</Button>}><div className="dp-connection-details"><SummaryRow label="Sora 服务器地址">{agent.server || '未配置'}</SummaryRow><SummaryRow label="Sora 账号">{agent.username || '未配置'}</SummaryRow><SummaryRow label="启用 Agent" description="保持连接并显示后台运行通知"><Badge neutral={!agent.enabled}>{agent.enabled ? '已启用' : '未启用'}</Badge></SummaryRow></div></Panel>
    <Panel title="设备密钥" description="设备公钥需要登记到 Sora 的设备管理。" action={agent.publicKey ? <Button onClick={() => open('设备公钥', <PublicKey publicKey={agent.publicKey} />, true)}>查看公钥</Button> : <Button busy={pending} onClick={() => perform(generateKey)}>生成设备密钥</Button>}><div className="dp-readonly"><div><small>公钥状态</small><strong>{agent.publicKey ? '已生成' : '未生成'}</strong></div><div><small>公钥指纹</small><strong className="dp-key-id">{agent.keyId || '生成密钥后显示'}</strong></div></div><div className="dp-form"><Note>私钥保存在此手机的系统密钥库中。</Note></div></Panel>
    <Panel title="Hako 远程操作权限" description="控制通过 Hako 发起的远程操作。"><div className="dp-form"><SwitchRow title="允许远程发送短信" description="还需要手机系统的发送短信权限" checked={agent.allowSms} disabled={pending} onChange={(value) => permission('allowSms', value)} /><SwitchRow title="允许远程拨号" description="拨号请求已提交不代表电话已接通" checked={agent.allowCalls} disabled={pending} onChange={(value) => permission('allowCalls', value)} /></div></Panel>
  </>;
}

function PublicKey({ publicKey }) {
  const ref = useRef(null);
  const [copied, setCopied] = useState(null);
  const { close } = useDialog();
  const copy = async () => {
    let success = false;
    try { if (window.isSecureContext && navigator.clipboard?.writeText) { await navigator.clipboard.writeText(publicKey); success = true; } } catch { /* The selected text remains available for manual copying. */ }
    if (!ref.current) return;
    if (!success) { ref.current.focus(); ref.current.select(); ref.current.setSelectionRange(0, publicKey.length); try { success = document.execCommand('copy'); } catch { success = false; } }
    setCopied(success);
  };
  return <><p className="dp-dialog-description">将完整公钥添加到 Sora 的设备管理。</p><Field label="公钥 PEM"><textarea ref={ref} className="dp-key-text" readOnly spellCheck={false} aria-label="完整设备公钥" value={publicKey} /></Field>{copied !== null && <p className={`dp-key-copy-status ${copied ? '' : 'error'}`} role="status">{copied ? '公钥已复制' : '请长按或选中上方公钥，手动复制。'}</p>}<div className="dp-form-actions"><Button onClick={close}>关闭</Button><Button primary onClick={copy}>{copied ? '已复制' : '复制公钥'}</Button></div></>;
}
