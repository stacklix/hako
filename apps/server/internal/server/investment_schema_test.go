package server

import (
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
)

func TestInvestmentDatabaseRejectsOldSchemaWithoutChangingRecords(t *testing.T) {
	directory := t.TempDir()
	db, err := sql.Open("sqlite", filepath.Join(directory, "investment.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`
		CREATE TABLE investment_assets (id TEXT PRIMARY KEY, asset_type TEXT, collateral_asset_id TEXT);
		INSERT INTO investment_assets VALUES ('legacy', 'crypto_contract', 'spot');
		PRAGMA user_version=2;
	`); err != nil {
		t.Fatal(err)
	}
	var originalSchema string
	if err := db.QueryRow("SELECT sql FROM sqlite_schema WHERE name='investment_assets'").Scan(&originalSchema); err != nil {
		t.Fatal(err)
	}
	opened, err := openInvestmentDB(filepath.Join(directory, "main.sqlite"))
	if opened != nil {
		opened.Close()
		t.Fatal("old schema was opened")
	}
	if err == nil || !strings.Contains(err.Error(), "unsupported database schema version 2 (expected 5)") {
		t.Fatalf("old schema error = %v", err)
	}
	var version int
	if err := db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 2 {
		t.Fatalf("old schema version changed: %d (%v)", version, err)
	}
	var schema, assetType, collateral string
	if err := db.QueryRow("SELECT sql FROM sqlite_schema WHERE name='investment_assets'").Scan(&schema); err != nil || schema != originalSchema {
		t.Fatalf("old table definition changed: %q (%v)", schema, err)
	}
	if err := db.QueryRow("SELECT asset_type,collateral_asset_id FROM investment_assets WHERE id='legacy'").Scan(&assetType, &collateral); err != nil || assetType != "crypto_contract" || collateral != "spot" {
		t.Fatalf("old records changed: %s %s (%v)", assetType, collateral, err)
	}
}
