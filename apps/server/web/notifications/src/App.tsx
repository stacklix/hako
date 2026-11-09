import { useCallback, useEffect, useState } from 'react';
import { Activity, ArrowDownLeft, ArrowRight, ArrowUpRight, Link2, MessageSquare, Radio, ShieldCheck, X, Zap } from 'lucide-react';
import { useHakoSession } from './api';
import { Button, Empty, ErrorLine, Loading, Status, relative, useResource } from './ui';
import type { Bot, Overview } from '../shared/types';
import { ChannelsPage, type WechatChannel } from './Channels';
import { MessagesPage } from './Messages';
import { WebHooksPage } from './WebHooks';

const pages = ['overview', 'channels', 'messages', 'webhooks'] as const;
type Page = typeof pages[number];
export interface Route { page: Page; botId?: string }
export type Navigate = (page: Page, botId?: string) => void;
function readRoute(): Route {
  const params = new URLSearchParams(location.search);
  const view = params.get('view');
  const page = view === 'bots' || view === 'settings' ? 'channels' : pages.find(value => value === view) ?? 'overview';
  return { page, botId: params.get('bot') || undefined };
}
const navigate: Navigate = (page, botId) => {
  const params = new URLSearchParams();
  if (botId) params.set('bot', botId);
  const url = '/admin/notifications/' + page + (params.size ? '?' + params : '');
  (window.top ?? window).location.assign(url);
};

export function App() {
  const [active, setActive] = useState(false), [error, setError] = useState('');
  const [route] = useState(readRoute);
  const [revision, setRevision] = useState(0), [toast, setToast] = useState('');
  const refresh = useCallback(() => setRevision(value => value + 1), []);
  const notify = useCallback((message: string) => setToast(message), []);
  useEffect(() => {
    let alive = true;
    const expired = () => { setActive(false); setError('Hako 管理会话已到期，请重新登录'); };
    void useHakoSession().then(() => { if (alive) setActive(true); }).catch(expired);
    window.addEventListener('unauthorized', expired);
    return () => { alive = false; window.removeEventListener('unauthorized', expired); };
  }, []);
  useEffect(() => {
    if (!active) return;
    const stream = new EventSource('/admin/api/notifications/events');
    let debounce: ReturnType<typeof setTimeout> | undefined;
    stream.onmessage = () => {
      if (!debounce) debounce = setTimeout(() => { debounce = undefined; refresh(); }, 250);
    };
    const timer = setInterval(() => { if (!document.hidden) refresh(); }, 15_000);
    return () => { stream.close(); clearInterval(timer); clearTimeout(debounce); };
  }, [active, refresh]);
  useEffect(() => {
    if (!toast) return;
    const timer = setTimeout(() => setToast(''), 4500);
    return () => clearTimeout(timer);
  }, [toast]);
  const botsResource = useResource<Bot[]>(active && route.page === 'messages' ? '/bots' : null, revision);
  const wechatResource = useResource<WechatChannel>(active && route.page !== 'messages' ? '/channels/wechat' : null, revision);
  const wechat = wechatResource.data?.connection ?? null;
  if (error) return <div className="boot"><ErrorLine error={error} /><Button onClick={() => (window.top ?? window).location.reload()}>重新登录</Button></div>;
  if (!active) return <Loading />;

  return <main className={'main hako-notification-content' + (route.page === 'messages' ? ' main-chat' : '')}>
    <ErrorLine error={botsResource.error || wechatResource.error} />
    {route.page === 'overview' && <OverviewPage wechat={wechat} revision={revision} navigate={navigate} />}
    {route.page === 'channels' && <ChannelsPage wechat={wechat} wechatReady={!!wechatResource.data} revision={revision} refresh={refresh} notify={notify} navigate={navigate} />}
    {route.page === 'messages' && (botsResource.loading && !botsResource.data ? <Loading /> :
      <MessagesPage bots={botsResource.data ?? []} revision={revision} refresh={refresh} notify={notify} route={route} navigate={navigate} />)}
    {route.page === 'webhooks' && <WebHooksPage wechatId={wechat?.accountId ? wechat.id : null} revision={revision} refresh={refresh} notify={notify} navigate={navigate} />}
    {toast && <div className="toast" role="status"><ShieldCheck size={18} />{toast}<button onClick={() => setToast('')} aria-label="关闭提示"><X size={15} /></button></div>}
  </main>;
}


function OverviewPage({ wechat, revision, navigate }: { wechat: Bot | null; revision: number; navigate: Navigate }) {
  const { data, error } = useResource<Overview>('/overview', revision);
  if (!data) return error ? <ErrorLine error={error} /> : <Loading />;
  const metrics = [
    { label: '微信在线连接', value: wechat?.status === 'online' ? 1 : 0, icon: MessageSquare, caption: '已建立的微信消息连接', style: 'green' },
    { label: '今日接收', value: data.receivedToday, icon: ArrowDownLeft, caption: '收到的微信消息', style: 'blue' },
    { label: '今日发送', value: data.sentToday, icon: ArrowUpRight, caption: '已提交平台的消息', style: 'purple' },
    { label: '待处理异常', value: data.failedToday, icon: Activity, caption: '今日失败或结果待确认', style: 'orange' },
  ];
  const max = Math.max(4, ...data.activity.flatMap(d => [d.incoming, d.outgoing]));
  return <div className="page-content overview"><ErrorLine error={error} /><div className="metrics">{metrics.map(metric => <div className="metric" key={metric.label}><div className="metric-top"><span>{metric.label}</span><span className={`metric-icon ${metric.style}`}><metric.icon size={18} /></span></div><div className="metric-value">{metric.value.toLocaleString()}</div><span className="metric-caption">{metric.caption}</span></div>)}</div>
    {!wechat?.accountId && <div className="welcome-banner"><div className="welcome-icon"><Zap size={26} /></div><div><h3>配置通知渠道</h3><p>绑定微信或登记 Apple Push 接收设备后，即可通过 Webhooks 发送通知。</p></div><Button variant="secondary" icon={ArrowRight} onClick={() => navigate('channels')}>配置渠道</Button></div>}
    <div className="overview-grid"><section className="panel"><div className="panel-header"><div><h2>消息活动</h2><p>最近 7 天的消息流动</p></div><div className="legend"><span><i className="legend-in" />接收</span><span><i className="legend-out" />发送</span></div></div>
      <div className="chart"><div className="chart-grid"><span>{max}</span><span>{Math.round(max / 2)}</span><span>0</span></div><div className="bars">{data.activity.map(day => <div className="bar-day" key={day.date}><div className="bar-pair" title={`${day.date} 接收 ${day.incoming} / 发送 ${day.outgoing}`}><div className="bar bar-in" style={{ height: `${day.incoming / max * 100}%`, minHeight: day.incoming ? 4 : 0 }} /><div className="bar bar-out" style={{ height: `${day.outgoing / max * 100}%`, minHeight: day.outgoing ? 4 : 0 }} /></div><span>{day.date.slice(5).replace('-', '/')}</span></div>)}</div>{!data.activity.some(d => d.incoming || d.outgoing) && <span className="chart-empty">接入后，这里会显示真实消息活动</span>}</div>
    </section><section className="panel"><div className="panel-header"><div><h2>连接状态</h2><p>微信连接与 Webhooks</p></div><button className="text-link" onClick={() => navigate('channels')}>管理 <ArrowRight size={14} /></button></div>
      <div className="connection-summary"><span className="connection-ring"><Radio size={29} /></span><div><strong>{data.webhooks}<small> 个启用的 Webhooks</small></strong></div></div>
      <div className="connection-list">{wechat?.accountId ? <button onClick={() => navigate('messages', wechat.id)}><span className="mini-platform"><MessageSquare size={15} /></span><strong>微信</strong><Status status={wechat.status} bot /></button> : <p className="quiet">微信尚未绑定</p>}</div><div className="queue-note"><span className="live-dot" />{data.queued ? `${data.queued} 条消息正在等待处理` : '当前没有待发送任务'}</div>
    </section></div>
    <section className="panel"><div className="panel-header"><div><h2>最近消息</h2><p>接收与发送，统一留痕</p></div><button className="text-link" onClick={() => navigate('messages')}>查看全部 <ArrowRight size={14} /></button></div>
      {!data.recentMessages.length ? <Empty icon={MessageSquare} title="消息将在这里汇合" text="绑定微信后，在微信中发一条消息即可建立会话。" /> : <div className="table-scroll"><table><thead><tr><th>消息内容</th><th>渠道 / 会话</th><th>来源</th><th>状态</th><th>时间</th></tr></thead><tbody>{data.recentMessages.map(message => <tr key={message.id} onClick={() => navigate('messages', message.botId)} className="clickable"><td><div className="message-preview"><span className={message.direction === 'in' ? 'direction-in' : 'direction-out'}>{message.direction === 'in' ? <ArrowDownLeft size={16} /> : <ArrowUpRight size={16} />}</span><span>{message.text}</span></div></td><td><strong>微信</strong><small className="cell-sub">{message.conversationName}</small></td><td><span className="source-tag">{message.source}</span></td><td><Status status={message.status} /></td><td className="nowrap quiet">{relative(message.createdAt)}</td></tr>)}</tbody></table></div>}
    </section><div className="page-foot"><Link2 size={13} /> iLinker · 让消息有序流动 <span>统计时区：Asia/Shanghai</span></div>
  </div>;
}
