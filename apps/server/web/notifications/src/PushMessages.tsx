import { useState } from 'react';
import { ArrowLeft, Send, Smartphone } from 'lucide-react';
import type { ChannelMessage, PushChannel } from '../shared/types';
import { post } from './api';
import { Button, Empty, ErrorLine, fullTime, Loading, Modal, Status, useResource } from './ui';

interface Props {
  channel: PushChannel | null;
  revision: number;
  refresh: () => void;
  notify: (message: string) => void;
  onBack: () => void;
}
export function PushMessages({ channel, revision, refresh, notify, onBack }: Props) {
  const [composing, setComposing] = useState(false);
  const [cursors, setCursors] = useState<string[]>([]);
  const cursor = cursors.at(-1);
  const path = '/push/messages' + (cursor ? '?before=' + encodeURIComponent(cursor) : '');
  const { data, loading, error } = useResource<{ items: ChannelMessage[]; nextCursor: string | null }>(path, revision);
  const ready = channel?.configured && channel.device?.status === 'active';
  return <section className="chat-main push-history">
    <header className="chat-header">
      <button type="button" className="icon-btn chat-back" aria-label="返回渠道列表" onClick={onBack}><ArrowLeft size={19} /></button>
      <div><h2>Apple Push</h2><p>{channel?.device?.name ?? '通知投递记录'}</p></div>
      <div className="chat-header-actions"><Button icon={Send} disabled={!ready} onClick={() => setComposing(true)}>发送通知</Button></div>
    </header>
    <div className="push-history-body">
      <ErrorLine error={error} />
      {loading && !data ? <Loading /> : !data?.items.length ? <Empty icon={Smartphone} title="暂无 Apple Push 消息"
        text={ready ? '从消息中心或 Webhooks 发送的通知会显示在这里。' : '在「通知渠道」配置 APNs 并登记 iPhone 后即可发送。'} /> :
        <div className="table-scroll"><table><thead><tr><th>通知内容</th><th>来源 / 设备</th><th>投递状态</th><th>时间</th></tr></thead><tbody>
          {data.items.map(message => <tr key={message.id}>
            <td><strong>{message.title}</strong><div className="push-message-text">{message.text}</div></td>
            <td>{message.source}<small className="cell-sub">{message.targetName}</small></td>
            <td><Status status={message.status} />{message.error && <small className="cell-sub text-error">{message.error}</small>}</td>
            <td className="quiet nowrap">{fullTime(message.createdAt)}</td>
          </tr>)}
        </tbody></table></div>}
    </div>
    {(cursors.length > 0 || data?.nextCursor) && <div className="push-history-pages inline-actions">
      <Button variant="secondary" disabled={loading || !cursors.length} onClick={() => setCursors(value => value.slice(0, -1))}>更新消息</Button>
      <Button variant="secondary" disabled={loading || !data?.nextCursor} onClick={() => {
        if (data?.nextCursor) setCursors(value => [...value, data.nextCursor!]);
      }}>更早消息</Button>
    </div>}
    {composing && <PushComposer onClose={() => setComposing(false)} onQueued={() => {
      setComposing(false); setCursors([]); refresh(); notify('Apple Push 通知已排队');
    }} />}
  </section>;
}

export function PushComposer({ test = false, onClose, onQueued }: { test?: boolean; onClose: () => void; onQueued: () => void }) {
  const [title, setTitle] = useState(test ? 'Hako 测试通知' : 'Hako');
  const [text, setText] = useState(test ? '这是一条来自 Hako 管理后台的测试通知。' : '');
  const [busy, setBusy] = useState(false), [error, setError] = useState('');
  return <Modal title={test ? '测试 Apple Push' : '发送 Apple Push 通知'} onClose={onClose}>
    <form className="modal-form" onSubmit={async e => {
      e.preventDefault(); setBusy(true); setError('');
      try { await post('/push/messages', { title, text }); onQueued(); }
      catch (error) { setError((error as Error).message); }
      finally { setBusy(false); }
    }}>
      <label>标题<input required maxLength={80} value={title} onChange={e => setTitle(e.target.value)} /></label>
      <label>正文<textarea required rows={4} maxLength={4000} value={text} onChange={e => setText(e.target.value)} /></label>
      <ErrorLine error={error} />
      <div className="modal-footer"><Button type="button" variant="secondary" onClick={onClose}>取消</Button>
        <Button type="submit" icon={Send} busy={busy} disabled={!title.trim() || !text.trim()}>发送通知</Button></div>
    </form>
  </Modal>;
}
