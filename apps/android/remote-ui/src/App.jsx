import { useEffect, useMemo, useState } from 'react';
import { AlertCircle, CheckCircle2, Eye, EyeOff, Phone, RefreshCw, Send, Trash2 } from 'lucide-react';
import { Alert, AlertDescription } from './components/ui/alert.jsx';
import { Badge } from './components/ui/badge.jsx';
import { Button } from './components/ui/button.jsx';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from './components/ui/card.jsx';
import { Input } from './components/ui/input.jsx';
import { Label } from './components/ui/label.jsx';
import { Select } from './components/ui/select.jsx';
import { Switch } from './components/ui/switch.jsx';
import { Tabs, TabsList, TabsTrigger } from './components/ui/tabs.jsx';
import { Textarea } from './components/ui/textarea.jsx';
import { cn } from './lib/utils.js';

const mainTabs = [
  ['overview', '首页'],
  ['forwarding', '转发'],
  ['commands', '指令'],
  ['actions', '操作'],
  ['logs', '日志'],
];
const visibleRecentTypes = new Set(['sms_received', 'sms_command', 'sms_sent_command', 'call_received', 'call_out_command']);
const visibleLogTypes = new Set(['sms_received', 'sms_command', 'sms_sent_command', 'call_received', 'call_out_command', 'sms_forwarded', 'operation_log']);

function eventTitle(type) {
  return {
    sms_received: '收到短信',
    sms_history: '短信历史',
    call_received: '电话呼入',
    call_out_command: '电话呼出',
    sms_forwarded: '短信已转发',
    sms_command: '收到指令',
    sms_sent_command: '发送短信',
    operation_log: '业务日志',
  }[type] || '系统事件';
}

async function api(path, options = {}) {
  const res = await fetch(path, {
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
    ...options,
  });
  const text = await res.text();
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    data = { raw: text };
  }
  if (!res.ok) {
    const error = new Error(data.message || data.error || `HTTP ${res.status}`);
    error.status = res.status;
    error.data = data;
    throw error;
  }
  return data;
}

function simLabel(sim) {
  return sim ? `${sim.displayName || '未命名卡'} · ${sim.number || '未读取号码'}` : '';
}

function isToday(timestamp) {
  const date = new Date(timestamp || 0);
  const now = new Date();
  return date.getFullYear() === now.getFullYear() && date.getMonth() === now.getMonth() && date.getDate() === now.getDate();
}

export function App() {
  const [authenticated, setAuthenticated] = useState(null);
  const [snapshot, setSnapshot] = useState({});
  const [activeTab, setActiveTab] = useState('overview');
  const [notice, setNotice] = useState(null);
  const [busy, setBusy] = useState('');

  const config = snapshot.config || {};
  const forwarding = config.forwarding || {};
  const commands = config.commands || {};
  const remoteControl = config.remoteControl || {};

  const showNotice = (type, text) => {
    setNotice({ type, text });
    window.clearTimeout(window.__doppelNoticeTimer);
    window.__doppelNoticeTimer = window.setTimeout(() => setNotice(null), 2600);
  };

  const refreshSnapshot = async () => {
    const data = await api('/api/snapshot');
    setSnapshot(data || {});
    setAuthenticated(true);
  };

  useEffect(() => {
    refreshSnapshot().catch((error) => {
      if (error.status === 401) setAuthenticated(false);
      else showNotice('error', `刷新失败：${error.message}`);
    });
  }, []);

  const runButton = async (key, task) => {
    setBusy(key);
    try {
      return await task();
    } finally {
      setBusy('');
    }
  };

  const saveConfig = async (buttonKey, partial, successText = '保存成功') => {
    const data = await runButton(buttonKey, () => api('/api/config', { method: 'POST', body: JSON.stringify({ config: partial }) }));
    showNotice('ok', successText);
    setSnapshot(data.snapshot || (await api('/api/snapshot')));
  };

  const logout = async () => {
    await runButton('logout', () => api('/logout', { method: 'POST' }));
    setAuthenticated(false);
  };

  if (authenticated === null) {
    return <Shell><Card><CardContent className="p-6 text-sm text-muted-foreground">加载中...</CardContent></Card></Shell>;
  }

  if (!authenticated) {
    return <LoginPanel onLogin={() => refreshSnapshot()} busy={busy} runButton={runButton} />;
  }

  return (
    <Shell onLogout={logout} logoutBusy={busy === 'logout'} notice={notice}>
      <Tabs className="space-y-4">
        <TabsList className="grid h-auto w-full grid-cols-2 gap-1 md:grid-cols-5">
          {mainTabs.map(([key, label]) => (
            <TabsTrigger key={key} active={activeTab === key} onClick={() => setActiveTab(key)}>{label}</TabsTrigger>
          ))}
        </TabsList>
        {activeTab === 'overview' && <Overview snapshot={snapshot} onRefresh={() => runButton('refresh', refreshSnapshot)} refreshBusy={busy === 'refresh'} />}
        {activeTab === 'forwarding' && <Forwarding snapshot={snapshot} forwarding={forwarding} saveConfig={saveConfig} busy={busy} />}
        {activeTab === 'commands' && <Commands snapshot={snapshot} commands={commands} remoteControl={remoteControl} saveConfig={saveConfig} busy={busy} />}
        {activeTab === 'actions' && <Actions snapshot={snapshot} busy={busy} runButton={runButton} showNotice={showNotice} />}
        {activeTab === 'logs' && <Logs events={(snapshot.events || []).filter((event) => visibleLogTypes.has(event.type))} />}
      </Tabs>
    </Shell>
  );
}

function Shell({ children, onLogout, logoutBusy, notice }) {
  return (
    <main className="mx-auto max-w-6xl p-4 md:p-6">
      <header className="mb-5 flex items-start justify-between gap-4">
        <div>
          <h1 className="text-3xl font-extrabold tracking-tight text-primary">Doppel 远程控制</h1>
          <p className="mt-1 text-sm font-medium text-muted-foreground">HTTP 管理页面，请仅在可信网络中使用。</p>
        </div>
        {onLogout && <Button variant="secondary" loading={logoutBusy} onClick={onLogout}>退出</Button>}
      </header>
      {notice && (
        <div className="fixed left-1/2 top-6 z-20 w-[min(860px,calc(100vw-32px))] -translate-x-1/2">
          <Alert variant={notice.type === 'ok' ? 'default' : 'destructive'} className="bg-background shadow-lg">
            {notice.type === 'ok' ? <CheckCircle2 className="size-4" /> : <AlertCircle className="size-4" />}
            <AlertDescription className="font-bold">{notice.text}</AlertDescription>
          </Alert>
        </div>
      )}
      {children}
    </main>
  );
}

function LoginPanel({ onLogin, busy, runButton }) {
  const [password, setPassword] = useState('');
  const [message, setMessage] = useState('');
  const submit = async () => {
    setMessage('');
    try {
      await runButton('login', () => api('/login', { method: 'POST', body: JSON.stringify({ password }) }));
      await onLogin();
    } catch {
      setMessage('登录失败');
    }
  };
  return (
    <Shell>
      <Card className="mx-auto max-w-md">
        <CardHeader>
          <CardTitle>登录</CardTitle>
          <CardDescription>输入管理密码后使用远程控制。</CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label>管理密码</Label>
            <PasswordInput autoComplete="current-password" value={password} onChange={setPassword} onEnter={submit} />
          </div>
          <Button loading={busy === 'login'} onClick={submit}>登录</Button>
          {message && <p className="text-sm text-muted-foreground">{message}</p>}
        </CardContent>
      </Card>
    </Shell>
  );
}

function Overview({ snapshot, onRefresh, refreshBusy }) {
  const events = snapshot.events || [];
  const permissions = snapshot.permissions || {};
  const running = !!(permissions.sms && permissions.phone);
  const metric = (types, today) => events.filter((event) => types.includes(event.type) && (!today || isToday(event.timestamp))).length;
  const recent = events.filter((event) => visibleRecentTypes.has(event.type) && event.source !== 'system_sms' && Date.parse(event.timestamp || '') >= Date.now() - 86400000);
  return (
    <Card>
      <CardHeader className="flex-row items-center justify-between">
        <div>
          <CardTitle>首页</CardTitle>
          <CardDescription>运行状态和最近事件。</CardDescription>
        </div>
        <Badge variant={running ? 'default' : 'secondary'}>{running ? '运行中' : '等待授权'}</Badge>
      </CardHeader>
      <CardContent className="space-y-5">
        <div className="grid gap-3 md:grid-cols-4">
          <Metric title="短信事件" today={metric(['sms_received', 'sms_command'], true)} total={metric(['sms_received', 'sms_command'])} />
          <Metric title="来电事件" today={metric(['call_received'], true)} total={metric(['call_received'])} />
          <Metric title="转发短信" today={metric(['sms_forwarded'], true)} total={metric(['sms_forwarded'])} />
          <Metric title="短信指令" today={metric(['sms_command'], true)} total={metric(['sms_command'])} />
        </div>
        <Button variant="secondary" loading={refreshBusy} onClick={onRefresh}><RefreshCw className="size-4" />刷新</Button>
        <EventList title="最近事件" events={recent} />
      </CardContent>
    </Card>
  );
}

function Metric({ title, today, total }) {
  return (
    <div className="rounded-lg border bg-muted p-4">
      <strong className="block text-sm">{title}</strong>
      <div className="mt-3 flex items-center gap-2"><b className="text-2xl">{today}</b><span className="text-xs text-muted-foreground">今日</span></div>
      <div className="mt-1 flex items-center gap-2"><b className="text-lg">{total}</b><span className="text-xs text-muted-foreground">累计</span></div>
    </div>
  );
}

function Forwarding({ snapshot, forwarding, saveConfig, busy }) {
  const [tab, setTab] = useState('sms');
  return (
    <TwoPane tabs={[['sms', '转发到手机号'], ['email', '邮箱收件人'], ['http', 'HTTP 地址']]} value={tab} onChange={setTab}>
      {tab === 'sms' && <SmsForwarding snapshot={snapshot} forwarding={forwarding} saveConfig={saveConfig} busy={busy} />}
      {tab === 'email' && <EmailForwarding forwarding={forwarding} saveConfig={saveConfig} busy={busy} />}
      {tab === 'http' && <TargetPanel title="HTTP 地址" label="添加 HTTP 推送地址" placeholder="https://example.com/sms" items={forwarding.httpTargets || []} addKey="httpTargets" inputKey="newHttpTarget" saveConfig={saveConfig} busy={busy} />}
    </TwoPane>
  );
}

function SmsForwarding({ snapshot, forwarding, saveConfig, busy }) {
  const simCards = snapshot.simCards || [];
  const selected = forwarding.selectedSmsSim || simLabel(simCards[0]) || '';
  const [editing, setEditing] = useState(false);
  const [nextSim, setNextSim] = useState(selected);
  useEffect(() => setNextSim(selected), [selected]);
  return (
    <div className="space-y-4">
      <Card>
        <CardHeader><CardTitle>发送 SIM 卡</CardTitle></CardHeader>
        <CardContent>
          {!editing ? (
            <div className="flex items-center justify-between gap-3">
              <strong className="break-words">{selected || '默认发送卡'}</strong>
              <Button variant="secondary" onClick={() => setEditing(true)}>编辑</Button>
            </div>
          ) : (
            <div className="flex flex-col gap-2 md:flex-row">
              <Select value={nextSim} onChange={(event) => setNextSim(event.target.value)}>
                {simCards.length ? simCards.map((sim) => <option key={sim.subscriptionId || simLabel(sim)} value={simLabel(sim)}>{simLabel(sim)}</option>) : <option value="">默认发送卡</option>}
              </Select>
              <Button loading={busy === 'saveSim'} onClick={async () => { await saveConfig('saveSim', { forwarding: { selectedSmsSim: nextSim } }, '发送 SIM 卡已保存'); setEditing(false); }}>保存</Button>
              <Button variant="secondary" onClick={() => setEditing(false)}>取消</Button>
            </div>
          )}
        </CardContent>
      </Card>
      <TargetPanel title="接收手机号" label="添加手机号" placeholder="+86 13800138000" items={forwarding.smsTargets || []} addKey="smsTargets" inputKey="newSmsTarget" saveConfig={saveConfig} busy={busy} />
    </div>
  );
}

function EmailForwarding({ forwarding, saveConfig, busy }) {
  const smtp = forwarding.smtp || {};
  const [editing, setEditing] = useState(false);
  const [form, setForm] = useState(smtp);
  useEffect(() => setForm(smtp), [smtp.host, smtp.port, smtp.fromEmail, smtp.username, smtp.password]);
  return (
    <div className="space-y-4">
      <Card>
        <CardHeader><CardTitle>SMTP 发件配置</CardTitle></CardHeader>
        <CardContent>
          {!editing ? (
            <div className="flex items-center justify-between gap-3">
              <div>
                <strong>{smtp.fromEmail || '未配置发件邮箱'}</strong>
                <p className="mt-1 text-sm text-muted-foreground">{smtp.host ? `${smtp.host}:${smtp.port || '465'} · 用户名 ${smtp.username || '未配置'}` : '配置 SMTP 后才能自动转发到邮箱'}</p>
              </div>
              <Button variant="secondary" onClick={() => setEditing(true)}>编辑</Button>
            </div>
          ) : (
            <div className="space-y-3">
              <div className="grid gap-3 md:grid-cols-2">
                <Field label="服务器" value={form.host || ''} onChange={(value) => setForm({ ...form, host: value })} placeholder="smtp.example.com" />
                <Field label="端口" value={form.port || ''} onChange={(value) => setForm({ ...form, port: value })} placeholder="465" />
                <Field label="发件邮箱" value={form.fromEmail || ''} onChange={(value) => setForm({ ...form, fromEmail: value })} placeholder="sender@example.com" />
                <Field label="用户名" value={form.username || ''} onChange={(value) => setForm({ ...form, username: value })} />
                <div className="space-y-2 md:col-span-2">
                  <Label>密码</Label>
                  <PasswordInput value={form.password || ''} onChange={(value) => setForm({ ...form, password: value })} />
                </div>
              </div>
              <div className="flex gap-2">
                <Button loading={busy === 'saveSmtp'} onClick={async () => { await saveConfig('saveSmtp', { forwarding: { smtp: { ...form, port: form.port || '465' } } }, 'SMTP 已保存'); setEditing(false); }}>保存 SMTP</Button>
                <Button variant="secondary" onClick={() => setEditing(false)}>取消</Button>
              </div>
            </div>
          )}
        </CardContent>
      </Card>
      <TargetPanel title="邮箱收件人" label="添加邮箱" placeholder="notify@example.com" items={forwarding.emailTargets || []} addKey="emailTargets" inputKey="newEmailTarget" saveConfig={saveConfig} busy={busy} />
    </div>
  );
}

function TargetPanel({ title, label, placeholder, items, addKey, inputKey, saveConfig, busy }) {
  const [value, setValue] = useState('');
  const add = async () => {
    const trimmed = value.trim();
    if (!trimmed) return;
    if (items.some((item) => item.value === trimmed)) return;
    await saveConfig(`add-${inputKey}`, { forwarding: { [addKey]: [...items, { value: trimmed }] } }, '已添加');
    setValue('');
  };
  const remove = (index) => saveConfig(`delete-${addKey}-${index}`, { forwarding: { [addKey]: items.filter((_, itemIndex) => itemIndex !== index) } }, '已删除');
  return (
    <Card>
      <CardHeader><CardTitle>{title}</CardTitle></CardHeader>
      <CardContent className="space-y-3">
        <Label>{label}</Label>
        <div className="flex flex-col gap-2 md:flex-row">
          <Input value={value} placeholder={placeholder} onChange={(event) => setValue(event.target.value)} />
          <Button loading={busy === `add-${inputKey}`} onClick={add}>添加</Button>
        </div>
        <div className="grid gap-2">
          {items.length ? items.map((item, index) => (
            <div className="flex items-center justify-between rounded-lg border bg-muted p-3" key={`${item.value}-${index}`}>
              <strong className="min-w-0 break-words">{item.value || '未填写'}</strong>
              <Button variant="destructive" size="sm" loading={busy === `delete-${addKey}-${index}`} onClick={() => remove(index)}><Trash2 className="size-4" />删除</Button>
            </div>
          )) : <span className="text-sm text-muted-foreground">暂无配置</span>}
        </div>
      </CardContent>
    </Card>
  );
}

function Commands({ snapshot, commands, remoteControl, saveConfig, busy }) {
  const [tab, setTab] = useState('sms');
  return (
    <TwoPane tabs={[['sms', '短信指令'], ['http', 'HTTP 指令']]} value={tab} onChange={setTab}>
      {tab === 'sms' && <SmsCommands commands={commands} saveConfig={saveConfig} busy={busy} />}
      {tab === 'http' && <HttpCommands snapshot={snapshot} remoteControl={remoteControl} saveConfig={saveConfig} busy={busy} />}
    </TwoPane>
  );
}

function SmsCommands({ commands, saveConfig, busy }) {
  const trusted = commands.trustedNumbers || [];
  const [number, setNumber] = useState('');
  const saveCommands = (partial) => saveConfig('saveCommands', { commands: { callEnabled: commands.callEnabled !== false, smsEnabled: commands.smsEnabled !== false, trustedNumbers: trusted, ...partial } }, '指令配置已保存');
  return (
    <div className="space-y-4">
      <Card>
        <CardHeader><CardTitle>状态</CardTitle></CardHeader>
        <CardContent className="space-y-4">
          <SwitchLine title="远程打电话" subtitle="DOPPEL CALL 13800138000" checked={commands.callEnabled !== false} onCheckedChange={(value) => saveCommands({ callEnabled: value })} />
          <SwitchLine title="远程发短信" subtitle="DOPPEL SMS 13800138000 你好" checked={commands.smsEnabled !== false} onCheckedChange={(value) => saveCommands({ smsEnabled: value })} />
        </CardContent>
      </Card>
      <Card>
        <CardHeader>
          <CardTitle>配置</CardTitle>
          <CardDescription>可信号码添加后立即生效。</CardDescription>
        </CardHeader>
        <CardContent className="space-y-3">
          <Label>可信号码</Label>
          <div className="flex flex-col gap-2 md:flex-row">
            <Input value={number} placeholder="13800138000" onChange={(event) => setNumber(event.target.value)} />
            <Button loading={busy === 'addTrusted'} onClick={async () => { if (!number.trim()) return; await saveConfig('addTrusted', { commands: { callEnabled: commands.callEnabled !== false, smsEnabled: commands.smsEnabled !== false, trustedNumbers: [...trusted, { number: number.trim() }] } }, '可信号码已更新'); setNumber(''); }}>添加</Button>
          </div>
          {trusted.length ? trusted.map((item, index) => (
            <div className="flex items-center justify-between rounded-lg border bg-muted p-3" key={`${item.number}-${index}`}>
              <strong>{item.number || '未填写'}</strong>
              <Button variant="destructive" size="sm" onClick={() => saveConfig(`deleteTrusted-${index}`, { commands: { callEnabled: commands.callEnabled !== false, smsEnabled: commands.smsEnabled !== false, trustedNumbers: trusted.filter((_, itemIndex) => itemIndex !== index) } }, '可信号码已更新')}>删除</Button>
            </div>
          )) : <span className="text-sm text-muted-foreground">暂无可信号码</span>}
        </CardContent>
      </Card>
    </div>
  );
}

function HttpCommands({ snapshot, remoteControl, saveConfig, busy }) {
  const status = snapshot.remoteControlStatus || {};
  const [editing, setEditing] = useState(false);
  const [form, setForm] = useState(remoteControl);
  useEffect(() => setForm(remoteControl), [remoteControl.port, remoteControl.password, remoteControl.token]);
  return (
    <div className="space-y-4">
      <Card>
        <CardHeader><CardTitle>状态</CardTitle></CardHeader>
        <CardContent className="grid gap-3 md:grid-cols-2">
          <ReadOnlyField label="当前 IP" value={(status.ipAddresses || []).join(', ') || '未检测到局域网 IP'} />
          <ReadOnlyField label="服务状态" value={status.isRunning ? `运行中，端口 ${status.port || remoteControl.port || ''}` : '未运行'} />
        </CardContent>
      </Card>
      <Card>
        <CardHeader><CardTitle>配置</CardTitle></CardHeader>
        <CardContent>
          {!editing ? (
            <div className="space-y-3">
              <div className="grid gap-3 md:grid-cols-2">
                <ReadOnlyField label="监听端口" value={remoteControl.port || '18080'} />
                <ReadOnlyField label="管理密码" value={remoteControl.password ? '已配置' : '未配置'} />
                <ReadOnlyField label="接口 Token" value={remoteControl.token ? '已配置' : '未配置'} className="md:col-span-2" />
              </div>
              <Button variant="secondary" onClick={() => setEditing(true)}>编辑</Button>
            </div>
          ) : (
            <div className="space-y-3">
              <Field label="监听端口" value={form.port || ''} onChange={(value) => setForm({ ...form, port: value })} placeholder="18080" />
              <div className="space-y-2">
                <Label>管理密码</Label>
                <PasswordInput value={form.password || ''} onChange={(value) => setForm({ ...form, password: value })} />
              </div>
              <Field label="接口 Token" type="password" value={form.token || ''} onChange={(value) => setForm({ ...form, token: value })} />
              <div className="flex gap-2">
                <Button loading={busy === 'saveRemote'} onClick={async () => { await saveConfig('saveRemote', { remoteControl: { port: form.port || '18080', password: form.password || '', token: form.token || '' } }, '远程控制配置已保存'); setEditing(false); }}>保存远程控制</Button>
                <Button variant="secondary" onClick={() => setEditing(false)}>取消</Button>
              </div>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

function Actions({ snapshot, busy, runButton, showNotice }) {
  const [tab, setTab] = useState('sms');
  const simCards = snapshot.simCards || [];
  const defaultSim = (snapshot.config || {}).forwarding?.selectedSmsSim || simLabel(simCards[0]) || '';
  const [sms, setSms] = useState({ to: '', message: '', sim: defaultSim });
  const [call, setCall] = useState({ number: '', sim: defaultSim });
  const [history, setHistory] = useState([]);
  useEffect(() => {
    if (!sms.sim && defaultSim) setSms((value) => ({ ...value, sim: defaultSim }));
    if (!call.sim && defaultSim) setCall((value) => ({ ...value, sim: defaultSim }));
  }, [defaultSim, sms.sim, call.sim]);
  const runAction = async (key, type, task) => {
    try {
      const data = await runButton(key, task);
      const message = data.message || '操作已提交';
      showNotice('ok', `${type}成功：${message}`);
      setHistory((items) => [{ type, ok: true, message, time: new Date().toLocaleString() }, ...items].slice(0, 20));
    } catch (error) {
      const message = error.message || '操作失败';
      showNotice('error', `${type}失败：${message}`);
      setHistory((items) => [{ type, ok: false, message, time: new Date().toLocaleString() }, ...items].slice(0, 20));
    }
  };
  return (
    <TwoPane tabs={[['sms', '发送短信'], ['call', '发起拨号'], ['history', '操作历史']]} value={tab} onChange={setTab}>
      {tab === 'sms' && (
        <Card>
          <CardHeader><CardTitle>发送短信</CardTitle></CardHeader>
          <CardContent className="space-y-3">
            <Field label="目标号码" value={sms.to} onChange={(value) => setSms({ ...sms, to: value })} />
            <SimField label="发送 SIM 卡" value={sms.sim} simCards={simCards} onChange={(value) => setSms({ ...sms, sim: value })} />
            <Label>短信内容</Label>
            <Textarea value={sms.message} onChange={(event) => setSms({ ...sms, message: event.target.value })} />
            <Button loading={busy === 'sendSms'} onClick={() => runAction('sendSms', '发送短信', () => api('/api/sms/send', { method: 'POST', body: JSON.stringify(sms) }))}><Send className="size-4" />发送短信</Button>
          </CardContent>
        </Card>
      )}
      {tab === 'call' && (
        <Card>
          <CardHeader><CardTitle>发起拨号</CardTitle></CardHeader>
          <CardContent className="space-y-3">
            <Field label="电话号码" value={call.number} onChange={(value) => setCall({ ...call, number: value })} />
            <SimField label="拨号 SIM 卡" value={call.sim} simCards={simCards} onChange={(value) => setCall({ ...call, sim: value })} />
            <Button loading={busy === 'startCall'} onClick={() => runAction('startCall', '发起拨号', () => api('/api/call/start', { method: 'POST', body: JSON.stringify(call) }))}><Phone className="size-4" />拨号</Button>
          </CardContent>
        </Card>
      )}
      {tab === 'history' && <Card><CardHeader><CardTitle>操作历史</CardTitle></CardHeader><CardContent><div className="grid gap-2">{history.length ? history.map((item, index) => <EventRow key={index} event={{ type: 'operation_log', detail: `${item.type}：${item.ok ? '成功' : '失败'}，${item.message}`, timestamp: item.time }} />) : <span className="text-sm text-muted-foreground">暂无操作记录</span>}</div></CardContent></Card>}
    </TwoPane>
  );
}

function Logs({ events }) {
  return <Card><CardHeader><CardTitle>日志</CardTitle></CardHeader><CardContent><EventList events={events} /></CardContent></Card>;
}

function EventList({ title, events }) {
  return (
    <div className="space-y-3">
      {title && <h3 className="text-xl font-semibold">{title}</h3>}
      <div className="grid gap-2">{events.length ? events.map((event, index) => <EventRow key={`${event.timestamp}-${index}`} event={event} />) : <span className="text-sm text-muted-foreground">暂无事件</span>}</div>
    </div>
  );
}

function EventRow({ event }) {
  return (
    <div className="rounded-lg border bg-muted p-3">
      <strong>{eventTitle(event.type)}</strong>
      <span className="ml-2 text-sm text-muted-foreground">{event.detail || ''}</span>
      <div className="mt-1 text-xs text-muted-foreground">{event.timestamp ? new Date(event.timestamp).toLocaleString() : ''}</div>
      {event.content && <div className="mt-1 text-sm text-muted-foreground">{event.content}</div>}
    </div>
  );
}

function TwoPane({ tabs, value, onChange, children }) {
  return (
    <div className="grid gap-4 md:grid-cols-[210px_minmax(0,1fr)]">
      <nav className="self-start rounded-lg border bg-card p-2 md:sticky md:top-4" aria-label="页面分组">
        <div className="grid gap-1">
          {tabs.map(([key, label]) => {
            const active = value === key;
            return (
              <Button
                key={key}
                variant={active ? 'secondary' : 'ghost'}
                className="justify-start"
                onClick={() => onChange(key)}
                type="button"
              >
                <span className="min-w-0 truncate">{label}</span>
              </Button>
            );
          })}
        </div>
      </nav>
      <div className="min-w-0">{children}</div>
    </div>
  );
}

function Field({ label, value, onChange, className, type = 'text', placeholder }) {
  return <div className={cn('space-y-2', className)}><Label>{label}</Label><Input type={type} value={value} placeholder={placeholder} onChange={(event) => onChange(event.target.value)} /></div>;
}

function PasswordInput({ value, onChange, autoComplete, onEnter }) {
  const [visible, setVisible] = useState(false);
  return (
    <div className="flex gap-2">
      <Input
        type={visible ? 'text' : 'password'}
        autoComplete={autoComplete}
        value={value}
        onChange={(event) => onChange(event.target.value)}
        onKeyDown={(event) => event.key === 'Enter' && onEnter?.()}
      />
      <Button
        type="button"
        variant="secondary"
        size="icon"
        aria-label={visible ? '隐藏密码' : '显示密码'}
        title={visible ? '隐藏密码' : '显示密码'}
        onClick={() => setVisible(!visible)}
      >
        {visible ? <EyeOff className="size-4" /> : <Eye className="size-4" />}
      </Button>
    </div>
  );
}

function SimField({ label, value, simCards, onChange }) {
  return (
    <div className="space-y-2">
      <Label>{label}</Label>
      <Select value={value || ''} onChange={(event) => onChange(event.target.value)} disabled={!simCards.length}>
        {simCards.length ? simCards.map((sim) => {
          const labelValue = simLabel(sim);
          return <option key={sim.subscriptionId || labelValue} value={labelValue}>{labelValue}</option>;
        }) : <option value="">无可用 SIM 卡</option>}
      </Select>
    </div>
  );
}

function ReadOnlyField({ label, value, className }) {
  return <div className={cn('rounded-lg border bg-muted p-3', className)}><strong className="block text-sm text-muted-foreground">{label}</strong><span className="mt-1 block break-words font-semibold">{value}</span></div>;
}

function SwitchLine({ title, subtitle, checked, onCheckedChange }) {
  return <div className="flex items-center justify-between gap-3"><div><strong>{title}</strong><p className="mt-1 text-sm text-muted-foreground">{subtitle}</p></div><Switch checked={checked} onCheckedChange={onCheckedChange} /></div>;
}
