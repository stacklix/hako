import { useState } from 'react';
import { KeyRound, Send, Smartphone } from 'lucide-react';
import type { PushChannel, PushConfig } from '../shared/types';
import { api } from './api';
import { PushComposer } from './PushMessages';
import { Button, ErrorLine, fullTime, Loading, Modal, useResource } from './ui';

export function PushSettings({ revision, refresh, notify }: { revision: number; refresh: () => void; notify: (message: string) => void }) {
  const { data, error, loading } = useResource<PushChannel>('/push/device', revision);
  const [editing, setEditing] = useState(false), [testing, setTesting] = useState(false);
  const device = data?.device, config = data?.config;
  return <section className="panel">
    <div className="panel-header"><div><h2>Apple Push</h2><p>向已登记的 Hako iPhone 发送文本通知</p></div><Smartphone size={21} /></div>
    <div className="settings-form">
      <ErrorLine error={error} />
      {loading && !data && <Loading />}
      {config ? <div className="webhook-target-hint">
        <strong>{config.source === 'environment' ? '已使用部署环境中的 APNs 密钥' : '已保存 APNs 配置'}</strong>
        <p>Team ID {config.teamId} · Key ID {config.keyId}</p>
        <p>Bundle ID {config.bundleId}</p>
      </div> : data && <p className="quiet">请填写 Apple Team ID、Key ID 和 Bundle ID，并选择 APNs .p8 私钥。</p>}
      {data?.configured && !device && <p className="quiet">请在 iPhone 上打开 Hako，登录这台服务器并允许通知。设备会自动登记。</p>}
      {device && <div className="webhook-target-hint">
        <strong>{device.name}</strong>
        <p>{device.status === 'active' ? '已登记' : '设备 Token 已失效，等待 Hako 更新'} · {device.environment === 'production' ? '生产环境' : '沙盒'}</p>
        <p>最近登记 {fullTime(device.updatedAt)}</p>
      </div>}
      <div className="inline-actions">
        <Button icon={KeyRound} disabled={!data} onClick={() => setEditing(true)}>{config ? '编辑 APNs 配置' : '配置 APNs'}</Button>
        <Button variant="secondary" icon={Send} disabled={!data?.configured || device?.status !== 'active'} onClick={() => setTesting(true)}>发送测试通知</Button>
      </div>
    </div>
    {editing && <PushConfigModal config={config} onClose={() => setEditing(false)} onSaved={() => {
      setEditing(false); refresh(); notify('APNs 配置已保存');
    }} />}
    {testing && <PushComposer test onClose={() => setTesting(false)} onQueued={() => {
      setTesting(false); refresh(); notify('测试通知已排队，可在消息中心查看投递结果');
    }} />}
  </section>;
}

function PushConfigModal({ config, onClose, onSaved }: { config?: PushConfig | null; onClose: () => void; onSaved: () => void }) {
  const [teamId, setTeamId] = useState(config?.teamId ?? ''), [keyId, setKeyId] = useState(config?.keyId ?? '');
  const [bundleId, setBundleId] = useState(config?.bundleId ?? 'me.stackli.hako');
  const [busy, setBusy] = useState(false), [error, setError] = useState('');
  return <Modal title="配置 Apple Push" subtitle="保存后立即应用于新投递。" onClose={onClose}>
    <form className="modal-form" onSubmit={async e => {
      e.preventDefault();
      const file = (new FormData(e.currentTarget)).get('privateKey');
      if (!(file instanceof File) || !file.size || file.size > 4096) {
        setError('请选择不超过 4 KB 的 Apple .p8 私钥。'); return;
      }
      setBusy(true); setError('');
      try {
        await api('/push/config', { method: 'PUT', body: JSON.stringify({ teamId, keyId, bundleId, privateKey: await file.text() }) });
        onSaved();
      } catch (error) { setError((error as Error).message); }
      finally { setBusy(false); }
    }}>
      <div className="two-fields">
        <label>Apple Team ID<input required pattern="[A-Z0-9]{10}" maxLength={10} autoComplete="off" value={teamId} onChange={e => setTeamId(e.target.value.trim().toUpperCase())} /></label>
        <label>Key ID<input required pattern="[A-Z0-9]{10}" maxLength={10} autoComplete="off" value={keyId} onChange={e => setKeyId(e.target.value.trim().toUpperCase())} /></label>
      </div>
      <label>Bundle ID<input required maxLength={255} autoComplete="off" value={bundleId} onChange={e => setBundleId(e.target.value)} /></label>
      <label>APNs 私钥（.p8）<input type="file" name="privateKey" accept=".p8" required /><small>每次保存都需要选择私钥。私钥由服务器加密保存。</small></label>
      <ErrorLine error={error} />
      <div className="modal-footer"><Button type="button" variant="secondary" onClick={onClose}>取消</Button><Button type="submit" busy={busy}>保存配置</Button></div>
    </form>
  </Modal>;
}
