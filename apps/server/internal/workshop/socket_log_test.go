package workshop

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestSocketLogPrivacyAndConcurrentClose(t *testing.T) {
	var rows []map[string]any
	d := &SocketLog{id: "connection-1", role: "agent", started: time.Now(), write: func(data []byte) {
		if strings.Contains(string(data), "secret") {
			t.Error("close description leaked")
		}
		var row map[string]any
		if err := json.Unmarshal(data, &row); err != nil {
			t.Error(err)
		}
		rows = append(rows, row)
	}}
	d.Event("read_failed", &websocket.CloseError{Code: 1006, Text: "secret authorization and message"})
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); d.Event("closed", nil) }()
	}
	wg.Wait()
	if len(rows) != 2 || rows[0]["closeCode"] != float64(1006) || rows[1]["event"] != "closed" || rows[0]["connectionId"] != rows[1]["connectionId"] {
		t.Fatalf("unexpected diagnostic rows: %#v", rows)
	}
}

func TestDiagnosticJournalReplayAfterRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "diagnostics.jsonl")
	j := NewDiagnosticJournal(path)
	j.Append([]byte(`{"event":"read_failed","closeCode":1006}`))
	first := j.Since(0)
	if len(first) != 1 {
		t.Fatal("diagnostic was not queued")
	}
	restarted := NewDiagnosticJournal(path)
	if len(restarted.Since(0)) != 1 || len(restarted.Since(first[0].Sequence)) != 0 {
		t.Fatal("replay cursor not preserved")
	}
	for i := 0; i < 1030; i++ {
		restarted.Append([]byte(`{"event":"read_failed"}`))
	}
	if len(restarted.rows) != 1024 || len(restarted.Since(0)) != 16 {
		t.Fatal("diagnostic spool limits not enforced")
	}
}
