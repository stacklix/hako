import { Smartphone } from 'lucide-react';
import type { PushDevice } from '../shared/types';
import { ErrorLine, fullTime, Loading, useResource } from './ui';

export function PushSettings({ revision }: { revision: number }) {
  const { data, error, loading } = useResource<{ configured: boolean; device?: PushDevice }>('/push/device', revision);
  const device = data?.device;
  return <section className="panel">
    <div className="panel-header"><div><h2>Apple Push</h2><p>使用已登记的 Hako iPhone 接收文本通知</p></div><Smartphone size={21} /></div>
    <div className="settings-form">
      <ErrorLine error={error} />
      {loading && !data && <Loading />}
      {data && !data.configured && <p className="quiet">请在 Hako 部署环境配置 APNs 密钥和 Bundle ID。</p>}
      {data?.configured && !device && <p className="quiet">请在 iPhone 上打开 Hako 并登录服务器。设备会自动登记。</p>}
      {device && <div className="webhook-target-hint">
        <strong>{device.name}</strong>
        <p>{device.status === 'active' ? '已登记' : '设备 Token 已失效，等待 Hako 更新'} · {device.environment === 'production' ? '生产环境' : '沙盒'}</p>
        <p>最近登记 {fullTime(device.updatedAt)}</p>
      </div>}
    </div>
  </section>;
}
