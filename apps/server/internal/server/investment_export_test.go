package server

import (
	"archive/zip"
	"bytes"
	"context"
	"database/sql"
	"encoding/csv"
	"io"
	"net/http"
	"strings"
	"testing"

	"hako/server/internal/dbschema"
)

func TestInvestmentExportIncludesCSVAndExecutableSchema(t *testing.T) {
	f := newFixture(t, true)
	const path = "/api/v1/investment/export"
	if status, _ := f.call(http.MethodGet, path, nil, ""); status != http.StatusUnauthorized {
		t.Fatalf("unauthenticated export = %d", status)
	}
	write := investmentWrite{Tables: investmentRows{
		"investment_accounts": {{"id": "account", "name": "测试,\"账户\"", "currency": "CNY", "account_type": "securities", "sort_order": "0"}},
		"investment_events":   {{"id": "event", "account_id": "account", "event_type": "deposit", "effective_date": "2026-11-09", "sequence": "0", "amount": "9007199254740993.0001"}},
	}}
	if status, body := f.call(http.MethodPut, "/api/v1/investment/book", write, f.tokens.AccessToken); status != 200 {
		t.Fatalf("write before export = %d %s", status, body)
	}
	write.Tables["investment_accounts"][0]["name"] = "其他账本"
	if _, err := f.s.persistInvestment(context.Background(), "other-owner", write); err != nil {
		t.Fatal(err)
	}
	status, body := f.call(http.MethodGet, path, nil, f.tokens.AccessToken)
	if status != 200 {
		t.Fatalf("export = %d %s", status, body)
	}
	archive, err := zip.NewReader(bytes.NewReader(body), int64(len(body)))
	if err != nil || len(archive.File) != len(investmentTables)+2 {
		t.Fatalf("archive: %v", err)
	}
	readFile := func(name string) string {
		t.Helper()
		file, err := archive.Open(name)
		if err != nil {
			t.Fatal(err)
		}
		defer file.Close()
		data, err := io.ReadAll(file)
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}
	readCSV := func(name string) []map[string]string {
		t.Helper()
		raw := readFile(name + ".csv")
		if !strings.HasPrefix(raw, "\ufeff") {
			t.Fatalf("missing UTF-8 BOM in %s", name)
		}
		records, err := csv.NewReader(strings.NewReader(strings.TrimPrefix(raw, "\ufeff"))).ReadAll()
		if err != nil || len(records) == 0 {
			t.Fatalf("invalid CSV %s: %v", name, err)
		}
		var rows []map[string]string
		for _, record := range records[1:] {
			row := map[string]string{}
			for i, value := range record {
				row[records[0][i]] = value
			}
			rows = append(rows, row)
		}
		return rows
	}
	books, accounts, events := readCSV("investment_books"), readCSV("investment_accounts"), readCSV("investment_events")
	if len(books) != 1 || len(accounts) != 1 || len(events) != 1 || accounts[0]["name"] != "测试,\"账户\"" ||
		events[0]["amount"] != "9007199254740993.0001" || events[0]["book_id"] != books[0]["id"] {
		t.Fatalf("unexpected exported rows: %v %v %v", books, accounts, events)
	}
	for _, table := range investmentTables {
		readCSV(table.name)
	}
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(readFile("schema.sql")); err != nil {
		t.Fatal(err)
	}
	schema, err := dbschema.Inspect(context.Background(), db)
	if err != nil || schema.Version != dbschema.CurrentVersion || len(schema.Tables) != len(investmentTables)+1 {
		t.Fatalf("recreated schema: %+v, %v", schema, err)
	}
	for _, table := range schema.Tables {
		if table.Name == "investment_events" && len(table.Indexes) == 1 {
			return
		}
	}
	t.Fatal("recreated schema is missing the event index")
}
