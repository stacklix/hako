package notify

import (
	"database/sql"
	"path/filepath"
	"testing"
)

func TestStartupResetsLegacyNotificationsOnlyOnce(t *testing.T) {
	config := Config{DataDir: t.TempDir()}
	legacy, err := sql.Open("sqlite", filepath.Join(config.DataDir, "notifications.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	_, err = legacy.Exec(`CREATE TABLE bots (id TEXT PRIMARY KEY);
		INSERT INTO bots VALUES ('old-bot');
		CREATE TABLE push_pairings (id TEXT PRIMARY KEY);
		CREATE TABLE apns_config (id INTEGER PRIMARY KEY);
		INSERT INTO apns_config VALUES (1);`)
	legacy.Close()
	if err != nil {
		t.Fatal(err)
	}

	s, err := New(config)
	if err != nil {
		t.Fatal(err)
	}
	var count int
	err = s.db.QueryRow(`SELECT (SELECT COUNT(*) FROM bots) +
		(SELECT COUNT(*) FROM apns_config) +
		(SELECT COUNT(*) FROM sqlite_schema WHERE name='push_pairings')`).Scan(&count)
	if err != nil || count != 0 {
		s.Close()
		t.Fatalf("legacy data or tables survived: count=%d, error=%v", count, err)
	}
	err = exec(s.db, "INSERT INTO bots(id,name,platform,created_at) VALUES ('new-bot','New',?,1)", botPlatform)
	s.Close()
	if err != nil {
		t.Fatal(err)
	}

	restarted, err := New(config)
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	if err := restarted.db.QueryRow("SELECT COUNT(*) FROM bots WHERE id='new-bot'").Scan(&count); err != nil || count != 1 {
		t.Fatalf("restart did not preserve new data: count=%d, error=%v", count, err)
	}
}

func TestNotificationMigrationRollsBackOnSchemaConflict(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	if err := exec(db, `CREATE TABLE bots (id TEXT PRIMARY KEY);
		INSERT INTO bots VALUES ('old-bot');
		CREATE TABLE other (id TEXT);
		CREATE INDEX bots_account ON other(id);`); err != nil {
		t.Fatal(err)
	}
	if err := initSchema(db); err == nil {
		t.Fatal("schema conflict should have failed migration")
	}
	var count, version int
	if err := db.QueryRow("SELECT COUNT(*) FROM bots WHERE id='old-bot'").Scan(&count); err != nil || count != 1 {
		t.Fatalf("failed migration did not preserve legacy data: count=%d, error=%v", count, err)
	}
	if err := db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 0 {
		t.Fatalf("failed migration advanced schema version: version=%d, error=%v", version, err)
	}
}
