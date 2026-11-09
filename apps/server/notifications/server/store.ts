import { DatabaseSync, type SQLInputValue } from 'node:sqlite';
import { randomUUID } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import type { Bot, Conversation, WebHook, Message, NotificationChannel, NotificationDelivery, NotificationStatus, WebHookRequest } from '../shared/types.js';
import { SEND_WINDOW_CODE, SEND_WINDOW_MESSAGE } from './send-window.js';

export const id = (prefix: string) => `${prefix}_${randomUUID().replaceAll('-', '')}`;
export interface BotRecord {
  id: string; name: string; platform: string; status: Bot['status']; note: string;
  credentials: string | null; base_url: string | null; account_id: string | null; peer_id: string | null;
  cursor: string; enabled: number; last_error: string | null; last_seen_at: number | null; created_at: number;
}
export interface ConversationRecord {
  id: string; bot_id: string; peer_id: string; name: string; remark: string;
  context: string | null; unread: number;
  last_message: string; last_message_at: number;
}
export interface WebHookRecord {
  id: string; name: string; bot_id: string | null; enabled: number;
  apns_enabled: number; default_channels: string;
  token_hash: string; token_hint: string; rate_limit: number; expires_at: number | null; created_at: number;
}

export class Store {
  db: DatabaseSync;
  private transactionDepth = 0;
  constructor(dataDir: string) {
    mkdirSync(dataDir, { recursive: true });
    this.db = new DatabaseSync(join(dataDir, 'ilinker.sqlite'));
    this.db.exec(`
      PRAGMA journal_mode=WAL;
      PRAGMA foreign_keys=ON;
      PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS bots (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, platform TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
        note TEXT NOT NULL DEFAULT '', credentials TEXT, base_url TEXT, account_id TEXT, peer_id TEXT,
        cursor TEXT NOT NULL DEFAULT '', enabled INTEGER NOT NULL DEFAULT 0, last_error TEXT,
        last_seen_at INTEGER, created_at INTEGER NOT NULL, deleted_at INTEGER,
        CHECK ((account_id IS NULL) = (peer_id IS NULL))
      );
      CREATE UNIQUE INDEX IF NOT EXISTS bots_account ON bots(platform, account_id) WHERE account_id IS NOT NULL AND deleted_at IS NULL;
      CREATE TABLE IF NOT EXISTS conversations (
        id TEXT PRIMARY KEY, bot_id TEXT NOT NULL UNIQUE REFERENCES bots(id), peer_id TEXT NOT NULL,
        name TEXT NOT NULL, remark TEXT NOT NULL DEFAULT '', context TEXT,
        unread INTEGER NOT NULL DEFAULT 0,
        last_message TEXT NOT NULL DEFAULT '', last_message_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS webhooks (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, bot_id TEXT REFERENCES bots(id),
        enabled INTEGER NOT NULL DEFAULT 1,
        token_hash TEXT NOT NULL UNIQUE, token_hint TEXT NOT NULL, rate_limit INTEGER NOT NULL DEFAULT 60,
        expires_at INTEGER, created_at INTEGER NOT NULL,
        apns_enabled INTEGER NOT NULL DEFAULT 0, default_channels TEXT NOT NULL DEFAULT '["wechat"]'
      );
      CREATE TABLE IF NOT EXISTS messages (
        seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
        bot_id TEXT NOT NULL REFERENCES bots(id), conversation_id TEXT NOT NULL REFERENCES conversations(id),
        direction TEXT NOT NULL, type TEXT NOT NULL DEFAULT 'text', text TEXT NOT NULL,
        status TEXT NOT NULL, source TEXT NOT NULL, webhook_id TEXT,
        provider_key TEXT, error TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        UNIQUE(bot_id, provider_key)
      );
      CREATE INDEX IF NOT EXISTS messages_conversation ON messages(conversation_id, seq);
      CREATE INDEX IF NOT EXISTS messages_queue ON messages(status, seq);
      CREATE INDEX IF NOT EXISTS messages_time ON messages(created_at);
      CREATE INDEX IF NOT EXISTS messages_webhook ON messages(webhook_id, seq);
      CREATE INDEX IF NOT EXISTS messages_inbound_time ON messages(conversation_id,MIN(created_at,updated_at)) WHERE direction='in';
      CREATE TABLE IF NOT EXISTS send_window_reminders (
        conversation_id TEXT PRIMARY KEY REFERENCES conversations(id),
        window_start INTEGER NOT NULL, message_id TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS message_images (
        message_id TEXT PRIMARY KEY REFERENCES messages(id), source_url TEXT, data BLOB, mime TEXT
      );
      CREATE TABLE IF NOT EXISTS webhook_requests (
        id TEXT PRIMARY KEY, webhook_id TEXT NOT NULL REFERENCES webhooks(id), message_id TEXT,
        status TEXT NOT NULL, summary TEXT NOT NULL, error TEXT, ip TEXT NOT NULL, created_at INTEGER NOT NULL,
        channels TEXT, apns_payload TEXT
      );
      CREATE INDEX IF NOT EXISTS requests_webhook ON webhook_requests(webhook_id, created_at);
      CREATE TABLE IF NOT EXISTS idempotency (
        webhook_id TEXT NOT NULL REFERENCES webhooks(id), key TEXT NOT NULL, fingerprint TEXT NOT NULL,
        notification_id TEXT NOT NULL, created_at INTEGER NOT NULL,
        PRIMARY KEY(webhook_id, key)
      );
      CREATE TABLE IF NOT EXISTS bot_logs (
        id TEXT PRIMARY KEY, bot_id TEXT NOT NULL REFERENCES bots(id), level TEXT NOT NULL,
        event TEXT NOT NULL, detail TEXT NOT NULL, created_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS push_devices (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, environment TEXT NOT NULL,
        console_id TEXT NOT NULL, token TEXT,
        status TEXT NOT NULL, updated_at INTEGER NOT NULL
      );
      CREATE UNIQUE INDEX IF NOT EXISTS push_devices_current ON push_devices((1)) WHERE status<>'revoked';
      CREATE TABLE IF NOT EXISTS notification_deliveries (
        id TEXT PRIMARY KEY, notification_id TEXT NOT NULL REFERENCES webhook_requests(id) ON DELETE CASCADE,
        channel TEXT NOT NULL, target_id TEXT NOT NULL, target_name TEXT NOT NULL,
        message_id TEXT REFERENCES messages(id), status TEXT NOT NULL, code TEXT, error TEXT,
        updated_at INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS notification_deliveries_parent ON notification_deliveries(notification_id);
      CREATE INDEX IF NOT EXISTS notification_deliveries_queue ON notification_deliveries(channel,status,updated_at);
    `);
    if (this.all<{ name: string }>('PRAGMA table_info(push_devices)').some(column => column.name === 'credential_hash')) {
      this.transaction(() => {
        this.db.exec(`
          UPDATE push_devices SET status='revoked',token=NULL;
          ALTER TABLE push_devices RENAME COLUMN credential_hash TO console_id;
          ALTER TABLE push_devices DROP COLUMN token_hash;
          DROP TABLE IF EXISTS push_pairings;
        `);
      });
    }
    if (!this.all<{ name: string }>('PRAGMA table_info(webhooks)').some(column => column.name === 'default_channels')) {
      this.db.exec('PRAGMA foreign_keys=OFF');
      try {
        this.transaction(() => {
          this.db.exec(`
            CREATE TABLE webhooks_new (
              id TEXT PRIMARY KEY, name TEXT NOT NULL, bot_id TEXT REFERENCES bots(id),
              enabled INTEGER NOT NULL DEFAULT 1, token_hash TEXT NOT NULL UNIQUE, token_hint TEXT NOT NULL,
              rate_limit INTEGER NOT NULL DEFAULT 60, expires_at INTEGER, created_at INTEGER NOT NULL,
              apns_enabled INTEGER NOT NULL DEFAULT 0, default_channels TEXT NOT NULL DEFAULT '["wechat"]'
            );
            INSERT INTO webhooks_new (id,name,bot_id,enabled,token_hash,token_hint,rate_limit,expires_at,created_at)
              SELECT id,name,bot_id,enabled,token_hash,token_hint,rate_limit,expires_at,created_at FROM webhooks;
            DROP TABLE webhooks;
            ALTER TABLE webhooks_new RENAME TO webhooks;
            ALTER TABLE webhook_requests ADD COLUMN channels TEXT;
            ALTER TABLE webhook_requests ADD COLUMN apns_payload TEXT;
            ALTER TABLE idempotency DROP COLUMN message_id;
            ALTER TABLE idempotency RENAME COLUMN request_id TO notification_id;
            UPDATE webhook_requests SET channels='["wechat"]' WHERE message_id IS NOT NULL;
            INSERT INTO notification_deliveries (id,notification_id,channel,target_id,target_name,message_id,status,updated_at)
              SELECT r.id,r.id,'wechat',m.bot_id,b.name,m.id,m.status,m.updated_at
              FROM webhook_requests r JOIN messages m ON m.id=r.message_id JOIN bots b ON b.id=m.bot_id;
          `);
          if (this.get('PRAGMA foreign_key_check')) throw new Error('Webhook 数据迁移外键校验失败');
        });
      } finally {
        this.db.exec('PRAGMA foreign_keys=ON');
      }
    }
  }
  conversation(botId: string): ConversationRecord | undefined {
    return this.get<ConversationRecord>('SELECT * FROM conversations WHERE bot_id=?', botId);
  }
  all<T = Record<string, unknown>>(sql: string, ...params: SQLInputValue[]): T[] {
    return this.db.prepare(sql).all(...params) as unknown as T[];
  }
  get<T = Record<string, unknown>>(sql: string, ...params: SQLInputValue[]): T | undefined {
    return this.db.prepare(sql).get(...params) as unknown as T | undefined;
  }
  run(sql: string, ...params: SQLInputValue[]) { return this.db.prepare(sql).run(...params); }
  transaction<T>(callback: () => T): T {
    const depth = this.transactionDepth++;
    const savepoint = `ilinker_tx_${depth}`;
    try {
      this.db.exec(depth ? `SAVEPOINT ${savepoint}` : 'BEGIN IMMEDIATE');
      try { const value = callback(); this.db.exec(depth ? `RELEASE ${savepoint}` : 'COMMIT'); return value; }
      catch (error) { this.db.exec(depth ? `ROLLBACK TO ${savepoint}; RELEASE ${savepoint}` : 'ROLLBACK'); throw error; }
    } finally { this.transactionDepth--; }
  }
  bots(): Bot[] {
    return this.all<BotRecord & { unread: number; webhookCount: number; conversationId: string | null; conversationName: string | null }>(`
      SELECT b.*, COALESCE(c.unread,0) unread,c.id conversationId,
      COALESCE(NULLIF(c.remark,''),c.name) conversationName,
      (SELECT COUNT(*) FROM webhooks WHERE bot_id=b.id) webhookCount
      FROM bots b LEFT JOIN conversations c ON c.bot_id=b.id
      WHERE b.deleted_at IS NULL ORDER BY b.created_at DESC`).map(b => ({
        id: b.id, name: b.name, platform: b.platform, status: b.status, note: b.note,
        accountId: b.account_id, lastError: b.last_error, lastSeenAt: b.last_seen_at,
        createdAt: b.created_at, hasCredentials: !!b.credentials, unread: b.unread,
        webhookCount: b.webhookCount, conversationId: b.conversationId, conversationName: b.conversationName,
      }));
  }
  webhooks(): WebHook[] {
    return this.all<WebHookRecord & { botName: string | null; conversationId: string | null; conversationName: string | null; requestCount: number; failureCount: number; lastUsedAt: number | null }>(`
      SELECT h.*, b.name botName,c.id conversationId,COALESCE(NULLIF(c.remark,''),c.name) conversationName,
      (SELECT COUNT(*) FROM webhook_requests r WHERE r.webhook_id=h.id) requestCount,
      (SELECT COUNT(*) FROM webhook_requests r WHERE r.webhook_id=h.id AND (r.status='rejected' OR EXISTS (
        SELECT 1 FROM notification_deliveries d LEFT JOIN messages m ON m.id=d.message_id
        WHERE d.notification_id=r.id AND COALESCE(m.status,d.status) IN ('failed','unknown')))) failureCount,
      (SELECT MAX(created_at) FROM webhook_requests r WHERE r.webhook_id=h.id) lastUsedAt
      FROM webhooks h LEFT JOIN bots b ON b.id=h.bot_id LEFT JOIN conversations c ON c.bot_id=h.bot_id
      ORDER BY h.created_at DESC`).map(h => ({
        id: h.id, name: h.name, botId: h.bot_id, conversationId: h.conversationId,
        apnsEnabled: !!h.apns_enabled, defaultChannels: JSON.parse(h.default_channels) as NotificationChannel[],
        enabled: !!h.enabled, tokenHint: h.token_hint, rateLimit: h.rate_limit,
        expiresAt: h.expires_at, createdAt: h.created_at, botName: h.botName,
        conversationName: h.conversationName, requestCount: h.requestCount,
        failureCount: h.failureCount, lastUsedAt: h.lastUsedAt,
      }));
  }
  log(botId: string, event: string, detail: string, level = 'info') {
    this.run('INSERT INTO bot_logs VALUES (?,?,?,?,?,?)', id('log'), botId, level, event, detail, Date.now());
  }
  requests(webhookId?: string): WebHookRequest[] {
    const requests = this.all<WebHookRequest>(`SELECT id,webhook_id webhookId,message_id messageId,status,summary,error,ip,created_at createdAt
      FROM webhook_requests ${webhookId ? 'WHERE webhook_id=?' : ''}
      ORDER BY created_at DESC,rowid DESC LIMIT 100`, ...(webhookId ? [webhookId] : []));
    return requests.map(request => {
      if (request.status === 'rejected') return request;
      const deliveries = this.deliveries(request.id);
      return { ...request, deliveries, status: notificationStatus(deliveries) };
    });
  }
  deliveries(notificationId: string): NotificationDelivery[] {
    return this.all<NotificationDelivery>(`
      SELECT d.id,d.channel,d.target_id targetId,d.target_name targetName,d.message_id messageId,
        COALESCE(m.status,d.status) status,COALESCE(m.updated_at,d.updated_at) updatedAt,
        CASE WHEN m.id IS NULL THEN d.code WHEN m.error=? THEN ? END code,
        CASE WHEN m.id IS NULL THEN d.error ELSE m.error END error
      FROM notification_deliveries d LEFT JOIN messages m ON m.id=d.message_id
      WHERE d.notification_id=? ORDER BY d.rowid`, SEND_WINDOW_MESSAGE, SEND_WINDOW_CODE, notificationId);
  }
  close() { this.db.close(); }
}

export function notificationStatus(deliveries: NotificationDelivery[]): NotificationStatus {
  const statuses = deliveries.map(delivery => delivery.status);
  if (!statuses.length) return 'failed';
  if (statuses.every(status => status === 'queued')) return 'queued';
  if (statuses.some(status => status === 'queued' || status === 'sending')) return 'sending';
  if (statuses.includes('unknown')) return 'unknown';
  if (statuses.every(status => status === 'provider_accepted')) return 'provider_accepted';
  return statuses.includes('provider_accepted') ? 'partial_failure' : 'failed';
}

export const messageColumns = `messages.id,messages.bot_id botId,messages.conversation_id conversationId,messages.direction,messages.type,messages.text,messages.status,messages.source,messages.webhook_id webhookId,messages.error,messages.created_at createdAt,messages.updated_at updatedAt,
  CASE WHEN EXISTS (SELECT 1 FROM message_images media WHERE media.message_id=messages.id AND media.data IS NOT NULL)
    THEN '/admin/api/notifications/messages/' || messages.id || '/image' ELSE NULL END imageUrl`;
export function toConversation(c: ConversationRecord): Conversation {
  return { id: c.id, botId: c.bot_id, peerId: c.peer_id, name: c.name, remark: c.remark,
    unread: c.unread, lastMessage: c.last_message,
    lastMessageAt: c.last_message_at, hasContext: !!c.context };
}
export const getMessage = (store: Store, messageId: string) => store.get<Message>(`SELECT ${messageColumns} FROM messages WHERE id=?`, messageId);
