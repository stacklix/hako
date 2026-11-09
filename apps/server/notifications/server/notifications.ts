import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { notificationChannels, type NotificationChannel, type NotificationResult } from '../shared/types.js';
import { Gateway } from './gateway.js';
import { notificationFingerprint, notificationSummary, parseNotification } from './images.js';
import { Push } from './push.js';
import { AppError } from './security.js';
import { id, notificationStatus, Store, type WebHookRecord } from './store.js';

export const channelList = z.array(z.enum(notificationChannels)).min(1).max(notificationChannels.length)
  .refine(channels => new Set(channels).size === channels.length, '通知渠道不能重复')
  .transform(channels => channels.sort());
const requestBody = z.object({ channels: channelList.optional(), message: z.unknown() }).strict();
const keyBody = z.string().min(1).max(128).optional();

export class Notifications {
  constructor(private store: Store, private gateway: Gateway, private push: Push) {}

  result(webhookId: string, notificationId: string): NotificationResult {
    if (!this.store.get("SELECT 1 FROM webhook_requests WHERE id=? AND webhook_id=? AND status<>'rejected'", notificationId, webhookId)) {
      throw new AppError(404, 'NOTIFICATION_NOT_FOUND', '通知不存在');
    }
    const deliveries = this.store.deliveries(notificationId);
    return { notificationId, status: notificationStatus(deliveries), deliveries };
  }

  submit(webhook: WebHookRecord, input: unknown, ip: string, rawKey?: unknown, test = false): NotificationResult {
    let summary = '';
    try {
      const body = requestBody.parse(input);
      const message = parseNotification(body.message), key = keyBody.parse(rawKey);
      const fingerprint = notificationFingerprint(message);
      summary = notificationSummary(message).slice(0, 120);
      const now = Date.now();
      const notificationId = this.store.transaction(() => {
        const existing = key && this.store.get<{ fingerprint: string; notification_id: string; channels: string }>(`
          SELECT i.fingerprint,i.notification_id,r.channels FROM idempotency i JOIN webhook_requests r ON r.id=i.notification_id
          WHERE i.webhook_id=? AND i.key=? AND i.created_at>?`, webhook.id, key, now - 86_400_000);
        if (existing) {
          const original = (JSON.parse(existing.channels) as NotificationChannel[]).sort();
          if (existing.fingerprint !== fingerprint || (body.channels && body.channels.join(',') !== original.join(','))) {
            throw new AppError(409, 'IDEMPOTENCY_CONFLICT', '同一个幂等键不能用于不同消息或渠道');
          }
          return existing.notification_id;
        }
        const channels = body.channels ?? JSON.parse(webhook.default_channels) as NotificationChannel[];
        if (channels.some(channel => channel === 'wechat' ? !webhook.bot_id : !webhook.apns_enabled)) {
          throw new AppError(403, 'CHANNEL_NOT_ALLOWED', 'Webhook 未授权所选通知渠道');
        }
        const notificationId = id('ntf');
        let apnsPayload: string | null = null;
        if (channels.includes('apns')) {
          if (message.type !== 'text') throw new AppError(422, 'CHANNEL_MESSAGE_UNSUPPORTED', 'Apple Push 只支持文本消息');
          apnsPayload = JSON.stringify({
            aps: { alert: { title: webhook.name, body: message.text }, sound: 'default' },
            type: 'ilinker_notification', notificationId,
          });
          if (Buffer.byteLength(apnsPayload) > 4096) throw new AppError(422, 'APNS_PAYLOAD_TOO_LARGE', 'Apple Push 消息超过 4096 字节');
        }
        const count = this.store.get<{ count: number }>("SELECT COUNT(*) count FROM webhook_requests WHERE webhook_id=? AND created_at>? AND status<>'rejected'",
          webhook.id, now - 60_000)!.count;
        if (count >= webhook.rate_limit) throw new AppError(429, 'WEBHOOK_RATE_LIMITED', 'Webhooks 调用频率超过限制');
        this.store.run(`INSERT INTO webhook_requests (id,webhook_id,status,summary,ip,created_at,channels,apns_payload)
          VALUES (?,?,'queued',?,?,?,?,?)`, notificationId, webhook.id, summary, ip, now, JSON.stringify(channels), apnsPayload);
        const insertDelivery = (channel: NotificationChannel, targetId: string, targetName: string,
          messageId: string | null = null, error?: AppError) =>
          this.store.run(`INSERT INTO notification_deliveries (id,notification_id,channel,target_id,target_name,message_id,status,code,error,updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?)`, randomUUID(), notificationId, channel, targetId, targetName, messageId, error ? 'failed' : 'queued',
            error?.code ?? null, error?.message ?? null, now);
        if (channels.includes('wechat') && webhook.bot_id) {
          const bot = this.store.get<{ name: string; deleted_at: number | null }>('SELECT name,deleted_at FROM bots WHERE id=?', webhook.bot_id);
          try {
            if (!bot || bot.deleted_at !== null) throw new AppError(404, 'BOT_NOT_FOUND', '微信机器人已删除');
            const source = `Webhooks · ${webhook.name}${test ? '（后台测试）' : ''}`;
            const queued = this.gateway.enqueueNotification(webhook.bot_id, message, source, webhook.id);
            insertDelivery('wechat', webhook.bot_id, bot.name, queued.id);
            this.store.run('UPDATE webhook_requests SET message_id=? WHERE id=?', queued.id, notificationId);
          } catch (error) {
            if (!(error instanceof AppError)) throw error;
            insertDelivery('wechat', webhook.bot_id, bot?.name ?? '微信机器人', null, error);
          }
        }
        if (apnsPayload) {
          const device = this.push.currentDevice();
          const error = device?.status === 'active' ? undefined :
            new AppError(409, 'APNS_DEVICE_UNAVAILABLE', 'Apple Push 设备未绑定或已失效');
          insertDelivery('apns', device?.id ?? 'hako', device?.name ?? 'Hako', null, error);
        }
        if (key) this.store.run('INSERT OR REPLACE INTO idempotency (webhook_id,key,fingerprint,notification_id,created_at) VALUES (?,?,?,?,?)',
          webhook.id, key, fingerprint, notificationId, now);
        return notificationId;
      });
      this.gateway.changed(webhook.bot_id ?? undefined);
      return this.result(webhook.id, notificationId);
    } catch (error) {
      this.store.run(`INSERT INTO webhook_requests (id,webhook_id,status,summary,error,ip,created_at)
        VALUES (?,?,'rejected',?,?,?,?)`, id('req'), webhook.id, summary,
        error instanceof AppError ? error.message : '请求内容不正确', ip, Date.now());
      throw error;
    }
  }
}
