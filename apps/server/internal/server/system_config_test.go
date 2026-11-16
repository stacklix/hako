package server

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"hako/server/internal/dbschema"
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
		Databases []databaseInfo
	}
	if err := json.Unmarshal(body, &result); err != nil {
		t.Fatal(err)
	}
	if len(result.Databases) != 4 {
		t.Fatalf("unexpected schema inventory: %s", body)
	}
	for i, want := range []string{"state", "notification_deliveries", "access_counts", "investment_daily_snapshots"} {
		db := result.Databases[i]
		expected := dbschema.CurrentVersion
		if want == "investment_daily_snapshots" {
			expected = investmentSchemaVersion
		}
		if db.Schema == nil || db.Schema.Version != expected || db.ExpectedVersion != expected || db.Status != "available" {
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

func TestAdminDatabaseQuery(t *testing.T) {
	f := newFixture(t, true)
	_, err := f.s.store.db.Exec(`CREATE TABLE preview(id INTEGER PRIMARY KEY, value TEXT); INSERT INTO preview VALUES (1,'<script>text</script>'),(2,NULL);`)
	if err != nil {
		t.Fatal(err)
	}
	guest := &adminClient{f: f}
	path := "/admin/api/system/databases/main/query"
	body := map[string]any{"sql": "SELECT * FROM preview ORDER BY id", "limit": 1}
	if code, _, _ := guest.request("POST", path, body, f.s.config.PublicURL, ""); code != 401 {
		t.Fatalf("guest query: %d", code)
	}
	admin := loginAdmin(f)
	if code, _, _ := admin.request("POST", path, body, f.s.config.PublicURL, "wrong"); code != 403 {
		t.Fatalf("missing CSRF protection: %d", code)
	}
	if code, _, _ := admin.request("POST", path, body, "https://other.example", admin.csrf); code != 403 {
		t.Fatalf("missing origin protection: %d", code)
	}
	data := admin.call("POST", "system/databases/main/query", body, 200)
	var result dbschema.QueryResult
	if err := json.Unmarshal(data, &result); err != nil {
		t.Fatal(err)
	}
	if len(result.Columns) != 2 || len(result.Rows) != 1 || !result.HasMore {
		t.Fatalf("bad result: %s", data)
	}
	admin.call("POST", "system/databases/main/query", map[string]any{"sql": "DELETE FROM preview"}, 400)
	admin.call("POST", "system/databases/main/query", map[string]any{"sql": "SELECT 1; DROP TABLE preview"}, 400)
	admin.call("POST", "system/databases/missing/query", body, 404)
	admin.call("POST", "system/databases/notifications/query", body, 409)
	admin.call("POST", "system/databases/access/query", body, 409)
	admin.call("POST", "system/databases/investment/query", map[string]any{"sql": "SELECT * FROM preview"}, 400)
	admin.call("POST", "system/databases/investment/query", map[string]any{"sql": "SELECT * FROM investment_accounts"}, 200)
	f.s.config.NotificationDataDir = t.TempDir()
	if err := f.s.startNotifications(); err != nil {
		t.Fatal(err)
	}
	admin.call("POST", "system/databases/notifications/query", map[string]any{"sql": "SELECT * FROM notification_deliveries"}, 200)
	logs, err := sql.Open("sqlite", f.s.config.Database+".access.db")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := logs.Exec("CREATE TABLE test_counts(count INTEGER); INSERT INTO test_counts VALUES (42)"); err != nil {
		t.Fatal(err)
	}
	logs.Close()
	admin.call("POST", "system/databases/access/query", map[string]any{"sql": "SELECT * FROM test_counts"}, 200)
}
