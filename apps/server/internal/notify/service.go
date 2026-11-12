package notify

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode/utf16"

	"hako/server/internal/dbschema"

	_ "modernc.org/sqlite"
)

const (
	windowCode     = "WECHAT_SEND_WINDOW_EXPIRED"
	windowMessage  = "微信发送限制：24 小时内未收到用户消息，无法主动发送。请接收人在微信中给机器人发送一条消息后重试。"
	windowMS       = int64(24 * time.Hour / time.Millisecond)
	reminderSource = "系统 · 微信窗口提醒"
)

type object map[string]any

type sqlRunner interface {
	Query(string, ...any) (*sql.Rows, error)
	Exec(string, ...any) (sql.Result, error)
}

func rows(db sqlRunner, query string, args ...any) ([]object, error) {
	result := []object{}
	rs, err := db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rs.Close()
	columns, err := rs.Columns()
	if err != nil {
		return nil, err
	}
	for rs.Next() {
		values := make([]any, len(columns))
		dest := make([]any, len(columns))
		for i := range values {
			dest[i] = &values[i]
		}
		if err := rs.Scan(dest...); err != nil {
			return nil, err
		}
		item := object{}
		for i, column := range columns {
			item[column] = values[i]
		}
		result = append(result, item)
	}
	return result, rs.Err()
}
func one(db sqlRunner, query string, args ...any) (object, error) {
	items, err := rows(db, query, args...)
	if err != nil || len(items) == 0 {
		return nil, err
	}
	return items[0], nil
}
func exec(db sqlRunner, query string, args ...any) error {
	_, err := db.Exec(query, args...)
	return err
}
func transact(db *sql.DB, fn func(*sql.Tx) error) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit()
}
func str(r object, field string) string    { v, _ := r[field].(string); return v }
func integer(r object, field string) int64 { v, _ := r[field].(int64); return v }
func enabled(r object, field string) bool  { return integer(r, field) != 0 }
func nowMS() int64                         { return time.Now().UnixMilli() }
func random(size int) []byte               { b := make([]byte, size); _, _ = rand.Read(b); return b }
func id(prefix string) string              { return prefix + "_" + hex.EncodeToString(random(16)) }
func token() string                        { return "hk_" + base64.RawURLEncoding.EncodeToString(random(32)) }
func sha(data []byte) string               { h := sha256.Sum256(data); return hex.EncodeToString(h[:]) }
func shorten(s string, max int) string {
	r := []rune(s)
	if len(r) > max {
		return string(r[:max])
	}
	return s
}
func in(value string, options ...string) bool {
	for _, option := range options {
		if value == option {
			return true
		}
	}
	return false
}

type apiError struct {
	status        int
	code, message string
}

func (e *apiError) Error() string                    { return e.message }
func problem(status int, code, message string) error { return &apiError{status, code, message} }
func invalid(message string) error                   { return problem(400, "VALIDATION_ERROR", message) }
func notFound(code, message string) error            { return problem(404, code, message) }
func writeJSON(w http.ResponseWriter, status int, data any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(data)
}
func writeError(w http.ResponseWriter, err error) {
	var known *apiError
	if errors.As(err, &known) {
		if known.status == 429 {
			w.Header().Set("Retry-After", "60")
		}
		writeJSON(w, known.status, object{"code": known.code, "message": known.message})
		return
	}
	var platform *providerError
	if errors.As(err, &platform) {
		writeJSON(w, 502, object{"code": "PLATFORM_ERROR", "message": platform.message})
		return
	}
	// SQL and transport errors may contain request paths or provider details.
	slog.Error("notification request failed", "errorType", fmt.Sprintf("%T", err))
	writeJSON(w, 500, object{"code": "INTERNAL_ERROR", "message": "通知服务处理失败，请稍后重试"})
}
func decode(r *http.Request, dest any) error {
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if err := d.Decode(dest); err != nil {
		var large *http.MaxBytesError
		if errors.As(err, &large) {
			return problem(413, "INVALID_REQUEST", "请求内容过大")
		}
		return invalid("请求内容不正确")
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return invalid("请求内容不正确")
	}
	return nil
}

type action func(*http.Request) (any, error)

func route(mux *http.ServeMux, pattern string, status int, fn action) {
	mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
		data, err := fn(r)
		if err != nil {
			writeError(w, err)
			return
		}
		writeJSON(w, status, data)
	})
}
func validatedText(value string, max int) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" || len(utf16.Encode([]rune(value))) > max {
		return "", invalid("文本为空或超过长度上限")
	}
	return value, nil
}

type vault struct{ aead cipher.AEAD }

func openVault(dir, configured string) (vault, error) {
	var key []byte
	var err error
	if configured != "" {
		key, err = base64.StdEncoding.DecodeString(configured)
		if err != nil {
			key, err = base64.RawStdEncoding.DecodeString(configured)
		}
	} else {
		path := filepath.Join(dir, "encryption.key")
		key, err = os.ReadFile(path)
		if os.IsNotExist(err) {
			key = random(32)
			var file *os.File
			file, err = os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
			if err == nil {
				_, err = file.Write(key)
				err = errors.Join(err, file.Close())
			}
		}
	}
	if err != nil || len(key) != 32 {
		return vault{}, errors.New("invalid notification encryption key")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return vault{}, err
	}
	aead, err := cipher.NewGCM(block)
	return vault{aead}, err
}
func (v vault) seal(text string) string {
	nonce := random(v.aead.NonceSize())
	data := v.aead.Seal(nil, nonce, []byte(text), nil)
	i := len(data) - v.aead.Overhead()
	// The existing notification database stores nonce, tag, ciphertext.
	out := append(append(nonce, data[i:]...), data[:i]...)
	return base64.StdEncoding.EncodeToString(out)
}
func (v vault) open(text string) (string, error) {
	data, err := base64.StdEncoding.DecodeString(text)
	n, t := v.aead.NonceSize(), v.aead.Overhead()
	if err != nil || len(data) < n+t {
		return "", errors.New("invalid sealed notification value")
	}
	sealed := append(append([]byte{}, data[n+t:]...), data[n:n+t]...)
	plain, err := v.aead.Open(nil, data[:n], sealed, nil)
	return string(plain), err
}

type Config struct {
	DataDir, EncryptionKey string
	TrustedConsoles        []string
	WorkshopAllowed        func(console string, finishedAt int64) bool
}

type operation struct{ cancel context.CancelFunc }

type Service struct {
	db              *sql.DB
	vault           vault
	wechat          wechatClient
	apns            *apnsClient
	consoles        []string
	admin           *http.ServeMux
	ctx             context.Context
	cancel          context.CancelFunc
	workers         sync.WaitGroup
	mu              sync.Mutex
	polls           map[string]*operation
	logins          map[string]*loginSession
	sending         map[string]*operation
	busyAPNs        int
	workshopAllowed func(string, int64) bool
	eventMu         sync.Mutex
	event           chan struct{}
}

func New(config Config) (*Service, error) {
	if err := os.MkdirAll(config.DataDir, 0700); err != nil {
		return nil, err
	}
	key, err := openVault(config.DataDir, config.EncryptionKey)
	if err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", filepath.Join(config.DataDir, "notifications.sqlite"))
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if err := initSchema(db); err != nil {
		db.Close()
		return nil, err
	}
	apns, err := loadAPNsConfig(db, key)
	if err != nil {
		db.Close()
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	s := &Service{db: db, vault: key, apns: apns, consoles: config.TrustedConsoles, ctx: ctx, cancel: cancel,
		workshopAllowed: config.WorkshopAllowed,
		polls:           make(map[string]*operation), logins: make(map[string]*loginSession), sending: make(map[string]*operation),
		event: make(chan struct{}), admin: http.NewServeMux(), wechat: newWechatClient()}
	if err := s.start(); err != nil {
		cancel()
		db.Close()
		return nil, err
	}
	s.adminRoutes()
	return s, nil
}
func (s *Service) DatabaseSchema(ctx context.Context) (dbschema.Schema, error) {
	return dbschema.Inspect(ctx, s.db)
}

func (s *Service) Close() error {
	s.mu.Lock()
	s.cancel()
	s.mu.Unlock()
	s.workers.Wait()
	s.wechat.http.CloseIdleConnections()
	if apns := s.apnsProvider(); apns != nil {
		apns.http.CloseIdleConnections()
	}
	return s.db.Close()
}
func (s *Service) changed() {
	s.eventMu.Lock()
	close(s.event)
	s.event = make(chan struct{})
	s.eventMu.Unlock()
}
func (s *Service) events(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, errors.New("stream unavailable"))
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("X-Accel-Buffering", "no")
	w.Header().Set("Cache-Control", "no-store")
	timeout := time.NewTimer(30 * time.Second)
	defer timeout.Stop()
	heartbeat := time.NewTicker(10 * time.Second)
	defer heartbeat.Stop()
	send := func(text string) bool {
		_, err := io.WriteString(w, text)
		flusher.Flush()
		return err == nil
	}
	if !send("data: {\"changed\":true}\n\n") {
		return
	}
	for {
		s.eventMu.Lock()
		event := s.event
		s.eventMu.Unlock()
		select {
		case <-s.ctx.Done():
			return
		case <-r.Context().Done():
			return
		case <-timeout.C:
			return
		case <-event:
			if !send("data: {\"changed\":true}\n\n") {
				return
			}
		case <-heartbeat.C:
			if !send(": heartbeat\n\n") {
				return
			}
		}
	}
}
func (s *Service) ServeAdmin(w http.ResponseWriter, r *http.Request) { s.admin.ServeHTTP(w, r) }
