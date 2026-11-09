import { useState } from 'react';
import { Check, Code2, ImagePlus, KeyRound, Link2, List, MessageSquare, Pause, Play, Plus, Search, Send, Settings, ShieldCheck, Trash2, Webhook, Zap } from 'lucide-react';
import { notificationChannels, type Message, type NotificationChannel, type NotificationDelivery, type NotificationResult, type WebHook, type WebHookRequest, type WebHookRouting } from '../shared/types';
import type { Navigate } from './App';
import { patch, post, remove } from './api';
import { Button, CopyButton, Empty, ErrorLine, IconButton, Loading, Modal, Status, fullTime, relative, useResource } from './ui';
import { WebHookMessages } from './WebHookMessages';

interface Props { wechatId: string | null; revision: number; refresh: () => void; notify: (message: string) => void; navigate: Navigate }
const channelLabel = { wechat: '微信', apns: 'Apple Push' };
const enabledChannels = (routing: WebHookRouting) => notificationChannels.filter(channel => channel === 'wechat' ? !!routing.botId : routing.apnsEnabled);
const channelNames = (channels: NotificationChannel[]) => channels.map(channel => channelLabel[channel]).join('、');
interface ChannelSelection { allowedChannels: NotificationChannel[]; defaultChannels: NotificationChannel[] }
function routingPayload(selection: ChannelSelection, wechatId: string | null): WebHookRouting | null {
  const { allowedChannels, defaultChannels } = selection;
  const useWechat = allowedChannels.includes('wechat');
  if (!defaultChannels.length || (useWechat && !wechatId)) return null;
  return { botId: useWechat ? wechatId : null, apnsEnabled: allowedChannels.includes('apns'), defaultChannels };
}
function RoutingFields({ wechatAvailable, selection, onChange }: { wechatAvailable: boolean; selection: ChannelSelection; onChange: (value: ChannelSelection) => void }) {
  const { allowedChannels, defaultChannels } = selection;
  function toggleChannel(channel: NotificationChannel, checked: boolean) {
    const allowed = checked ? [...allowedChannels, channel] : allowedChannels.filter(item => item !== channel);
    const defaults = defaultChannels.filter(item => allowed.includes(item));
    onChange({ allowedChannels: allowed, defaultChannels: defaults.length ? defaults : allowed.slice(0, 1) });
  }
  return <div className="webhook-target-hint routing-fields">
    <fieldset><legend>允许渠道</legend>
      {notificationChannels.map(channel => <label className="routing-checkbox" key={channel}>
        <input type="checkbox" checked={allowedChannels.includes(channel)}
          disabled={channel === 'wechat' && !wechatAvailable && !allowedChannels.includes(channel)}
          onChange={e => toggleChannel(channel, e.target.checked)} />{channelLabel[channel]}
      </label>)}
      {!wechatAvailable && <p>请先在「通知渠道」扫码绑定微信。</p>}
    </fieldset>
    <p>已登录 Hako 的 iPhone 会自动登记 Apple Push。图片仅支持微信。</p>
    <fieldset><legend>默认渠道</legend>
      {notificationChannels.filter(channel => allowedChannels.includes(channel)).map(channel => <label className="routing-checkbox" key={channel}><input type="checkbox" checked={defaultChannels.includes(channel)} onChange={e => {
        const defaults = e.target.checked ? [...defaultChannels, channel] : defaultChannels.filter(item => item !== channel);
        onChange({ ...selection, defaultChannels: defaults });
      }} />{channelLabel[channel]}</label>)}
      {!allowedChannels.length && <p>请先启用至少一个渠道。</p>}
    </fieldset>
    <p>调用时省略 channels 使用默认渠道。调用方也可从启用的渠道中显式选择。</p>
  </div>;
}
function DeliveryList({ deliveries }: { deliveries: NotificationDelivery[] }) {
  return <ul className="delivery-list">{deliveries.map(delivery => <li key={delivery.id}>
    <div><strong>{channelLabel[delivery.channel]} · {delivery.targetName}</strong><Status status={delivery.status} /></div>
    {delivery.error && <span className="small text-error">{delivery.error}</span>}
  </li>)}</ul>;
}
export function WebHooksPage({ wechatId, revision, refresh, notify, navigate }: Props) {
  const { data: webhooks, error, loading } = useResource<WebHook[]>('/webhooks', revision);
  const [search, setSearch] = useState(''), [filter, setFilter] = useState('all'), [creating, setCreating] = useState(false), [selectedId, setSelectedId] = useState<string | null>(null), [actionError, setActionError] = useState('');
  const [secret, setSecret] = useState<{ path: string; name: string } | null>(null);
  const [selectedTab, setSelectedTab] = useState('logs');
  const openHook = (webhookId: string, tab = 'logs') => { setSelectedTab(tab); setSelectedId(webhookId); };
  const filtered = (webhooks || []).filter(h => (!search || `${h.name} ${channelNames(enabledChannels(h))} ${h.conversationName ?? ""}`.toLowerCase().includes(search.toLowerCase())) && (filter === 'all' || (filter === 'enabled' ? h.enabled : !h.enabled)));
  const selected = webhooks?.find(h => h.id === selectedId);
  return <div className="page-content"><div className="section-toolbar"><div className="tabs">{[['all', '全部 Webhooks', webhooks?.length || 0], ['enabled', '已启用', webhooks?.filter(h => h.enabled).length || 0], ['disabled', '已停用', webhooks?.filter(h => !h.enabled).length || 0]].map(([value, label, count]) => <button key={value} className={filter === value ? 'selected' : ''} onClick={() => setFilter(String(value))}>{label}<span>{count}</span></button>)}</div><Button icon={Plus} onClick={() => setCreating(true)}>创建 Webhooks</Button></div><ErrorLine error={error || actionError} />
    <section className="panel">
      <div className="list-toolbar"><div className="search-box"><Search size={16} /><input aria-label="搜索 Webhooks" value={search} onChange={e => setSearch(e.target.value)} placeholder="搜索 Webhooks、渠道或会话…" /></div><span className="small quiet">每个 Webhooks 拥有独立 Token</span></div>
      {loading && !webhooks ? <Loading /> : !filtered.length ? <Empty icon={Webhook} title={webhooks?.length ? '未找到匹配的 Webhooks' : '给你的应用一个通知入口'} text={webhooks?.length ? '试试其他关键词或筛选条件。' : '创建 Webhooks 后，复制地址到你的监控、部署或其他应用中。'} action={!webhooks?.length && <Button icon={Plus} onClick={() => setCreating(true)}>创建第一个 Webhooks</Button>} /> : <div className="table-scroll"><table className="webhooks-table">
        <thead><tr><th>Webhooks 名称</th><th>发送目标</th><th>状态</th><th>调用 / 异常</th><th>最近调用</th><th>操作</th></tr></thead>
        <tbody>{filtered.map(webhook => <tr key={webhook.id}>
          <td><button className="webhook-name" onClick={() => openHook(webhook.id)}><span className="webhook-table-icon"><Webhook size={19} /></span><span><strong>{webhook.name}</strong><small>{webhook.tokenHint}••••••</small></span></button></td>
          <td><strong>{channelNames(enabledChannels(webhook))}</strong><small className="cell-sub">默认 · {channelNames(webhook.defaultChannels)}</small></td>
          <td><span className={`status ${!webhook.enabled ? 'status-stopped' : webhook.expiresAt && webhook.expiresAt < Date.now() ? 'status-expired' : 'status-online'}`}><i />{!webhook.enabled ? '已停用' : webhook.expiresAt && webhook.expiresAt < Date.now() ? '已过期' : '已启用'}</span></td>
          <td><span className="request-count">{webhook.requestCount}<span>/</span><b className={webhook.failureCount ? 'text-error' : 'quiet'}>{webhook.failureCount}</b></span></td>
          <td className="quiet nowrap">{relative(webhook.lastUsedAt)}</td>
          <td><div className="table-actions"><button className="text-link" onClick={() => openHook(webhook.id)}>消息</button><button className="text-link" onClick={() => openHook(webhook.id, 'integration')}>管理</button><IconButton icon={webhook.enabled ? Pause : Play} label={webhook.enabled ? `停用 ${webhook.name}` : `启用 ${webhook.name}`} onClick={async () => { try { await patch(`/webhooks/${webhook.id}`, { enabled: !webhook.enabled }); refresh(); } catch (error) { setActionError((error as Error).message); } }} /></div></td>
        </tr>)}</tbody>
      </table></div>}
    </section>
    <div className="info-strip"><Link2 size={17} /><span>Webhooks 地址包含访问凭证。后台只保存 Token 摘要，创建或重置后请及时复制完整地址。</span></div>
    {creating && <WebHookForm wechatId={wechatId} onClose={() => setCreating(false)} onCreated={result => { setCreating(false); setSecret({ path: result.path, name: result.webhook.name }); refresh(); }} />}
    {selected && <WebHookDetails key={`${selected.id}:${selectedTab}`} initialTab={selectedTab} webhook={selected} wechatId={wechatId} revision={revision} refresh={refresh} notify={notify} onClose={() => setSelectedId(null)} onSecret={path => { setSelectedId(null); setSecret({ path, name: selected.name }); }} navigate={navigate} />}
    {secret && <SecretModal path={secret.path} name={secret.name} onClose={() => setSecret(null)} />}
  </div>;
}
function WebHookForm({ wechatId, onClose, onCreated }: { wechatId: string | null; onClose: () => void; onCreated: (result: { webhook: WebHook; path: string }) => void }) {
  const [name, setName] = useState(''), [rateLimit, setRateLimit] = useState(60), [error, setError] = useState(''), [busy, setBusy] = useState(false);
  const [selection, setSelection] = useState<ChannelSelection>({ allowedChannels: [], defaultChannels: [] });
  const routing = routingPayload(selection, wechatId);
  return <Modal title="创建 Webhooks" subtitle="选择允许使用的渠道及默认发送方式。" onClose={onClose}>
    <form className="modal-form" onSubmit={async e => {
      e.preventDefault();
      if (!routing) return;
      setBusy(true); setError('');
      try { onCreated(await post('/webhooks', { name, ...routing, rateLimit })); }
      catch (error) { setError((error as Error).message); } finally { setBusy(false); }
    }}>
      <div className="form-steps"><span className="done">1<span>命名</span></span><i /><span className="done">2<span>选择渠道</span></span><i /><span>3<span>生成地址</span></span></div>
      <label>Webhooks 名称<input required maxLength={80} value={name} onChange={e => setName(e.target.value)} placeholder="例如：生产环境部署通知" autoFocus /></label>
      <RoutingFields wechatAvailable={!!wechatId} selection={selection} onChange={setSelection} />
      <label>每分钟调用上限<div className="number-field"><input type="number" min={1} max={600} value={rateLimit} onChange={e => setRateLimit(Number(e.target.value))} required /><span>次 / 分钟</span></div></label>
      <ErrorLine error={error} /><div className="modal-footer"><Button variant="secondary" type="button" onClick={onClose}>取消</Button><Button icon={KeyRound} busy={busy} disabled={!routing} type="submit">生成 Webhooks 地址</Button></div>
    </form>
  </Modal>;
}
function SecretModal({ path, name, onClose }: { path: string; name: string; onClose: () => void }) {
  const url = `${location.origin}${path}`;
  return <Modal title="Webhooks 地址已生成" subtitle={name} onClose={onClose}><div className="secret-content"><div className="secret-success"><Check size={26} /></div><h3>复制地址，即可开始对接</h3><p>完整地址仅在本次展示。关闭后可通过重置 Token 生成新地址。</p><div className="secret-url"><code>{url}</code></div><CopyButton text={url} label="复制完整地址" /><div className="code-header"><span>请求示例</span><CopyButton text={`curl -X POST "${url}" -H "Content-Type: application/json" -d '{"message":{"type":"text","text":"部署成功"}}'`} /></div><pre className="code-block">{`POST ${path}\nContent-Type: application/json\n\n{\n  "message": { "type": "text", "text": "部署成功" }\n}`}</pre><div className="modal-footer"><Button onClick={onClose}>我已保存地址</Button></div></div></Modal>;
}
function WebHookDetails({ webhook, initialTab, wechatId, revision, refresh, notify, onClose, onSecret, navigate }: { webhook: WebHook; initialTab: string; wechatId: string | null; revision: number; refresh: () => void; notify: (message: string) => void; onClose: () => void; onSecret: (path: string) => void; navigate: Navigate }) {
  const [tab, setTab] = useState(initialTab), [error, setError] = useState(''), [busy, setBusy] = useState(false);
  const [name, setName] = useState(webhook.name), [rateLimit, setRateLimit] = useState(webhook.rateLimit), [expiresAt, setExpiry] = useState(webhook.expiresAt ? new Date(webhook.expiresAt - new Date(webhook.expiresAt).getTimezoneOffset() * 60_000).toISOString().slice(0, 16) : '');
  const [selection, setSelection] = useState<ChannelSelection>({ allowedChannels: enabledChannels(webhook), defaultChannels: webhook.defaultChannels });
  const routing = routingPayload(selection, wechatId);
  const requests = useResource<WebHookRequest[]>(`/webhooks/${webhook.id}/requests`, revision);
  const template = `${location.origin}/webhook/notifications/<token>`;
  return <Modal title={webhook.name} subtitle={`默认发送 · ${channelNames(webhook.defaultChannels)}`} onClose={onClose} wide><div className="detail-tabs">{[['messages', MessageSquare, '微信消息'], ['integration', Code2, '接入指南'], ['test', Send, '在线测试'], ['logs', List, '投递记录'], ['settings', Settings, '配置']].map(([key, Icon, label]) => { const Glyph = Icon as typeof Code2; return <button key={String(key)} className={tab === key ? 'selected' : ''} onClick={() => { setTab(String(key)); setError(''); }}><Glyph size={15} />{String(label)}</button>; })}</div><div className="webhook-detail-body"><ErrorLine error={error} />
    {tab === 'messages' && <WebHookMessages webhook={webhook} revision={revision} refresh={refresh} navigate={navigate} onClose={onClose} />}
    {tab === 'integration' && <>
      <div className="target-card"><span className="webhook-intro-icon"><Webhook size={23} /></span><div><strong>允许渠道 · {channelNames(enabledChannels(webhook))}</strong><p>省略 channels 时发送到 {channelNames(webhook.defaultChannels)}。</p></div></div>
      <label className="field-title">接口地址</label><div className="endpoint"><span>POST</span><code>{template}</code></div><p className="small quiet">将 &lt;token&gt; 替换为创建时保存的 Token。无需 Authorization 请求头。</p>
      <NotificationExamples webhook={webhook} /><p className="small quiet">微信窗口过期时，微信投递会标为失败。Apple Push 继续投递。图片请显式选择微信。</p>
      <div className="integration-notes"><div><ShieldCheck size={16} /><p><strong>避免重复发送</strong><span>可选请求头 Idempotency-Key，24 小时内同一个键只创建一个通知。</span></p></div><div><Zap size={16} /><p><strong>异步发送</strong><span>HTTP 202 返回 notificationId。使用 GET /webhook/notifications/&lt;token&gt;/&lt;notificationId&gt; 查询各渠道。</span></p></div></div>
      <Button variant="secondary" icon={KeyRound} onClick={async () => { if (!confirm('重置后旧 Webhooks 地址立即失效，需要更新外部应用配置。继续？')) return; try { const result = await post<{ path: string }>(`/webhooks/${webhook.id}/rotate-token`); refresh(); onSecret(result.path); } catch (error) { setError((error as Error).message); } }}>重置 Token 并生成新地址</Button>
    </>}
    {tab === 'test' && <WebHookTest webhook={webhook} revision={revision} refresh={refresh} notify={notify} />}
    {tab === 'logs' && <><div className="log-summary"><strong>{webhook.requestCount}<span>总调用</span></strong><strong>{webhook.failureCount}<span>异常</span></strong><strong>{webhook.rateLimit}<span>每分钟上限</span></strong></div><ErrorLine error={requests.error} />{requests.loading && !requests.data ? <Loading /> : !requests.data?.length ? <Empty icon={List} title="还没有调用记录" text="外部应用调用或在线测试后，结果会显示在这里。" /> : <div className="request-list">{requests.data.map(request => <div className="request-item" key={request.id}><div><Status status={request.status} /><time>{fullTime(request.createdAt)}</time></div><p>{request.summary || '无消息内容'}</p><small>{request.id} · {request.ip}</small>{request.deliveries && <DeliveryList deliveries={request.deliveries} />}{request.error && <span className="text-error small">{request.error}</span>}</div>)}</div>}</>}
    {tab === 'settings' && <form className="webhook-settings" onSubmit={async e => { e.preventDefault(); if (!routing) return; setBusy(true); setError(''); try { await patch(`/webhooks/${webhook.id}`, { name, rateLimit, ...routing, expiresAt: expiresAt ? new Date(expiresAt).getTime() : null }); refresh(); notify('Webhooks 配置已保存'); } catch (error) { setError((error as Error).message); } finally { setBusy(false); } }}><label>Webhooks 名称<input required maxLength={80} value={name} onChange={e => setName(e.target.value)} /></label><RoutingFields wechatAvailable={!!wechatId} selection={selection} onChange={setSelection} /><div className="two-fields"><label>每分钟上限<input type="number" required min={1} max={600} value={rateLimit} onChange={e => setRateLimit(Number(e.target.value))} /></label><label>过期时间 <span className="optional">可选</span><input type="datetime-local" value={expiresAt} onChange={e => setExpiry(e.target.value)} /></label></div><div className="settings-toggle"><div><strong>启用 Webhooks</strong><p>停用后，外部应用将无法通过此地址发送消息。</p></div><button type="button" className={`switch ${webhook.enabled ? 'on' : ''}`} role="switch" aria-label="启用 Webhooks" aria-checked={webhook.enabled} onClick={async () => { try { await patch(`/webhooks/${webhook.id}`, { enabled: !webhook.enabled }); refresh(); } catch (error) { setError((error as Error).message); } }}><i /></button></div><div className="modal-footer"><Button variant="danger" type="button" icon={Trash2} onClick={async () => { if (!confirm(`确定删除“${webhook.name}”？其接口地址会立即失效，调用日志会被删除。`)) return; try { await remove(`/webhooks/${webhook.id}`); refresh(); onClose(); notify('Webhooks 已删除'); } catch (error) { setError((error as Error).message); } }}>删除 Webhooks</Button><Button busy={busy} disabled={!routing} type="submit">保存配置</Button></div></form>}
  </div></Modal>;
}

function NotificationExamples({ webhook }: { webhook: WebHook }) {
  const [kind, setKind] = useState('text');
  const allowed = enabledChannels(webhook);
  const examples: Record<string, object> = {
    text: { message: { type: 'text', text: '你的通知内容' } },
    explicit: { channels: allowed, message: { type: 'text', text: '你的通知内容' } },
    url: { channels: ['wechat'], message: { type: 'image', image: { url: 'https://example.com/report.png' } } },
    base64: { channels: ['wechat'], message: { type: 'image', image: { base64: 'data:image/png;base64,<图片的 Base64 数据>' } } },
  };
  const tabs = [['text', '默认渠道'], ['explicit', '指定渠道']];
  if (webhook.botId) tabs.push(['url', '图片 URL'], ['base64', '图片 Base64']);
  const code = JSON.stringify(examples[kind], null, 2);
  return <div className="notification-examples"><div className="code-header"><div className="message-kind-tabs">{tabs.map(([value, label]) => <button key={value} type="button" className={kind === value ? 'selected' : ''} onClick={() => setKind(value)}>{label}</button>)}</div><CopyButton text={code} /></div><pre className="code-block">{code}</pre>{(kind === 'url' || kind === 'base64') && <p className="image-help">支持 PNG、JPEG、GIF、WebP，单张不超过 8 MB。URL 需为公网 HTTPS 地址。</p>}</div>;
}

function WebHookTest({ webhook, revision, refresh, notify }: { webhook: WebHook; revision: number; refresh: () => void; notify: (message: string) => void }) {
  const [kind, setKind] = useState<'text' | 'image'>('text'), [source, setSource] = useState<'url' | 'file'>('url');
  const [text, setText] = useState('这是一条来自 iLinker 的测试通知。'), [url, setUrl] = useState(''), [base64, setBase64] = useState(''), [fileName, setFileName] = useState('');
  const [error, setError] = useState(''), [busy, setBusy] = useState(false), [reading, setReading] = useState(false), [testId, setTestId] = useState<string | null>(null);
  const [selection, setSelection] = useState('');
  const allowed = enabledChannels(webhook);
  const test = useResource<NotificationResult>(testId ? `/webhooks/${webhook.id}/notifications/${testId}` : null, revision);
  const messageId = test.data?.deliveries.find(delivery => delivery.channel === 'wechat')?.messageId;
  const preview = useResource<Message>(kind === 'image' && messageId ? `/messages/${messageId}` : null, revision);
  return <form onSubmit={async e => {
    e.preventDefault(); setBusy(true); setError('');
    try {
      const message = kind === 'text' ? { type: 'text', text } : { type: 'image', image: source === 'url' ? { url } : { base64 } };
      const channels = kind === 'image' ? ['wechat'] : selection ? selection.split(',') : undefined;
      const result = await post<NotificationResult>(`/webhooks/${webhook.id}/test`, { channels, message });
      setTestId(result.notificationId); refresh(); notify('测试通知已创建');
    } catch (error) { setError((error as Error).message); } finally { setBusy(false); }
  }}>
    <div className="message-kind-tabs test-kind">{(['text', 'image'] as const).map(value => <button key={value} type="button" disabled={value === 'image' && !webhook.botId} className={kind === value ? 'selected' : ''} onClick={() => { setKind(value); setError(''); }}>{value === 'text' ? <MessageSquare size={14} /> : <ImagePlus size={14} />}{value === 'text' ? '文本' : '图片'}</button>)}</div>
    <label>发送渠道<select disabled={kind === 'image'} value={kind === 'image' ? 'wechat' : selection} onChange={e => setSelection(e.target.value)}>
      <option value="">默认 · {channelNames(webhook.defaultChannels)}</option>
      {allowed.map(channel => <option key={channel} value={channel}>{channelLabel[channel]}</option>)}
      {allowed.length > 1 && <option value={allowed.join(',')}>微信和 Apple Push</option>}
    </select></label>
    {kind === 'text' ? <label>消息内容<textarea value={text} onChange={e => setText(e.target.value)} rows={5} required maxLength={4000} /></label> : <div className="image-test-fields">
      <label>图片来源<select value={source} onChange={e => { setSource(e.target.value as 'url' | 'file'); setError(''); }}><option value="url">图片链接</option><option value="file">本地图片</option></select></label>
      {source === 'url' ? <label>图片 URL<input type="url" required value={url} onChange={e => setUrl(e.target.value)} placeholder="https://example.com/report.png" /></label> : <label>选择图片<input type="file" accept="image/png,image/jpeg,image/gif,image/webp" onChange={async e => {
        setBase64(''); setFileName(''); setError(''); const file = e.target.files?.[0]; if (!file) return;
        if (file.size > 8 * 1024 * 1024) { setError('图片不能超过 8 MB'); e.target.value = ''; return; }
        if (!['image/png', 'image/jpeg', 'image/gif', 'image/webp'].includes(file.type)) { setError('请选择 PNG、JPEG、GIF 或 WebP 图片'); e.target.value = ''; return; }
        setReading(true);
        try {
          const data = await new Promise<string>((resolve, reject) => { const reader = new FileReader(); reader.onload = () => resolve(String(reader.result)); reader.onerror = () => reject(new Error('图片读取失败')); reader.readAsDataURL(file); });
          setBase64(data); setFileName(file.name);
        } catch (error) { setError((error as Error).message); } finally { setReading(false); }
      }} /></label>}
      {source === 'file' && base64 && <div className="image-upload-preview"><img src={base64} alt="待发送图片预览" /><span>{fileName}</span></div>}
      <p className="image-help">单张图片不超过 8 MB。URL 在后台下载，支持的格式为 PNG、JPEG、GIF 和 WebP。</p>
    </div>}
    <ErrorLine error={error || test.error} /><div className="test-actions"><span className="quiet small">会真实发送到所选渠道</span><Button type="submit" icon={Send} busy={busy || reading} disabled={kind === 'image' && (!webhook.botId || (source === 'file' && !base64))}>发送测试</Button></div>
    {test.data && <div className="test-result"><Status status={test.data.status} /><code>{test.data.notificationId}</code><DeliveryList deliveries={test.data.deliveries} />
      {preview.data?.imageUrl && <img className="test-result-image" src={preview.data.imageUrl} alt="已提交的测试图片" />}
    </div>}
  </form>;
}
