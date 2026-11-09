package notify

import (
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
)

func TestStartupRejectsUnmigratedNotificationsWithoutResetting(t *testing.T) {
	config := Config{DataDir: t.TempDir()}
	legacy, err := sql.Open("sqlite", filepath.Join(config.DataDir, "notifications.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer legacy.Close()
	if _, err := legacy.Exec("CREATE TABLE bots (id TEXT PRIMARY KEY); INSERT INTO bots VALUES ('old-bot')"); err != nil {
		t.Fatal(err)
	}

	if s, err := New(config); err == nil || !strings.Contains(err.Error(), "database has not been migrated") {
		if s != nil {
			s.Close()
		}
		t.Fatalf("expected an explicit migration error, got %v", err)
	}

	var id string
	if err := legacy.QueryRow("SELECT id FROM bots").Scan(&id); err != nil || id != "old-bot" {
		t.Fatalf("legacy data changed: id=%q, error=%v", id, err)
	}
	var version int
	if err := legacy.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 0 {
		t.Fatalf("schema version changed: version=%d, error=%v", version, err)
	}
}
