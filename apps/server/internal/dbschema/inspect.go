package dbschema

import (
	"context"
	"database/sql"
)

type Table struct {
	Name    string   `json:"name"`
	SQL     string   `json:"sql"`
	Indexes []string `json:"indexes,omitempty"`
	Columns []Column `json:"columns"`
}

type Column struct {
	Name       string  `json:"name"`
	Type       string  `json:"type"`
	NotNull    bool    `json:"notNull"`
	Default    *string `json:"default"`
	PrimaryKey int     `json:"primaryKey"`
	Hidden     int     `json:"hidden"`
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
	if err := rows.Err(); err != nil {
		return schema, err
	}
	if err := rows.Close(); err != nil {
		return schema, err
	}
	for i := range schema.Tables {
		columns, err := tx.QueryContext(ctx, `SELECT name,type,"notnull",dflt_value,pk,hidden FROM pragma_table_xinfo(?)`, schema.Tables[i].Name)
		if err != nil {
			return schema, err
		}
		schema.Tables[i].Columns = []Column{}
		for columns.Next() {
			var c Column
			if err := columns.Scan(&c.Name, &c.Type, &c.NotNull, &c.Default, &c.PrimaryKey, &c.Hidden); err != nil {
				columns.Close()
				return schema, err
			}
			schema.Tables[i].Columns = append(schema.Tables[i].Columns, c)
		}
		err = columns.Err()
		columns.Close()
		if err != nil {
			return schema, err
		}
	}
	return schema, nil
}
