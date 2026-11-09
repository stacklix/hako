import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { PushDevice } from '../shared/types.js';
import type { ApnsProvider } from './apns.js';
import { AppError, Vault } from './security.js';
import { id, Store } from './store.js';

const DELIVERY_MS = 15 * 60_000;
const CONCURRENCY = 8;
const registration = z.object({
  token: z.string().regex(/^(?:[0-9a-f]{2}){1,512}$/i).transform(token => token.toLowerCase()),
  environment: z.enum(['sandbox', 'production']),
  deviceId: z.string().regex(/^[A-Za-z0-9_-]{43}$/),
}).strict();
interface DeviceRecord {
  id: string; name: string; environment: PushDevice['environment'];
  token: string | null; status: PushDevice['status']; updated_at: number;
}
interface Job { id: string; target_id: string; apns_payload: string; created_at: number }

export class Push {
  private timer?: ReturnType<typeof setInterval>;
  private pending = new Map<string, Promise<void>>();
  constructor(private store: Store, private vault: Vault, private changed: () => void,
    private provider: ApnsProvider | undefined, private trustedConsoles: string[]) {
    const current = this.currentDevice();
    if (current && !this.trustedConsoles.includes(current.consoleId)) {
      this.store.run("UPDATE push_devices SET token=NULL,status='revoked',updated_at=? WHERE id=?", Date.now(), current.id);
    }
  }

  private device(deviceId: string) {
    return this.store.get<DeviceRecord>('SELECT id,name,environment,token,status,updated_at FROM push_devices WHERE id=?', deviceId);
  }
  currentDevice() {
    return this.store.get<PushDevice & { consoleId: string }>(`SELECT id,name,environment,status,updated_at updatedAt,console_id consoleId
      FROM push_devices WHERE status<>'revoked'`);
  }

  register(app: FastifyInstance) {
    app.get('/api/v1/push/device', async () => {
      const device = this.currentDevice();
      return {
        configured: !!this.provider,
        device: device && { id: device.id, name: device.name, environment: device.environment, status: device.status, updatedAt: device.updatedAt },
      };
    });
    app.put('/internal/push/registration', async (request, reply) => {
      if (!this.provider) return reply.code(204).send();
      const body = registration.parse(request.body);
      if (!this.trustedConsoles.includes(body.deviceId)) throw new AppError(403, 'CONSOLE_NOT_TRUSTED', '设备未在 Hako 登记');
      const current = this.currentDevice();
      if (current && current.consoleId !== body.deviceId) {
        throw new AppError(409, 'PUSH_DEVICE_OCCUPIED', '已有 Hako 设备接收通知');
      }
      const token = this.vault.seal(body.token);
      if (current) {
        this.store.run("UPDATE push_devices SET token=?,environment=?,status='active',updated_at=? WHERE id=?",
          token, body.environment, Date.now(), current.id);
      } else {
        this.store.run("INSERT INTO push_devices (id,name,environment,console_id,token,status,updated_at) VALUES (?,'Hako iPhone',?,?,?,'active',?)",
          id('device'), body.environment, body.deviceId, token, Date.now());
      }
      this.changed();
      return reply.code(204).send();
    });
  }

  start() {
    this.store.run(`UPDATE notification_deliveries SET status='unknown',code='APNS_OUTCOME_UNKNOWN',
      error='网关在发送过程中重启，请确认接收情况',updated_at=? WHERE channel='apns' AND status='sending'`, Date.now());
    this.timer = setInterval(() => this.drain(), 500);
    this.timer.unref();
  }

  private drain() {
    const slots = CONCURRENCY - this.pending.size;
    if (!slots) return;
    const jobs = this.store.all<Job>(`SELECT d.id,d.target_id,r.apns_payload,r.created_at
      FROM notification_deliveries d JOIN webhook_requests r ON r.id=d.notification_id
      WHERE d.channel='apns' AND d.status='queued' ORDER BY d.updated_at,d.rowid LIMIT ?`, slots);
    for (const job of jobs) {
      const task = this.deliver(job).finally(() => this.pending.delete(job.id));
      this.pending.set(job.id, task);
    }
  }

  private async deliver(job: Job) {
    const update = (status: string, code: string | null = null, error: string | null = null) => {
      this.store.run('UPDATE notification_deliveries SET status=?,code=?,error=?,updated_at=? WHERE id=?', status, code, error, Date.now(), job.id);
      this.changed();
    };
    const expiresAt = job.created_at + DELIVERY_MS;
    if (Date.now() >= expiresAt) return update('failed', 'APNS_DELIVERY_EXPIRED', '等待发送 Apple Push 超时');
    if (!this.provider) return update('failed', 'APNS_NOT_CONFIGURED', '网关尚未配置 APNs');
    const device = this.device(job.target_id);
    if (device?.status !== 'active' || !device.token) return update('failed', 'APNS_DEVICE_UNAVAILABLE', 'Apple Push 设备已失效或解绑');
    let token: string;
    try { token = this.vault.open(device.token); }
    catch { return update('failed', 'APNS_DEVICE_UNAVAILABLE', '无法读取 Apple Push 设备凭证'); }
    update('sending');
    try {
      const result = await this.provider.send({ id: job.id, environment: device.environment, token, payload: job.apns_payload, expiresAt });
      if (result.status === 200) return update('provider_accepted');
      if (result.status === 410 && ['Unregistered', 'ExpiredToken'].includes(result.reason || '') &&
          (result.timestamp === undefined || device.updated_at <= result.timestamp)) {
        // A new registration received while the request was in flight supersedes the failed token.
        this.store.run("UPDATE push_devices SET status='invalid',token=NULL,updated_at=? WHERE id=? AND token=?",
          Date.now(), device.id, device.token);
      }
      const reason = result.reason && /^[A-Za-z0-9]{1,64}$/.test(result.reason) ? ` · ${result.reason}` : '';
      update('failed', `APNS_HTTP_${result.status}`, `APNs 拒绝请求（${result.status}${reason}）`);
    } catch {
      update('unknown', 'APNS_OUTCOME_UNKNOWN', 'APNs 请求中断，结果待确认');
    }
  }

  async close() {
    clearInterval(this.timer);
    this.provider?.close();
    await Promise.allSettled(this.pending.values());
  }
}
