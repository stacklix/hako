package server

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"math"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	_ "time/tzdata"
)

// An empty directory disables collection. Times are grouped in the configured timezone.
type AccessLogConfig struct {
	Directory           string `json:"directory"`
	ScanIntervalSeconds int    `json:"scanIntervalSeconds"`
	Timezone            string `json:"timezone"`
}

type accessLogStatus struct {
	Enabled   bool   `json:"enabled"`
	Timezone  string `json:"timezone"`
	Interval  int    `json:"scanIntervalSeconds"`
	Retention int    `json:"retentionDays"`
	Scanning  bool   `json:"scanning"`
	LastScan  string `json:"lastScan,omitempty"`
	Error     string `json:"error,omitempty"`
	Files     int    `json:"files"`
	Imported  int64  `json:"imported"`
	Skipped   int64  `json:"skipped"`
}

type accessLogService struct {
	config   AccessLogConfig
	location *time.Location
	db       *sql.DB
	ctx      context.Context
	cancel   context.CancelFunc
	done     chan struct{}
	mu       sync.Mutex
	status   accessLogStatus
}

func newAccessLogService(database string, config AccessLogConfig) (*accessLogService, error) {
	if config.Directory == "" {
		return nil, nil
	}
	if config.ScanIntervalSeconds == 0 {
		config.ScanIntervalSeconds = 60
	}
	if config.Timezone == "" {
		config.Timezone = "UTC"
	}
	if config.ScanIntervalSeconds < 1 || config.ScanIntervalSeconds > 86400 {
		return nil, fmt.Errorf("accessLogs: scanIntervalSeconds must be 1..86400")
	}
	location, err := time.LoadLocation(config.Timezone)
	if err != nil {
		return nil, fmt.Errorf("accessLogs timezone: %w", err)
	}
	directory, err := filepath.Abs(config.Directory)
	if err != nil {
		return nil, err
	}
	config.Directory = directory
	path := database + ".access.db"
	if database == ":memory:" {
		path = ":memory:"
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	err = initAccessLogSchema(db)
	if err != nil {
		db.Close()
		return nil, err
	}
	// Changing timezone requires an explicit rebuild, otherwise existing buckets would mix definitions.
	_, err = db.Exec(`CREATE TABLE IF NOT EXISTS access_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
	INSERT INTO access_metadata(key,value) VALUES('timezone',?) ON CONFLICT(key) DO NOTHING`, config.Timezone)
	var storedTimezone string
	if err == nil {
		err = db.QueryRow("SELECT value FROM access_metadata WHERE key='timezone'").Scan(&storedTimezone)
	}
	if err != nil || storedTimezone != config.Timezone {
		db.Close()
		if err != nil {
			return nil, err
		}
		return nil, fmt.Errorf("accessLogs timezone changed; stop server and remove only %s to rebuild statistics from available logs", filepath.Base(path))
	}
	if err = pruneAccessLogs(context.Background(), db, time.Now()); err != nil {
		db.Close()
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	a := &accessLogService{config: config, location: location, db: db, ctx: ctx, cancel: cancel, done: make(chan struct{})}
	a.status = accessLogStatus{Enabled: true, Timezone: config.Timezone, Interval: config.ScanIntervalSeconds, Retention: 7}
	go func() {
		defer close(a.done)
		a.scan()
		ticker := time.NewTicker(time.Duration(config.ScanIntervalSeconds) * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				a.scan()
			}
		}
	}()
	return a, nil
}

const accessLogRetention = 7 * 24 * time.Hour

func pruneAccessLogs(ctx context.Context, db *sql.DB, now time.Time) error {
	_, err := db.ExecContext(ctx, "DELETE FROM access_counts WHERE occurred_at < ?", now.Add(-accessLogRetention).Unix())
	return err
}

const accessCountsColumns = `(
 hour INTEGER NOT NULL, occurred_at INTEGER NOT NULL, domain TEXT NOT NULL, status INTEGER NOT NULL,
 ip TEXT NOT NULL, ua TEXT NOT NULL, url TEXT NOT NULL, count INTEGER NOT NULL,
 PRIMARY KEY(hour,occurred_at,domain,status,ip,ua,url)
) WITHOUT ROWID`

func initAccessLogSchema(db *sql.DB) error {
	if _, err := db.Exec(`PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;
	CREATE TABLE IF NOT EXISTS access_counts ` + accessCountsColumns + `;
	CREATE TABLE IF NOT EXISTS access_cursors (id TEXT PRIMARY KEY,offset INTEGER NOT NULL,anchor BLOB NOT NULL,size INTEGER NOT NULL,modified INTEGER NOT NULL);`); err != nil {
		return err
	}
	rows, err := db.Query("PRAGMA table_info(access_counts)")
	if err != nil {
		return err
	}
	precise := false
	for rows.Next() {
		var cid, required, pk int
		var name, kind string
		var value any
		if err = rows.Scan(&cid, &name, &kind, &required, &value, &pk); err != nil {
			break
		}
		if name == "occurred_at" {
			precise = true
		}
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return err
	}
	if !precise {
		// Preserve old hourly totals and cursors. Only newly imported data has second-level boundaries.
		tx, err := db.Begin()
		if err != nil {
			return err
		}
		defer tx.Rollback()
		if _, err = tx.Exec(`CREATE TABLE access_counts_precise ` + accessCountsColumns + `;
		INSERT INTO access_counts_precise SELECT hour,hour,domain,status,ip,ua,url,count FROM access_counts;
		DROP TABLE access_counts; ALTER TABLE access_counts_precise RENAME TO access_counts;`); err != nil {
			return err
		}
		if err = tx.Commit(); err != nil {
			return err
		}
	}
	_, err = db.Exec(`CREATE INDEX IF NOT EXISTS access_domain_hour ON access_counts(domain,hour);
	CREATE INDEX IF NOT EXISTS access_time ON access_counts(occurred_at);
	CREATE INDEX IF NOT EXISTS access_domain_time ON access_counts(domain,occurred_at);`)
	return err
}

func (a *accessLogService) close() { a.cancel(); <-a.done; _ = a.db.Close() }
func (a *accessLogService) snapshot() accessLogStatus {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.status
}

func accessLogFilename(path string) bool {
	name := strings.TrimSuffix(strings.ToLower(filepath.Base(path)), ".gz")
	for _, ext := range []string{".log", ".json", ".jsonl"} {
		if strings.HasSuffix(name, ext) || strings.Contains(name, ext+".") {
			return true
		}
	}
	return false
}

func (a *accessLogService) scan() {
	a.mu.Lock()
	a.status.Scanning = true
	a.mu.Unlock()
	files, imported, skipped := 0, int64(0), int64(0)
	var failures []error
	cutoff := time.Now().Add(-accessLogRetention).Unix()
	err := filepath.WalkDir(a.config.Directory, func(path string, entry fs.DirEntry, walkErr error) error {
		if a.ctx.Err() != nil {
			return a.ctx.Err()
		}
		if walkErr != nil {
			failures = append(failures, walkErr)
			return nil
		}
		// Do not follow links out of the operator-selected log directory.
		if !entry.Type().IsRegular() || !accessLogFilename(path) {
			return nil
		}
		files++
		n, bad, err := a.scanFile(path, cutoff)
		imported += n
		skipped += bad
		if err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", filepath.Base(path), err))
		}
		return nil
	})
	if err != nil {
		failures = append(failures, err)
	}
	if err := pruneAccessLogs(a.ctx, a.db, time.Now()); err != nil {
		failures = append(failures, err)
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	a.status.Scanning = false
	a.status.LastScan = time.Now().UTC().Format(time.RFC3339)
	a.status.Files, a.status.Imported, a.status.Skipped = files, imported, skipped
	a.status.Error = ""
	if err := errors.Join(failures...); err != nil {
		a.status.Error = err.Error()
	}
}

const maxAccessLine = 1024 * 1024

var errAccessLineTooLong = errors.New("log line exceeds 1 MiB")

// Consume oversized lines without retaining them. An unterminated live line is retried later.
func accessLine(reader *bufio.Reader) ([]byte, int64, error) {
	var line []byte
	var length int64
	var tail []byte
	for {
		part, err := reader.ReadSlice('\n')
		length += int64(len(part))
		tail = tailAccessBytes(tail, part)
		if length <= maxAccessLine {
			line = append(line, part...)
		} else {
			line = nil
		}
		if err != bufio.ErrBufferFull {
			if length > maxAccessLine && err == nil {
				return tail, length, errAccessLineTooLong
			}
			return line, length, err
		}
	}
}

type accessTuple struct {
	Hour        int64
	Timestamp   int64
	Domain      string
	Status      int
	IP, UA, URL string
}

func accessHourStart(timestamp time.Time, location *time.Location) int64 {
	local := timestamp.In(location)
	return timestamp.Add(-time.Duration(local.Minute())*time.Minute - time.Duration(local.Second())*time.Second).Unix()
}

func parseAccessLine(line []byte, location *time.Location) (accessTuple, bool) {
	var v struct {
		TS      json.RawMessage `json:"ts"`
		Status  int             `json:"status"`
		Request struct {
			Host     string              `json:"host"`
			URI      string              `json:"uri"`
			ClientIP string              `json:"client_ip"`
			RemoteIP string              `json:"remote_ip"`
			Headers  map[string][]string `json:"headers"`
		} `json:"request"`
	}
	if json.Unmarshal(line, &v) != nil || len(v.TS) == 0 || v.Status < 100 || v.Status > 599 || v.Request.Host == "" || !strings.HasPrefix(v.Request.URI, "/") {
		return accessTuple{}, false
	}
	var timestamp time.Time
	var seconds float64
	if json.Unmarshal(v.TS, &seconds) == nil && !math.IsNaN(seconds) && !math.IsInf(seconds, 0) && seconds > 0 && seconds < 253402300800 {
		timestamp = time.Unix(int64(seconds), 0)
	} else {
		var text string
		if json.Unmarshal(v.TS, &text) != nil {
			return accessTuple{}, false
		}
		var err error
		timestamp, err = time.Parse(time.RFC3339Nano, text)
		if err != nil {
			return accessTuple{}, false
		}
	}
	// Subtract wall-clock minutes so non-integral UTC offsets and DST stay correct.
	hour := accessHourStart(timestamp, location)
	domain := strings.ToLower(strings.TrimSuffix(v.Request.Host, "."))
	if host, _, err := net.SplitHostPort(domain); err == nil {
		domain = strings.TrimSuffix(host, ".")
	}
	if domain == "" || len(domain) > 512 {
		return accessTuple{}, false
	}
	ip := v.Request.ClientIP
	if net.ParseIP(ip) == nil {
		ip = v.Request.RemoteIP
	}
	if parsed := net.ParseIP(ip); parsed != nil {
		ip = parsed.String()
	} else {
		ip = "(unknown)"
	}
	ua := "(unknown)"
	for key, values := range v.Request.Headers {
		if strings.EqualFold(key, "User-Agent") && len(values) > 0 && values[0] != "" {
			ua = values[0]
			break
		}
	}
	// Query strings do not identify pages and can contain private values.
	page, _, _ := strings.Cut(v.Request.URI, "?")
	return accessTuple{hour, timestamp.Unix(), domain, v.Status, ip, ua, page}, true
}

func tailAccessBytes(previous, line []byte) []byte {
	if len(line) >= 256 {
		return append([]byte(nil), line[len(line)-256:]...)
	}
	result := append(append([]byte(nil), previous...), line...)
	if len(result) > 256 {
		result = result[len(result)-256:]
	}
	return result
}

type accessLogReader struct {
	ctx    context.Context
	reader io.Reader
}

func (r accessLogReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.reader.Read(p)
}

func (a *accessLogService) scanFile(path string, cutoff int64) (imported, skipped int64, resultErr error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, 0, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return 0, 0, err
	}
	compressed := strings.HasSuffix(strings.ToLower(path), ".gz")
	var input io.Reader = f
	if compressed {
		gz, err := gzip.NewReader(f)
		if err != nil {
			return 0, 0, err
		}
		defer gz.Close()
		input = gz
	}
	reader := bufio.NewReader(accessLogReader{a.ctx, input})
	first, firstLength, err := accessLine(reader)
	if err == io.EOF {
		return 0, 0, nil
	}
	if err != nil {
		return 0, 0, err
	}
	if len(first) == 0 {
		return 0, 0, fmt.Errorf("first log line exceeds 1 MiB")
	}
	hash := sha256.Sum256(first)
	id := hex.EncodeToString(hash[:])
	var offset, size, modified int64
	var anchor []byte
	var savedAnchor []byte
	err = a.db.QueryRowContext(a.ctx, "SELECT offset,anchor,size,modified FROM access_cursors WHERE id=?", id).Scan(&offset, &savedAnchor, &size, &modified)
	if err != nil && err != sql.ErrNoRows {
		return 0, 0, err
	}
	// A rotation from plain text to gzip has the same identity and decompressed offset.
	if err == nil && size == info.Size() && modified == info.ModTime().UnixNano() {
		return 0, 0, nil
	}
	err = nil
	pendingFirst := true
	if offset >= firstLength {
		remaining := offset - firstLength
		anchorLength := min(offset, 256)
		if !compressed {
			if _, err = f.Seek(offset-anchorLength, io.SeekStart); err != nil {
				return 0, 0, err
			}
			reader.Reset(accessLogReader{a.ctx, f})
		} else {
			// Include bytes from the first line if the checkpoint's anchor overlaps it.
			if remaining < anchorLength {
				prefix := first[len(first)-int(anchorLength-remaining):]
				reader = bufio.NewReader(io.MultiReader(bytes.NewReader(prefix), reader))
			} else if _, err = io.CopyN(io.Discard, reader, remaining-anchorLength); err != nil {
				return 0, 0, fmt.Errorf("archive truncated before checkpoint")
			}
		}
		actual := make([]byte, anchorLength)
		_, readErr := io.ReadFull(reader, actual)
		actualHash := sha256.Sum256(actual)
		if readErr == nil && bytes.Equal(actualHash[:], savedAnchor) {
			pendingFirst = false
			anchor = actual
		} else {
			// Rewrites retaining the same first line are ambiguous: stop instead of double counting.
			return 0, 0, fmt.Errorf("log rewritten or truncated at checkpoint; use rename-based rotation")
		}
	} else {
		offset = 0
		anchor = nil
	}
	batch := map[accessTuple]int64{}
	lines := 0
	var batchImported, batchSkipped int64
	flush := func(complete bool) error {
		tx, err := a.db.BeginTx(a.ctx, nil)
		if err != nil {
			return err
		}
		defer tx.Rollback()
		stmt, err := tx.PrepareContext(a.ctx, `INSERT INTO access_counts(hour,occurred_at,domain,status,ip,ua,url,count) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(hour,occurred_at,domain,status,ip,ua,url) DO UPDATE SET count=count+excluded.count`)
		if err != nil {
			return err
		}
		defer stmt.Close()
		for key, count := range batch {
			if _, err = stmt.ExecContext(a.ctx, key.Hour, key.Timestamp, key.Domain, key.Status, key.IP, key.UA, key.URL, count); err != nil {
				return err
			}
		}
		cachedSize, cachedModified := int64(-1), int64(-1)
		if complete {
			cachedSize, cachedModified = info.Size(), info.ModTime().UnixNano()
		}
		// Store only a digest of the checkpoint bytes, never fragments of raw headers or queries.
		anchorHash := sha256.Sum256(anchor)
		_, err = tx.ExecContext(a.ctx, `INSERT INTO access_cursors(id,offset,anchor,size,modified) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET offset=excluded.offset,anchor=excluded.anchor,size=excluded.size,modified=excluded.modified`, id, offset, anchorHash[:], cachedSize, cachedModified)
		if err != nil {
			return err
		}
		if err = tx.Commit(); err != nil {
			return err
		}
		imported += batchImported
		skipped += batchSkipped
		batchImported, batchSkipped = 0, 0
		batch = map[accessTuple]int64{}
		lines = 0
		return nil
	}
	for {
		if err := a.ctx.Err(); err != nil {
			return imported, skipped, err
		}
		var line []byte
		var length int64
		if pendingFirst {
			line = first
			length = firstLength
			pendingFirst = false
		} else {
			line, length, err = accessLine(reader)
		}
		if err == io.EOF {
			break
		}
		if err != nil && !errors.Is(err, errAccessLineTooLong) {
			return imported, skipped, err
		}
		offset += length
		anchor = tailAccessBytes(anchor, line)
		if key, ok := parseAccessLine(line, a.location); ok && !errors.Is(err, errAccessLineTooLong) {
			if key.Timestamp >= cutoff && key.Timestamp <= time.Now().Add(time.Hour).Unix() {
				batch[key]++
				batchImported++
			}
		} else {
			batchSkipped++
		}
		lines++
		if lines >= 1000 {
			if err = flush(false); err != nil {
				return imported, skipped, err
			}
		}
	}
	resultErr = flush(true)
	return
}
