package server

import (
	"bytes"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func newLocalHTTP(t *testing.T, s *Server) *httptest.Server {
	ts := httptest.NewServer(s)
	t.Cleanup(ts.Close)
	return ts
}

func TestWindowsAgentEndToEnd(t *testing.T) {
	program := os.Getenv("HAKO_WINDOWS_CHECKS")
	if program == "" {
		t.Skip("Set HAKO_WINDOWS_CHECKS to the built Windows checks executable")
	}
	f := newFixture(t, true)
	// The production agent accepts HTTP only on loopback. Run the same service on
	// its plain HTTP listener for this local interoperability check.
	plain := newLocalHTTP(t, f.s)
	f.s.config.PublicURL = plain.URL
	f.http = plain
	keyPath := filepath.Join(t.TempDir(), "agent.private.pem")
	der, err := x509.MarshalPKCS8PrivateKey(f.agentKey)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0600); err != nil {
		t.Fatal(err)
	}
	command := exec.Command(program, "agent", plain.URL, "owner", keyPath)
	codexHome := t.TempDir()
	if err := os.MkdirAll(filepath.Join(codexHome, "sessions"), 0700); err != nil {
		t.Fatal(err)
	}
	usageRecord, err := json.Marshal(map[string]any{"timestamp": time.Now().UTC().Format(time.RFC3339Nano), "type": "token_usage_record",
		"payload": map[string]any{"response_id": "private-response-fixture", "usage": map[string]int{"input_tokens": 30, "cached_input_tokens": 10, "output_tokens": 3, "reasoning_output_tokens": 1, "total_tokens": 33}}})
	if err != nil {
		t.Fatal(err)
	}
	userRecord, err := json.Marshal(map[string]any{"timestamp": time.Now().UTC().Format(time.RFC3339Nano), "type": "response_item", "payload": map[string]any{
		"type": "message", "role": "user", "id": "private-user-fixture", "internal_chat_message_metadata_passthrough": map[string]any{"turn_id": "test-turn", "content_item_kinds": []string{"user.text", "user.image"}}}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(codexHome, "sessions", "fixture.jsonl"), bytes.Join([][]byte{userRecord, userRecord, usageRecord, usageRecord, nil}, []byte("\n")), 0600); err != nil {
		t.Fatal(err)
	}
	command.Env = append(os.Environ(), "CODEX_HOME="+codexHome)
	if err = command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = command.Process.Kill(); _ = command.Wait() })
	deadline := time.Now().Add(15 * time.Second)
	for {
		f.s.mu.Lock()
		online := f.s.online["PC"] != nil
		f.s.mu.Unlock()
		if online {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("Windows agent did not authenticate")
		}
		time.Sleep(50 * time.Millisecond)
	}
	f.s.config.RequestTimeout = 10 * time.Second
	status, data := f.call("GET", "/api/v1/agents", nil, f.tokens.AccessToken)
	if status != 200 || !bytes.Contains(data, []byte(`"capabilities":[{"name":"query.system.metrics","version":1},{"name":"query.codex.usage","version":1},{"name":"action.network.http.check","version":1}]`)) {
		t.Fatal("Windows capabilities missing", status, string(data))
	}
	status, data = f.call("POST", "/api/v1/agents/PC/requests", map[string]any{"method": "query.system.metrics", "version": 1, "params": map[string]any{}}, f.tokens.AccessToken)
	if status != 200 {
		t.Fatal(status, string(data))
	}
	var reply struct{ Result testMetrics }
	if json.Unmarshal(data, &reply) != nil || !reply.Result.valid() {
		t.Fatal("Windows metrics invalid")
	}
	t.Logf("Real Windows metrics received: CPU %.1f%%, memory %.1f%%", reply.Result.CPUUsagePercent, reply.Result.MemoryUsagePercent)
	status, data = f.call("POST", "/api/v1/agents/PC/requests", agentRequest{Method: "query.codex.usage", Version: 1, Params: json.RawMessage(`{}`)}, f.tokens.AccessToken)
	var usage struct {
		Result struct {
			Days []struct {
				RequestCount int
				TotalTokens  int
			}
			RunningSessions  *int
			RequestCountKind string
		}
	}
	if status != 200 || json.Unmarshal(data, &usage) != nil || usage.Result.RequestCountKind != "user_messages" || len(usage.Result.Days) != 7 || usage.Result.Days[6].RequestCount != 1 || usage.Result.Days[6].TotalTokens != 33 || usage.Result.RunningSessions != nil || bytes.Contains(data, []byte("private-response-fixture")) || bytes.Contains(data, []byte("private-user-fixture")) {
		t.Fatal("Codex usage query, deduplication or metadata privacy failed", status, string(data))
	}
	status, data = f.call("POST", "/api/v1/agents/PC/requests", map[string]any{"method": "query.system.metrics", "version": 1, "params": map[string]any{"unexpected": true}}, f.tokens.AccessToken)
	if status != 200 || !bytes.Contains(data, []byte(`"code":"invalid_params"`)) {
		t.Fatal("Windows action error not forwarded", status, string(data))
	}
	var redirects atomic.Int32
	slowStarted := make(chan struct{}, 1)
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/redirect":
			w.Header().Set("Location", "/followed")
			w.WriteHeader(301)
		case "/followed":
			redirects.Add(1)
		case "/slow":
			slowStarted <- struct{}{}
			<-r.Context().Done()
		case "/body":
			w.WriteHeader(200)
			w.(http.Flusher).Flush()
			<-r.Context().Done()
		default:
			w.WriteHeader(500)
		}
	}))
	defer target.Close()
	check := func(url string) (int, []byte) {
		return f.call("POST", "/api/v1/agents/PC/requests", agentRequest{Method: "action.network.http.check", Version: 1, Params: json.RawMessage(`{"url":` + string(mustJSON(url)) + `}`)}, f.tokens.AccessToken)
	}
	for _, path := range []string{"/redirect", "/error", "/body"} {
		started := time.Now()
		status, data = check(target.URL + path)
		want := `"statusCode":500`
		if path == "/redirect" {
			want = `"statusCode":301`
		}
		if path == "/body" {
			want = `"statusCode":200`
		}
		if status != 200 || !bytes.Contains(data, []byte(`"reachable":true`)) || !bytes.Contains(data, []byte(want)) || time.Since(started) > 3*time.Second {
			t.Fatal("HTTP headers/status check failed", status, string(data))
		}
	}
	if redirects.Load() != 0 {
		t.Fatal("Agent followed redirect")
	}
	probeDone := make(chan []byte, 1)
	go func() { _, data := check(target.URL + "/slow"); probeDone <- data }()
	select {
	case <-slowStarted:
	case <-time.After(3 * time.Second):
		t.Fatal("probe did not start")
	}
	status, data = f.call("POST", "/api/v1/agents/PC/requests", agentRequest{Method: "query.all", Version: 1, Params: json.RawMessage(`{}`)}, f.tokens.AccessToken)
	var aggregate struct {
		Result struct {
			Data map[string]struct {
				Version int
				Result  testMetrics
			}
		}
		Capabilities []agentCapability
	}
	if status != 200 || json.Unmarshal(data, &aggregate) != nil || !aggregate.Result.Data["query.system.metrics"].Result.valid() || len(aggregate.Result.Data) != 2 || len(aggregate.Capabilities) != 3 {
		t.Fatal("real aggregate query failed", status, string(data))
	}
	select {
	case data := <-probeDone:
		t.Fatal("probe blocked aggregate query", string(data))
	default:
	}
	select {
	case data := <-probeDone:
		if !bytes.Contains(data, []byte(`"code":"timeout"`)) || !bytes.Contains(data, []byte(`"reachable":false`)) {
			t.Fatal("probe timeout result invalid", string(data))
		}
	case <-time.After(7 * time.Second):
		t.Fatal("probe timeout budget exceeded")
	}
	tlsTarget := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer tlsTarget.Close()
	status, data = check(tlsTarget.URL)
	if status != 200 || !bytes.Contains(data, []byte(`"code":"tls_failed"`)) {
		t.Fatal("Agent bypassed TLS verification", status, string(data))
	}
}

func mustJSON(value string) []byte { data, _ := json.Marshal(value); return data }

// Metric semantics belong to the client/agent, not the production relay.
type testMetrics struct {
	CPUUsagePercent    float64 `json:"cpuUsagePercent"`
	MemoryUsagePercent float64 `json:"memoryUsagePercent"`
	MemoryUsedBytes    uint64  `json:"memoryUsedBytes"`
	MemoryTotalBytes   uint64  `json:"memoryTotalBytes"`
	SampledAt          string  `json:"sampledAt"`
	SampleWindowMS     int     `json:"sampleWindowMs"`
}

func (m testMetrics) valid() bool {
	_, err := time.Parse(time.RFC3339Nano, m.SampledAt)
	return err == nil && m.CPUUsagePercent >= 0 && m.CPUUsagePercent <= 100 && m.MemoryUsagePercent >= 0 && m.MemoryUsagePercent <= 100 && m.MemoryTotalBytes > 0 && m.MemoryUsedBytes <= m.MemoryTotalBytes && m.SampleWindowMS >= 500 && m.SampleWindowMS <= 5000
}
