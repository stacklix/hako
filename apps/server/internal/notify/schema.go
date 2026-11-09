package notify

import (
	"database/sql"
	"fmt"

	"hako/server/internal/dbschema"
)

func initSchema(db *sql.DB) error {
	if _, err := db.Exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000"); err != nil {
		return err
	}
	err := dbschema.Initialize(db, func(tx *sql.Tx) error {
		_, err := tx.Exec(schema)
		return err
	})
	if err != nil {
		return fmt.Errorf("open notification database: %w", err)
	}
	return nil
}

const schema = `
      CREATE TABLE bots (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, platform TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
        note TEXT NOT NULL DEFAULT '', credentials TEXT, base_url TEXT, account_id TEXT, peer_id TEXT,
        cursor TEXT NOT NULL DEFAULT '', enabled INTEGER NOT NULL DEFAULT 0, last_error TEXT,
        last_seen_at INTEGER, created_at INTEGER NOT NULL, deleted_at INTEGER,
        CHECK ((account_id IS NULL) = (peer_id IS NULL))
      );
      CREATE UNIQUE INDEX bots_account ON bots(platform, account_id) WHERE account_id IS NOT NULL AND deleted_at IS NULL;
      CREATE TABLE conversations (
        id TEXT PRIMARY KEY, bot_id TEXT NOT NULL UNIQUE REFERENCES bots(id), peer_id TEXT NOT NULL,
        name TEXT NOT NULL, remark TEXT NOT NULL DEFAULT '', context TEXT,
        unread INTEGER NOT NULL DEFAULT 0,
        last_message TEXT NOT NULL DEFAULT '', last_message_at INTEGER NOT NULL
      );
      CREATE TABLE webhooks (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, bot_id TEXT REFERENCES bots(id),
        enabled INTEGER NOT NULL DEFAULT 1,
        token_hash TEXT NOT NULL UNIQUE, token_hint TEXT NOT NULL, rate_limit INTEGER NOT NULL DEFAULT 60,
        expires_at INTEGER, created_at INTEGER NOT NULL,
        apns_enabled INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE messages (
        seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
        bot_id TEXT NOT NULL REFERENCES bots(id), conversation_id TEXT NOT NULL REFERENCES conversations(id),
        direction TEXT NOT NULL, type TEXT NOT NULL DEFAULT 'text', text TEXT NOT NULL,
        status TEXT NOT NULL, source TEXT NOT NULL, webhook_id TEXT,
        provider_key TEXT, error TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        UNIQUE(bot_id, provider_key)
      );
      CREATE INDEX messages_conversation ON messages(conversation_id, seq);
      CREATE INDEX messages_queue ON messages(status, seq);
      CREATE INDEX messages_time ON messages(created_at);
      CREATE INDEX messages_webhook ON messages(webhook_id, seq);
      CREATE INDEX messages_inbound_time ON messages(conversation_id,MIN(created_at,updated_at)) WHERE direction='in';
      CREATE TABLE send_window_reminders (
        conversation_id TEXT PRIMARY KEY REFERENCES conversations(id),
        window_start INTEGER NOT NULL, message_id TEXT NOT NULL
      );
      CREATE TABLE message_images (
        message_id TEXT PRIMARY KEY REFERENCES messages(id), source_url TEXT, data BLOB, mime TEXT
      );
      CREATE TABLE webhook_requests (
        id TEXT PRIMARY KEY, webhook_id TEXT NOT NULL REFERENCES webhooks(id), message_id TEXT,
        status TEXT NOT NULL, summary TEXT NOT NULL, error TEXT, ip TEXT NOT NULL, created_at INTEGER NOT NULL,
        apns_payload TEXT
      );
      CREATE INDEX requests_webhook ON webhook_requests(webhook_id, created_at);
      CREATE TABLE idempotency (
        webhook_id TEXT NOT NULL REFERENCES webhooks(id), key TEXT NOT NULL, fingerprint TEXT NOT NULL,
        notification_id TEXT NOT NULL, created_at INTEGER NOT NULL,
        PRIMARY KEY(webhook_id, key)
      );
      CREATE TABLE bot_logs (
        id TEXT PRIMARY KEY, bot_id TEXT NOT NULL REFERENCES bots(id), level TEXT NOT NULL,
        event TEXT NOT NULL, detail TEXT NOT NULL, created_at INTEGER NOT NULL
      );
      CREATE TABLE push_devices (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, environment TEXT NOT NULL,
        console_id TEXT NOT NULL, token TEXT,
        status TEXT NOT NULL, updated_at INTEGER NOT NULL
      );
      CREATE UNIQUE INDEX push_devices_current ON push_devices((1)) WHERE status<>'revoked';
      CREATE TABLE apns_config (
        id INTEGER PRIMARY KEY CHECK(id=1), team_id TEXT NOT NULL, key_id TEXT NOT NULL,
        bundle_id TEXT NOT NULL, private_key TEXT NOT NULL
      );
      CREATE TABLE direct_push (
        id TEXT PRIMARY KEY, target_id TEXT NOT NULL, target_name TEXT NOT NULL,
        payload TEXT NOT NULL, status TEXT NOT NULL, code TEXT, error TEXT,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
      );
      CREATE INDEX direct_push_time ON direct_push(created_at, id);
      CREATE INDEX direct_push_queue ON direct_push(status, created_at);
      CREATE TABLE notification_deliveries (
        id TEXT PRIMARY KEY, notification_id TEXT NOT NULL UNIQUE REFERENCES webhook_requests(id) ON DELETE CASCADE,
        channel TEXT NOT NULL, target_id TEXT NOT NULL, target_name TEXT NOT NULL,
        message_id TEXT REFERENCES messages(id), status TEXT NOT NULL, code TEXT, error TEXT,
        updated_at INTEGER NOT NULL
      );
      CREATE INDEX notification_deliveries_queue ON notification_deliveries(channel,status,updated_at);
      CREATE INDEX notification_deliveries_channel ON notification_deliveries(channel,notification_id);
    `
