package server

import (
	"archive/zip"
	"bytes"
	"context"
	"database/sql"
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"hako/server/internal/dbschema"
)

func (s *Server) exportInvestment(w http.ResponseWriter, r *http.Request) {
	owner, ok := s.investmentOwner(w, r)
	if !ok {
		return
	}
	data, err := investmentArchive(r.Context(), s.investment, owner)
	if err != nil {
		reject(w, http.StatusServiceUnavailable, "storage_unavailable")
		return
	}
	filename := "investment-ledger-" + time.Now().UTC().Format(time.DateOnly) + ".zip"
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", `attachment; filename="`+filename+`"`)
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	_, _ = w.Write(data)
}

func investmentArchive(ctx context.Context, db *sql.DB, owner string) ([]byte, error) {
	tx, err := db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var bookID sql.NullString
	if err := tx.QueryRowContext(ctx, "SELECT id FROM investment_books WHERE owner_id=?", owner).Scan(&bookID); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	schema, err := dbschema.InspectTx(ctx, tx)
	if err != nil {
		return nil, err
	}
	var buffer bytes.Buffer
	archive := zip.NewWriter(&buffer)
	if err := writeInvestmentSchema(archive, schema); err != nil {
		return nil, err
	}
	bookColumns := strings.Fields("owner_id id name timezone generation revision snapshot_dirty_from snapshot_through")
	if err := writeInvestmentCSV(ctx, tx, archive, "investment_books", bookColumns, "owner_id", owner, "owner_id"); err != nil {
		return nil, err
	}
	for _, table := range investmentTables {
		columns := append([]string{"book_id"}, table.columns()...)
		order := strings.Join(strings.Fields(table.keys), ",")
		if err := writeInvestmentCSV(ctx, tx, archive, table.name, columns, "book_id", bookID, order); err != nil {
			return nil, err
		}
	}
	if err := archive.Close(); err != nil {
		return nil, err
	}
	return buffer.Bytes(), nil
}

func writeInvestmentSchema(archive *zip.Writer, schema dbschema.Schema) error {
	file, err := archive.Create("schema.sql")
	if err != nil {
		return err
	}
	var sql strings.Builder
	sql.WriteString("BEGIN TRANSACTION;\n\n")
	for _, table := range schema.Tables {
		sql.WriteString(table.SQL + ";\n")
		for _, index := range table.Indexes {
			sql.WriteString(index + ";\n")
		}
		sql.WriteByte('\n')
	}
	fmt.Fprintf(&sql, "PRAGMA user_version = %d;\nCOMMIT;\n", schema.Version)
	_, err = io.WriteString(file, sql.String())
	return err
}

// Table names, column names and sort order come from the ledger schema, never the HTTP request.
func writeInvestmentCSV(ctx context.Context, tx *sql.Tx, archive *zip.Writer, table string, columns []string, scope string, id any, order string) error {
	rows, err := tx.QueryContext(ctx, "SELECT "+strings.Join(columns, ",")+" FROM "+table+" WHERE "+scope+"=? ORDER BY "+order, id)
	if err != nil {
		return err
	}
	defer rows.Close()
	file, err := archive.Create(table + ".csv")
	if err != nil {
		return err
	}
	// A UTF-8 BOM lets spreadsheet apps identify Chinese text on opening.
	if _, err := io.WriteString(file, "\ufeff"); err != nil {
		return err
	}
	writer := csv.NewWriter(file)
	if err := writer.Write(columns); err != nil {
		return err
	}
	values := make([]sql.NullString, len(columns))
	args := make([]any, len(columns))
	record := make([]string, len(columns))
	for i := range values {
		args[i] = &values[i]
	}
	for rows.Next() {
		if err := rows.Scan(args...); err != nil {
			return err
		}
		for i, value := range values {
			record[i] = value.String
		}
		if err := writer.Write(record); err != nil {
			return err
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	writer.Flush()
	return writer.Error()
}
