package server

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"hako/server/internal/dbschema"
)

type databaseInfo struct {
	ID              string           `json:"id"`
	Name            string           `json:"name"`
	File            string           `json:"file"`
	Status          string           `json:"status"`
	Schema          *dbschema.Schema `json:"schema,omitempty"`
	ExpectedVersion int              `json:"expectedVersion"`
}

func (s *Server) adminDatabaseSchemas(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	describe := func(name, file string, schema dbschema.Schema, err error) databaseInfo {
		info := databaseInfo{Name: name, File: filepath.Base(file), Status: "unreadable", ExpectedVersion: dbschema.CurrentVersion}
		if err == nil {
			info.Status = "available"
			info.Schema = &schema
		}
		return info
	}

	mainSchema, err := dbschema.Inspect(ctx, s.store.db)
	main := describe("服务端主库", s.config.Database, mainSchema, err)

	notifications := databaseInfo{Name: "通知网关", File: "notifications.sqlite", Status: "disabled", ExpectedVersion: dbschema.CurrentVersion}
	if s.notifications != nil {
		schema, err := s.notifications.DatabaseSchema(ctx)
		notifications = describe(notifications.Name, notifications.File, schema, err)
	}

	accessFile := s.config.Database + ".access.db"
	access := databaseInfo{Name: "访问日志", File: filepath.Base(accessFile), Status: "not_created", ExpectedVersion: dbschema.CurrentVersion}
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
	investment.ExpectedVersion = investmentSchemaVersion
	main.ID, notifications.ID, access.ID, investment.ID = "main", "notifications", "access", "investment"
	respond(w, http.StatusOK, map[string]any{
		"databases": []databaseInfo{main, notifications, access, investment},
	})
}

func inspectInactiveDatabase(r *http.Request, path string) (dbschema.Schema, error) {
	db, err := openInactiveDatabase(path)
	if err != nil {
		return dbschema.Schema{}, err
	}
	defer db.Close()
	return dbschema.Inspect(r.Context(), db)
}

func openInactiveDatabase(path string) (*sql.DB, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	if _, err := os.Stat(absolute); err != nil {
		return nil, err
	}
	uriPath := filepath.ToSlash(absolute)
	if !strings.HasPrefix(uriPath, "/") {
		uriPath = "/" + uriPath
	}
	dsn := url.URL{Scheme: "file", Path: uriPath, RawQuery: "mode=ro"}
	db, err := sql.Open("sqlite", dsn.String())
	if err != nil {
		return nil, err
	}
	return db, nil
}

func (s *Server) adminDatabaseQuery(w http.ResponseWriter, r *http.Request) {
	var input struct {
		SQL    string `json:"sql"`
		Limit  int    `json:"limit"`
		Offset int    `json:"offset"`
	}
	if !decode(w, r, &input) {
		return
	}
	if input.Limit == 0 {
		input.Limit = 100
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	var result dbschema.QueryResult
	var err error
	switch r.PathValue("database") {
	case "main":
		result, err = dbschema.Query(ctx, s.store.db, input.SQL, input.Limit, input.Offset)
	case "investment":
		result, err = dbschema.Query(ctx, s.investment, input.SQL, input.Limit, input.Offset)
	case "notifications":
		if s.notifications == nil {
			reject(w, 409, "database_unavailable")
			return
		}
		result, err = s.notifications.DatabaseQuery(ctx, input.SQL, input.Limit, input.Offset)
	case "access":
		if s.accessLogs != nil {
			result, err = s.accessLogs.DatabaseQuery(ctx, input.SQL, input.Limit, input.Offset)
		} else {
			if s.config.Database == ":memory:" {
				reject(w, 409, "database_unavailable")
				return
			}
			db, openErr := openInactiveDatabase(s.config.Database + ".access.db")
			if openErr != nil {
				reject(w, 409, "database_unavailable")
				return
			}
			defer db.Close()
			result, err = dbschema.Query(ctx, db, input.SQL, input.Limit, input.Offset)
		}
	default:
		reject(w, 404, "database_not_found")
		return
	}
	if err != nil {
		message := err.Error()
		if ctx.Err() != nil {
			message = "查询超过 5 秒或已取消，请缩小查询范围。"
		}
		respond(w, 400, map[string]string{"error": "database_query_failed", "message": message})
		return
	}
	respond(w, 200, result)
}
