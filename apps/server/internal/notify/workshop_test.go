package notify

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// No queue worker or real transport is started. Every APNs request is intercepted.
func workshopGateway(t *testing.T) (*Service, *atomic.Int32) {
	t.Helper()
	dir := t.TempDir()
	db, err := sql.Open("sqlite", filepath.Join(dir, "notifications.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	if err = initSchema(db); err != nil {
		t.Fatal(err)
	}
	vault, err := openVault(dir, "")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	calls := &atomic.Int32{}
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		if r.Header.Get("apns-push-type") != "alert" || !workshopUUID.MatchString(r.Header.Get("apns-id")) || r.Header.Get("apns-topic") != "me.stackli.hako" {
			t.Error("notification did not use existing APNs alert transport")
		}
		data, _ := io.ReadAll(r.Body)
		if strings.Contains(string(data), "secret-prompt") || !(strings.Contains(string(data), `"type":"workshop_terminal"`) || strings.Contains(string(data), `"type":"workshop_question"`)) {
			t.Error("invalid APNs payload")
		}
		return &http.Response{StatusCode: 200, ProtoMajor: 2, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(`{}`))}, nil
	})}
	s := &Service{db: db, vault: vault, ctx: ctx, cancel: cancel, event: make(chan struct{}), apns: &apnsClient{http: client, key: key, keyID: "KEY0000001", teamID: "TEAM000001", topic: "me.stackli.hako"}}
	s.workshopAllowed = func(console string, _ int64) bool { return console == "console" }
	t.Cleanup(func() { cancel(); s.workers.Wait(); db.Close() })
	if err := exec(db, `INSERT INTO push_devices VALUES('iphone','Hako iPhone','production','console',?,'active',?)`, vault.seal("abcd"), nowMS()); err != nil {
		t.Fatal(err)
	}
	return s, calls
}

func terminalFor(i int, state string) WorkshopTerminal {
	return WorkshopTerminal{ComputerID: "PC", OperationID: fmtUUID(i), State: state, FinishedAt: nowMS(), ProjectName: "hako", SessionName: "会话测试", Summary: "已完成本轮修复。"}
}

func TestWorkshopNotificationContentAndBounds(t *testing.T) {
	s, _ := workshopGateway(t)
	event := terminalFor(0, "completed")
	event.Summary = strings.Repeat("🛠", 240)
	if err := s.EnqueueWorkshop(event, "console", nowMS()-1000); err != nil {
		t.Fatal(err)
	}
	row, _ := one(s.db, "SELECT payload FROM direct_push")
	payload := str(row, "payload")
	var decoded struct {
		APS struct {
			Alert struct{ Title, Subtitle, Body string }
		}
	}
	if err := json.Unmarshal([]byte(payload), &decoded); err != nil {
		t.Fatal(err)
	}
	alert := decoded.APS.Alert
	if alert.Title != "代码工坊 · hako" || alert.Subtitle != "会话测试" || alert.Body != "任务已完成。\n"+event.Summary || len(payload) > 4096 {
		t.Fatal("notification lost its project, session, summary or payload bound")
	}
	// Maximum Unicode names and JSON-escaped characters must also fit APNs.
	maximum := terminalFor(1, "failed")
	maximum.ProjectName = strings.Repeat("🛠", 80)
	maximum.SessionName = strings.Repeat("🛠", 120)
	maximum.Summary = "x" + strings.Repeat("\u2028", 238) + "x"
	if err := s.EnqueueWorkshop(maximum, "console", nowMS()-1000); err != nil {
		t.Fatal(err)
	}
	row, _ = one(s.db, "SELECT MAX(length(CAST(payload AS BLOB))) n FROM direct_push")
	if integer(row, "n") > 4096 {
		t.Fatal("Unicode payload exceeded APNs limit")
	}
	for _, mutate := range []func(*WorkshopTerminal){
		func(e *WorkshopTerminal) { e.ProjectName = "" },
		func(e *WorkshopTerminal) { e.SessionName = "" },
		func(e *WorkshopTerminal) { e.ProjectName = strings.Repeat("中", 81) },
		func(e *WorkshopTerminal) { e.SessionName = strings.Repeat("中", 121) },
		func(e *WorkshopTerminal) { e.Summary = strings.Repeat("🛠", 241) },
		func(e *WorkshopTerminal) { e.Summary = "injected\ntext" },
		func(e *WorkshopTerminal) { e.Summary = "\xff" },
	} {
		bad := terminalFor(2, "completed")
		mutate(&bad)
		if s.EnqueueWorkshop(bad, "console", nowMS()-1000) == nil {
			t.Fatal("invalid notification text accepted")
		}
	}
	noReply := terminalFor(3, "interrupted")
	noReply.Summary = ""
	if err := s.EnqueueWorkshop(noReply, "console", nowMS()-1000); err != nil {
		t.Fatal(err)
	}
}
func fmtUUID(i int) string {
	return "11111111-1111-4111-8111-" + strings.Repeat("0", 11) + string("0123456789abcdef"[i])
}

func TestWorkshopTerminalDeduplicatesAndReusesAPNsQueue(t *testing.T) {
	s, calls := workshopGateway(t)
	since := nowMS() - 1000
	for i, state := range []string{"completed", "failed", "interrupted", "unknown"} {
		event := terminalFor(i, state)
		var wg sync.WaitGroup
		for range 12 {
			wg.Go(func() {
				if err := s.EnqueueWorkshop(event, "console", since); err != nil {
					t.Error(err)
				}
			})
		}
		wg.Wait()
	}
	count, _ := one(s.db, "SELECT COUNT(*) n FROM direct_push WHERE status='queued'")
	if integer(count, "n") != 4 || calls.Load() != 0 {
		t.Fatal("duplicate or premature send", count, calls.Load())
	}
	if err := s.drainAPNs(); err != nil {
		t.Fatal(err)
	}
	s.workers.Wait()
	count, _ = one(s.db, "SELECT COUNT(*) n FROM direct_push WHERE status='provider_accepted'")
	if integer(count, "n") != 4 || calls.Load() != 4 {
		t.Fatal("gateway did not deliver once per outcome", count, calls.Load())
	}
	for i, state := range []string{"completed", "failed", "interrupted", "unknown"} {
		if err := s.EnqueueWorkshop(terminalFor(i, state), "console", since); err != nil {
			t.Fatal(err)
		}
	}
	_ = s.drainAPNs()
	s.workers.Wait()
	if calls.Load() != 4 {
		t.Fatal("reconnect resent a delivered notification")
	}
	// Deduplication remains in the database after service restart, without in-memory receipts.
	var seq int
	var name, path string
	if err := s.db.QueryRow("PRAGMA database_list").Scan(&seq, &name, &path); err != nil {
		t.Fatal(err)
	}
	reopened, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	reopened.SetMaxOpenConns(1)
	if err := initSchema(reopened); err != nil {
		t.Fatal(err)
	}
	replacement := &Service{db: reopened, vault: s.vault, apns: s.apns, event: make(chan struct{})}
	if err := replacement.EnqueueWorkshop(terminalFor(0, "failed"), "console", since); err != nil {
		t.Fatal(err)
	}
	count, _ = one(reopened, "SELECT COUNT(*) n FROM direct_push")
	if integer(count, "n") != 4 {
		t.Fatal("restart lost receipts")
	}
}

func TestWorkshopOffExpiryDeviceAndUnknownDelivery(t *testing.T) {
	s, calls := workshopGateway(t)
	event := terminalFor(0, "completed")
	if err := s.EnqueueWorkshop(event, "console", 0); err != nil {
		t.Fatal(err)
	}
	// Enabling later never revives an event already suppressed while off.
	_ = s.EnqueueWorkshop(event, "console", nowMS()-1000)
	expired := terminalFor(1, "completed")
	expired.FinishedAt = nowMS() - 16*60_000
	_ = s.EnqueueWorkshop(expired, "console", expired.FinishedAt-1000)
	_ = s.EnqueueWorkshop(terminalFor(2, "failed"), "other-console", nowMS()-1000)
	_ = s.EnqueueWorkshop(terminalFor(3, "interrupted"), "console", nowMS()-1000)
	if err := s.SuppressWorkshop("console"); err != nil {
		t.Fatal(err)
	}
	_ = s.drainAPNs()
	s.workers.Wait()
	if calls.Load() != 0 {
		t.Fatal("disabled/expired/wrong-device notification sent")
	}
	count, _ := one(s.db, "SELECT COUNT(*) n FROM direct_push WHERE status='suppressed'")
	if integer(count, "n") != 3 {
		t.Fatal(count)
	}
	// A transport interruption is unknown and never automatically resent.
	s.apns.http = &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		calls.Add(1)
		return nil, errors.New("fixture interrupted")
	})}
	uncertain := terminalFor(4, "unknown")
	_ = s.EnqueueWorkshop(uncertain, "console", nowMS()-1000)
	_ = s.drainAPNs()
	s.workers.Wait()
	_ = s.EnqueueWorkshop(uncertain, "console", nowMS()-1000)
	_ = s.drainAPNs()
	s.workers.Wait()
	count, _ = one(s.db, "SELECT COUNT(*) n FROM direct_push WHERE status='unknown'")
	if integer(count, "n") != 1 || calls.Load() != 1 {
		t.Fatal("unknown delivery retried", count, calls.Load())
	}
	for _, state := range []string{"running", "finishing", "queued", "paused", "steered", "cancelled"} {
		if s.EnqueueWorkshop(terminalFor(5, state), "console", nowMS()-1000) == nil {
			t.Fatal("accepted nonterminal", state)
		}
	}
	future := terminalFor(5, "completed")
	future.FinishedAt = time.Now().Add(time.Hour).UnixMilli()
	if s.EnqueueWorkshop(future, "console", 1) == nil {
		t.Fatal("future timestamp accepted")
	}
}

func TestWorkshopMissingCredentialsAndInvalidDeviceAreRecorded(t *testing.T) {
	s, calls := workshopGateway(t)
	provider := s.apns
	s.apns = nil
	if err := s.EnqueueWorkshop(terminalFor(0, "completed"), "console", nowMS()-1000); err != nil {
		t.Fatal(err)
	}
	missing, _ := one(s.db, "SELECT status,code FROM direct_push")
	if str(missing, "status") != "failed" || str(missing, "code") != "APNS_NOT_CONFIGURED" {
		t.Fatal(missing)
	}
	s.apns = provider
	if err := exec(s.db, "UPDATE push_devices SET status='invalid',token=NULL"); err != nil {
		t.Fatal(err)
	}
	if err := s.EnqueueWorkshop(terminalFor(1, "failed"), "console", nowMS()-1000); err != nil {
		t.Fatal(err)
	}
	count, _ := one(s.db, "SELECT COUNT(*) n FROM direct_push WHERE code='APNS_DEVICE_UNAVAILABLE'")
	if integer(count, "n") != 1 {
		t.Fatal(count)
	}
	_ = s.drainAPNs()
	s.workers.Wait()
	if calls.Load() != 0 {
		t.Fatal("unready gateway sent a push")
	}
}

func TestWorkshopQueueRechecksPersistedSubscriptionBeforeSending(t *testing.T) {
	s, calls := workshopGateway(t)
	event := terminalFor(0, "completed")
	if err := s.EnqueueWorkshop(event, "console", nowMS()-1000); err != nil {
		t.Fatal(err)
	}
	// Simulate restart after preference was saved but before queued rows were suppressed.
	s.workshopAllowed = func(string, int64) bool { return false }
	if err := s.drainAPNs(); err != nil {
		t.Fatal(err)
	}
	s.workers.Wait()
	count, _ := one(s.db, "SELECT COUNT(*) n FROM direct_push WHERE status='suppressed'")
	if calls.Load() != 0 || integer(count, "n") != 1 {
		t.Fatal("disabled subscription sent after restart", count, calls.Load())
	}
}
func TestWorkshopQuestionsUseIndependentDurablePushes(t *testing.T) {
	s, calls := workshopGateway(t)
	event := terminalFor(0, "input_required")
	event.ThreadID = fmtUUID(10)
	event.QuestionID = "async-question-one"
	event.Summary = "如何升级？"
	since := nowMS() - 1000
	for i := 0; i < 3; i++ {
		if err := s.EnqueueWorkshop(event, "console", since); err != nil {
			t.Fatal(err)
		}
	}
	event.QuestionID = "async-question-two"
	if err := s.EnqueueWorkshop(event, "console", since); err != nil {
		t.Fatal(err)
	}
	if err := s.EnqueueWorkshop(terminalFor(0, "completed"), "console", since); err != nil {
		t.Fatal(err)
	}
	items, err := rows(s.db, "SELECT payload FROM direct_push")
	if err != nil || len(items) != 3 {
		t.Fatal("Questions and terminal outcomes must have independent identities", len(items), err)
	}
	questionCount := 0
	for _, row := range items {
		var payload map[string]any
		if err := json.Unmarshal([]byte(str(row, "payload")), &payload); err != nil {
			t.Fatal(err)
		}
		if payload["type"] == "workshop_question" {
			questionCount++
			if payload["threadId"] != event.ThreadID || payload["operationId"] != event.OperationID || payload["questionId"] == "" {
				t.Fatal(payload)
			}
		}
	}
	if questionCount != 2 {
		t.Fatal("Question payloads were not routed separately", questionCount)
	}
	if err := s.drainAPNs(); err != nil {
		t.Fatal(err)
	}
	s.workers.Wait()
	if calls.Load() != 3 {
		t.Fatal("Unexpected APNs request count", calls.Load())
	}
	for _, mutate := range []func(*WorkshopTerminal){
		func(e *WorkshopTerminal) { e.QuestionID = "" },
		func(e *WorkshopTerminal) { e.ThreadID = "invalid" },
	} {
		bad := event
		mutate(&bad)
		if s.EnqueueWorkshop(bad, "console", since) == nil {
			t.Fatal("Invalid question routing accepted")
		}
	}
}
