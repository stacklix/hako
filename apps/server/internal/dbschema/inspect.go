package dbschema

import (
	"context"
	"database/sql"
)

type Table struct {
	Name    string   `json:"name"`
	SQL     string   `json:"sql"`
	Indexes []string `json:"indexes,omitempty"`
}

type Schema struct {
	Version int     `json:"version"`
	Tables  []Table `json:"tables"`
}

// Inspect reads SQLite metadata without querying application rows.
func Inspect(ctx context.Context, db *sql.DB) (Schema, error) {
	tx, err := db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return Schema{}, err
	}
	defer tx.Rollback()
	return InspectTx(ctx, tx)
}

// InspectTx reads the schema in the same SQLite snapshot as a caller's data queries.
func InspectTx(ctx context.Context, tx *sql.Tx) (Schema, error) {
	schema := Schema{Tables: []Table{}}
	if err := tx.QueryRowContext(ctx, "PRAGMA user_version").Scan(&schema.Version); err != nil {
		return Schema{}, err
	}
	rows, err := tx.QueryContext(ctx, `SELECT tbl_name, type, sql FROM sqlite_schema
		WHERE type IN ('table','index') AND name NOT GLOB 'sqlite_*' AND sql IS NOT NULL
		ORDER BY tbl_name, type DESC, name`)
	if err != nil {
		return Schema{}, err
	}
	defer rows.Close()
	for rows.Next() {
		var name, kind, definition string
		if err := rows.Scan(&name, &kind, &definition); err != nil {
			return Schema{}, err
		}
		if kind == "table" {
			schema.Tables = append(schema.Tables, Table{Name: name, SQL: definition})
		} else if n := len(schema.Tables); n > 0 && schema.Tables[n-1].Name == name {
			schema.Tables[n-1].Indexes = append(schema.Tables[n-1].Indexes, definition)
		}
	}
	return schema, rows.Err()
}
