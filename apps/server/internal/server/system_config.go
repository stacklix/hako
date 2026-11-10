package server

import (
	"database/sql"
	"errors"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"hako/server/internal/dbschema"
)

type databaseInfo struct {
	Name   string           `json:"name"`
	File   string           `json:"file"`
	Status string           `json:"status"`
	Schema *dbschema.Schema `json:"schema,omitempty"`
}

func (s *Server) adminDatabaseSchemas(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	describe := func(name, file string, schema dbschema.Schema, err error) databaseInfo {
		info := databaseInfo{Name: name, File: filepath.Base(file), Status: "unreadable"}
		if err == nil {
			info.Status = "available"
			info.Schema = &schema
		}
		return info
	}

	mainSchema, err := dbschema.Inspect(ctx, s.store.db)
	main := describe("服务端主库", s.config.Database, mainSchema, err)

	notifications := databaseInfo{Name: "通知网关", File: "notifications.sqlite", Status: "disabled"}
	if s.notifications != nil {
		schema, err := s.notifications.DatabaseSchema(ctx)
		notifications = describe(notifications.Name, notifications.File, schema, err)
	}

	accessFile := s.config.Database + ".access.db"
	access := databaseInfo{Name: "访问日志", File: filepath.Base(accessFile), Status: "not_created"}
	if s.accessLogs != nil {
		schema, err := s.accessLogs.DatabaseSchema(ctx)
		access = describe(access.Name, accessFile, schema, err)
	} else if s.config.Database != ":memory:" {
		// A disabled scanner can still have a database from an earlier deployment.
		schema, err := inspectInactiveDatabase(r, accessFile)
		if !errors.Is(err, os.ErrNotExist) {
			access = describe(access.Name, accessFile, schema, err)
		}
	}

	investmentSchema, err := dbschema.Inspect(ctx, s.investment)
	investment := describe("投资记账", "investment.sqlite", investmentSchema, err)
	respond(w, http.StatusOK, map[string]any{
		"expectedVersion": dbschema.CurrentVersion,
		"databases":       []databaseInfo{main, notifications, access, investment},
	})
}

func inspectInactiveDatabase(r *http.Request, path string) (dbschema.Schema, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return dbschema.Schema{}, err
	}
	if _, err := os.Stat(absolute); err != nil {
		return dbschema.Schema{}, err
	}
	uriPath := filepath.ToSlash(absolute)
	if !strings.HasPrefix(uriPath, "/") {
		uriPath = "/" + uriPath
	}
	dsn := url.URL{Scheme: "file", Path: uriPath, RawQuery: "mode=ro"}
	db, err := sql.Open("sqlite", dsn.String())
	if err != nil {
		return dbschema.Schema{}, err
	}
	defer db.Close()
	return dbschema.Inspect(r.Context(), db)
}
