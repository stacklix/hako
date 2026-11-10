package server

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

func TestAdminDatabaseSchemas(t *testing.T) {
	f := newFixture(t, true)
	f.s.config.NotificationDataDir = t.TempDir()
	if err := f.s.startNotifications(); err != nil {
		t.Fatal(err)
	}
	logs, err := sql.Open("sqlite", f.s.config.Database+".access.db")
	if err != nil {
		t.Fatal(err)
	}
	_, err = logs.Exec(`CREATE TABLE access_counts (id INTEGER PRIMARY KEY, count INTEGER);
		CREATE INDEX access_total ON access_counts(count);
		INSERT INTO access_counts VALUES (1,123456789);
		PRAGMA user_version = 2;`)
	logs.Close()
	if err != nil {
		t.Fatal(err)
	}

	guest := &adminClient{f: f}
	if code, _, _ := guest.request("GET", "/admin/api/system/databases", nil, "", ""); code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated schema request: %d", code)
	}
	admin := loginAdmin(f)
	body := admin.call("GET", "system/databases", nil, 200)
	if strings.Contains(string(body), "123456789") {
		t.Fatal("schema response included application row data")
	}
	var result struct {
		ExpectedVersion int
		Databases       []databaseInfo
	}
	if err := json.Unmarshal(body, &result); err != nil {
		t.Fatal(err)
	}
	if result.ExpectedVersion != 2 || len(result.Databases) != 4 {
		t.Fatalf("unexpected schema inventory: %s", body)
	}
	for i, want := range []string{"state", "notification_deliveries", "access_counts", "investment_daily_snapshots"} {
		db := result.Databases[i]
		if db.Schema == nil || db.Schema.Version != 2 || db.Status != "available" {
			t.Fatalf("%s schema is unavailable: %+v", db.Name, db)
		}
		found := false
		for _, table := range db.Schema.Tables {
			if table.Name == want {
				found = strings.Contains(table.SQL, "CREATE TABLE")
				if want == "access_counts" && len(table.Indexes) != 1 {
					t.Fatalf("missing access log index: %+v", table)
				}
			}
		}
		if !found {
			t.Fatalf("missing %s table definition", want)
		}
	}
}
