package workshop

import (
	"bufio"
	"encoding/json"
	"log"
	"os"
	"sync"
	"time"
)

type DiagnosticRecord struct {
	Sequence int64           `json:"sequence"`
	Payload  json.RawMessage `json:"payload"`
}

// Bounded durable spool. Cursors are acknowledged by the Agent on reconnect.
// Device business calls still pass through unchanged; this is transport telemetry.
type DiagnosticJournal struct {
	mu   sync.Mutex
	path string
	last int64
	rows []DiagnosticRecord
}

func NewDiagnosticJournal(path string) *DiagnosticJournal {
	j := &DiagnosticJournal{path: path}
	if path == "" {
		return j
	}
	for _, name := range []string{path + ".previous", path} {
		f, err := os.Open(name)
		if err != nil {
			continue
		}
		s := bufio.NewScanner(f)
		s.Buffer(make([]byte, 4096), 8192)
		for s.Scan() {
			var row DiagnosticRecord
			if json.Unmarshal(s.Bytes(), &row) == nil && row.Sequence > j.last {
				j.last = row.Sequence
				j.rows = append(j.rows, row)
				if len(j.rows) > 1024 {
					j.rows = j.rows[1:]
				}
			}
		}
		_ = f.Close()
	}
	return j
}

func (j *DiagnosticJournal) Append(payload []byte) {
	if j == nil || len(payload) > 4096 || !json.Valid(payload) {
		return
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	next := time.Now().UnixMicro()
	if next <= j.last {
		next = j.last + 1
	}
	j.last = next
	row := DiagnosticRecord{next, append(json.RawMessage(nil), payload...)}
	j.rows = append(j.rows, row)
	if len(j.rows) > 1024 {
		j.rows = j.rows[1:]
	}
	if j.path == "" {
		return
	}
	if info, err := os.Stat(j.path); err == nil && info.Size() >= 1_048_576 {
		if err := os.Rename(j.path, j.path+".previous"); err != nil {
			log.Printf("workshop_diagnostic_spool rotation_failed errorClass=%T", err)
			return
		}
	}
	f, err := os.OpenFile(j.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		log.Printf("workshop_diagnostic_spool open_failed errorClass=%T", err)
		return
	}
	data, _ := json.Marshal(row)
	if _, err := f.Write(append(data, '\n')); err != nil {
		log.Printf("workshop_diagnostic_spool write_failed errorClass=%T", err)
	}
	_ = f.Close()
}

func (j *DiagnosticJournal) Since(cursor int64) []DiagnosticRecord {
	j.mu.Lock()
	defer j.mu.Unlock()
	var result []DiagnosticRecord
	for _, row := range j.rows {
		if row.Sequence > cursor {
			result = append(result, row)
			if len(result) >= 16 {
				break
			}
		}
	}
	return result
}
