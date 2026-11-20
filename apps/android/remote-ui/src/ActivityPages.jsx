import { useState } from 'react';
import { ArrowUpRight, ChevronRight, History, MessageSquare, Phone, Send, ShieldCheck } from 'lucide-react';
import { Badge, Button, Field, Note, Panel, Tabs, useDialog } from './ui.jsx';
import { post, requirePhone, simLabel } from './api.js';
import { SimSelect } from './ConfigPages.jsx';

const recentTypes = new Set(['sms_received', 'sms_command', 'sms_sent_command', 'call_received', 'call_out_command']);
const logTypes = new Set([...recentTypes, 'sms_forwarded', 'operation_log', 'agent_connection']);
const title = (type) => ({ sms_received: '收到短信', sms_history: '短信历史', call_received: '电话呼入', call_out_command: '电话呼出', sms_forwarded: '短信已转发', sms_command: '收到指令', sms_sent_command: '发送短信', operation_log: '业务日志', agent_connection: 'Sora 连接' })[type] || '系统事件';
const eventIcon = (type) => type.includes('call') ? Phone : type.includes('command') ? ShieldCheck : type === 'sms_forwarded' ? ArrowUpRight : MessageSquare;
const time = (value) => value ? new Date(value).toLocaleString() : '—';

function EventTable({ events }) {
  const { open } = useDialog();
  if (!events.length) return <div className="dp-empty">暂无事件</div>;
  return <table className="dp-table"><thead><tr><th style={{ width: '25%' }}>事件</th><th style={{ width: '35%' }}>号码 / 内容</th><th style={{ width: '25%' }}>时间</th><th style={{ width: '15%' }} /></tr></thead><tbody>{events.map((event, index) => {
    const Icon = eventIcon(event.type);
    return <tr key={event.id || `${event.timestamp}-${index}`}><td><div className="dp-event-title"><span className="dp-eventicon"><Icon /></span>{title(event.type)}</div></td><td><span className="dp-sender">{event.from || event.to || '—'}</span><span className="dp-preview">{event.content || event.detail || ''}</span></td><td className="dp-time">{time(event.timestamp)}</td><td className="dp-detail-cell"><button type="button" className="dp-link" onClick={() => open(title(event.type), <><div className="dp-readonly"><div><small>时间</small><strong>{time(event.timestamp)}</strong></div><div><small>号码 / 目标</small><strong>{event.from || event.to || '—'}</strong></div></div><div className="dp-message">{event.content || event.detail || '无详情'}</div>{event.content && event.detail && <p className="dp-dialog-description">{event.detail}</p>}</>)}>详情<ChevronRight /></button></td></tr>;
  })}</tbody></table>;
}

export function Overview({ snapshot, navigate }) {
  const events = snapshot.events || [], permissions = snapshot.permissions || {};
  const running = !!(permissions.sms && permissions.phone), today = new Date().toDateString();
  const metrics = [['短信事件', ['sms_received', 'sms_command'], MessageSquare], ['来电事件', ['call_received'], Phone], ['转发短信', ['sms_forwarded'], ArrowUpRight], ['短信指令', ['sms_command'], ShieldCheck]];
  const recent = events.filter((event) => recentTypes.has(event.type) && event.source !== 'system_sms' && new Date(event.timestamp).getTime() >= Date.now() - 86400000);
  return <><div className="dp-statusline"><span><span className="dp-dot" />{running ? '设备运行正常' : '等待手机授予短信或电话权限'}</span><small>{snapshot.remoteControlStatus?.isRunning ? 'HTTP 服务运行中' : 'HTTP 服务未运行'}</small></div><div className="dp-metrics">{metrics.map(([label, types, Icon]) => {
    const matches = events.filter((event) => types.includes(event.type));
    return <div className="dp-metric" key={label}><div className="dp-metric-head"><span>{label}</span><Icon /></div><div className="dp-value">{matches.filter((event) => new Date(event.timestamp).toDateString() === today).length}<small>今日</small></div><div className="dp-metric-foot"><span>累计</span><strong>{matches.length}</strong></div></div>;
  })}</div><Panel title="最近事件" description="最近 24 小时的短信、来电与指令。" action={<button className="dp-link" onClick={() => navigate('logs')}>查看全部<ChevronRight /></button>}><EventTable events={recent.slice(0, 8)} /><div className="dp-panel-bottom"><span>最近 {Math.min(8, recent.length)} 条事件</span><span>最近 24 小时</span></div></Panel></>;
}

export function Logs({ snapshot }) {
  const events = (snapshot.events || []).filter((event) => logTypes.has(event.type));
  return <Panel title="事件日志" description="短信、来电、指令、转发与 Sora 连接状态。" action={<Badge neutral>{events.length} 条事件</Badge>}><EventTable events={events} /><div className="dp-panel-bottom"><span>共 {events.length} 条事件</span><span>当前设备</span></div></Panel>;
}

export function Actions({ snapshot, notify, history, setHistory }) {
  const [tab, setTab] = useState('sms'), [pending, setPending] = useState(false);
  const [sms, setSms] = useState({ to: '', message: '' }), [call, setCall] = useState('');
  const selected = snapshot.config?.forwarding?.selectedSmsSim || simLabel(snapshot.simCards?.[0]);
  const submit = async (event) => {
    event.preventDefault(); if (pending) return;
    const values = Object.fromEntries(new FormData(event.currentTarget));
    const isSms = tab === 'sms', type = isSms ? 'sms_sent_command' : 'call_out_command';
    try {
      requirePhone(isSms ? values.to.trim() : values.number.trim());
      if (isSms && !values.message.trim()) throw new Error('请填写短信内容');
      setPending(true);
      const result = await post(isSms ? '/api/sms/send' : '/api/call/start', { ...values, sim: values.sim ?? selected ?? '' });
      if (isSms) setSms((current) => ({ ...current, message: '' }));
      const detail = result.message || '操作已提交'; notify('ok', detail);
      setHistory((items) => [{ type, to: isSms ? values.to : values.number, detail, timestamp: new Date().toISOString() }, ...items].slice(0, 100));
    } catch (error) {
      notify('error', error.message);
      setHistory((items) => [{ type: 'operation_log', detail: `${isSms ? '发送短信' : '发起拨号'}失败：${error.message}`, timestamp: new Date().toISOString() }, ...items].slice(0, 100));
    } finally { setPending(false); }
  };
  return <><Tabs items={[[ 'sms', '发送短信', MessageSquare ], [ 'call', '发起拨号', Phone ], [ 'history', '操作历史', History ]]} value={tab} onChange={setTab} />{tab === 'history' ? <Panel title="操作历史" description="本次会话中的操作提交记录。"><EventTable events={history} /></Panel> : <Panel title={tab === 'sms' ? '发送短信' : '发起拨号'} description={tab === 'sms' ? '选择 SIM 卡，填写目标号码和短信内容。' : '通过当前设备提交拨号请求。'}><form className="dp-form" key={tab} onSubmit={submit}><fieldset disabled={pending}><div className="dp-fields"><Field label={tab === 'sms' ? '目标号码' : '电话号码'} name={tab === 'sms' ? 'to' : 'number'} type="tel" required placeholder="请输入手机号" value={tab === 'sms' ? sms.to : call} onChange={(event) => tab === 'sms' ? setSms({ ...sms, to: event.target.value }) : setCall(event.target.value)} /><SimSelect snapshot={snapshot} value={selected} label={tab === 'sms' ? '发送 SIM 卡' : '拨号 SIM 卡'} /></div>{tab === 'sms' ? <Field label="短信内容"><textarea name="message" required placeholder="输入需要发送的短信内容…" value={sms.message} onChange={(event) => setSms({ ...sms, message: event.target.value })} /></Field> : <Note>拨号请求已提交，不代表电话已接通。</Note>}<div className="dp-form-actions"><small>通过当前手机提交操作</small><Button type="submit" primary busy={pending}>{tab === 'sms' ? <Send /> : <Phone />}{tab === 'sms' ? '发送短信' : '发起拨号'}</Button></div></fieldset></form></Panel>}</>;
}
