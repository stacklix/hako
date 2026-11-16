package dbschema

import (
	"context"
	"database/sql"
	"strings"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

func TestQueryReadOnlyAndPagination(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(`CREATE TABLE sample(id INTEGER PRIMARY KEY, name TEXT DEFAULT 'hello', extra BLOB);
		INSERT INTO sample VALUES(1,'one',x'0102'),(2,NULL,NULL),(3,'three',NULL);`); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	first, err := Query(ctx, db, "WITH items AS (SELECT * FROM sample) SELECT * FROM items ORDER BY id; -- comment", 2, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(first.Rows) != 2 || !first.HasMore || first.Rows[0][0] != "1" || first.Rows[0][2] != "[BLOB: 2 bytes]" || first.Rows[1][1] != nil {
		t.Fatalf("bad first page: %+v", first)
	}
	last, err := Query(ctx, db, "SELECT * FROM sample ORDER BY id", 2, 2)
	if err != nil || len(last.Rows) != 1 || last.HasMore || last.Rows[0][0] != "3" {
		t.Fatalf("bad last page: %+v, %v", last, err)
	}
	for _, query := range []string{
		`SELECT ';', 'it''s; fine', "name" FROM sample /* ; ignored */;`,
		"SELECT 1 -- comment\n; /* after semicolon */", `SELECT 9223372036854775807`,
		`SELECT 1e999`,
	} {
		if _, err := Query(ctx, db, query, 100, 0); err != nil {
			t.Fatalf("valid query %q: %v", query, err)
		}
	}
	for _, query := range []string{
		`DELETE FROM sample RETURNING id`, `INSERT INTO sample(id) VALUES(4) RETURNING id`,
		`UPDATE sample SET name='changed'`, `DROP TABLE sample`, `PRAGMA user_version=9`,
		`ATTACH DATABASE ':memory:' AS other`, `BEGIN`, `VACUUM`,
		`SELECT 1; DELETE FROM sample`, `SELECT 1); DELETE FROM sample; --`,
		`WITH items AS (SELECT 1) DELETE FROM sample RETURNING id`,
		`SELECT 1 /* unfinished`, `SELECT 'unfinished`, "", strings.Repeat(" ", 20001),
	} {
		if _, err := Query(ctx, db, query, 100, 0); err == nil {
			t.Fatalf("accepted nonquery %q", query)
		}
	}
	var count int
	if err := db.QueryRow("SELECT count(*) FROM sample").Scan(&count); err != nil || count != 3 {
		t.Fatalf("data was modified: %d %v", count, err)
	}
	if _, err := Query(ctx, db, "SELECT 1", 201, 0); err == nil {
		t.Fatal("unbounded page accepted")
	}
	clipped, err := Query(ctx, db, "SELECT '"+strings.Repeat("中", 5000)+"'", 1, 0)
	if err != nil || !clipped.Clipped || !strings.HasSuffix(clipped.Rows[0][0].(string), "[内容已截断]") {
		t.Fatalf("long cell: %+v %v", clipped, err)
	}
	schema, err := Inspect(ctx, db)
	if err != nil || len(schema.Tables) != 1 {
		t.Fatalf("inspect: %+v %v", schema, err)
	}
	columns := schema.Tables[0].Columns
	if len(columns) != 3 || columns[0].PrimaryKey != 1 || columns[1].Default == nil || *columns[1].Default != "'hello'" {
		t.Fatalf("missing column metadata: %+v", columns)
	}

	cancelCtx, cancel := context.WithTimeout(ctx, 20*time.Millisecond)
	defer cancel()
	_, err = Query(cancelCtx, db, `WITH RECURSIVE nums(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM nums) SELECT sum(n) FROM nums`, 1, 0)
	if err == nil || cancelCtx.Err() == nil {
		t.Fatalf("expensive query was not canceled: %v", err)
	}
	if _, err := Query(ctx, db, "SELECT count(*) FROM sample", 1, 0); err != nil {
		t.Fatalf("connection not reusable after cancellation: %v", err)
	}
}
