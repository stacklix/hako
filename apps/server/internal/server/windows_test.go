package server

import (
	"bytes"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"hako/server/internal/agent"
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
	var agentOutput bytes.Buffer
	command.Stdout = &agentOutput
	command.Stderr = &agentOutput
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
	t.Cleanup(func() {
		_ = command.Process.Kill()
		_ = command.Wait()
		if t.Failed() {
			t.Log(agentOutput.String())
		}
	})
	deadline := time.Now().Add(15 * time.Second)
	for {
		peer, _ := f.s.agentHub.Lookup("PC")
		online := peer != nil
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
	var agents struct {
		Agents []struct{ Capabilities []agent.Capability }
	}
	if status != 200 || json.Unmarshal(data, &agents) != nil || len(agents.Agents) != 1 {
		t.Fatal("Windows capabilities missing", status, string(data))
	}
	for _, name := range []string{"query.system.metrics", "query.system.processes", "query.codex.usage", "query.network.listeners",
		"admin.services.status", "admin.services.start", "action.network.http.check", "query.git.repositories"} {
		if !slices.Contains(agents.Agents[0].Capabilities, agent.Capability{Name: name, Version: 1}) {
			t.Fatalf("Windows capability %q version 1 missing: %s", name, data)
		}
	}
	status, data = f.call("POST", "/api/v1/agents/PC/requests", agent.Request{
		Method: "query.git.repository", Version: 1, Params: json.RawMessage(`{"repository":3}`),
	}, f.tokens.AccessToken)
	if status != 200 || !bytes.Contains(data, []byte(`"code":"invalid_params"`)) {
		t.Fatal("Windows Git query was not forwarded", status, string(data))
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
	status, data = f.call("POST", "/api/v1/agents/PC/requests", agent.Request{Method: "query.system.processes", Version: 1, Params: json.RawMessage(`{}`)}, f.tokens.AccessToken)
	var processes struct{ Result testProcessResources }
	if status != 200 || json.Unmarshal(data, &processes) != nil || !processes.Result.valid() {
		t.Fatal("Windows process resource query invalid", status, string(data))
	}
	live := openConsoleAgentSocket(t, f, "/ws/console/agents/live/PC")
	if subscribed := readAgentFrame[consoleAgentReply](t, live); subscribed.Type != "subscribed" {
		t.Fatalf("real Windows telemetry subscription: %+v", subscribed)
	}
	firstMetric := ""
	seen := map[string]bool{}
	telemetryDeadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(telemetryDeadline) && len(seen) < 5 {
		update := readAgentFrame[agent.TelemetryUpdate](t, live)
		if update.Type != "update" || update.Version != 1 || (update.Error != nil &&
			(update.Method != "admin.services.status" || update.Error.Code != "registry_missing")) {
			t.Fatalf("real Windows telemetry: %+v, error=%+v", update, update.Error)
		}
		switch update.Method {
		case "query.system.metrics":
			var metrics testMetrics
			if json.Unmarshal(update.Result, &metrics) != nil || !metrics.valid() {
				t.Fatal("real Windows live system metrics invalid")
			}
			if firstMetric == "" {
				firstMetric = metrics.SampledAt
			} else if firstMetric != metrics.SampledAt {
				seen[update.Method] = true
			}
		case "query.codex.usage", "query.network.listeners", "admin.services.status":
			seen[update.Method] = true
		case "query.system.processes":
			var processes testProcessResources
			if json.Unmarshal(update.Result, &processes) != nil || !processes.valid() {
				t.Fatal("real Windows live process resources invalid")
			}
			seen[update.Method] = true
		default:
			t.Logf("Additional Windows telemetry forwarded: %q", update.Method)
		}
	}
	if len(seen) != 5 {
		t.Fatalf("missing Windows telemetry: %v", seen)
	}
	live.Close()
	status, data = f.call("POST", "/api/v1/agents/PC/requests", agent.Request{Method: "query.network.listeners", Version: 1, Params: json.RawMessage(`{}`)}, f.tokens.AccessToken)
	var listeners struct {
		Result struct {
			CollectedAt string
			Ports       []struct {
				Protocol  string
				Port      int
				Processes []struct {
					ProcessID     int `json:"processId"`
					ProcessName   string
					Category      string
					StartedAt     string
					UptimeSeconds *int64
					Addresses     []string
				}
			}
		}
	}
	if status != 200 || json.Unmarshal(data, &listeners) != nil {
		t.Fatal("Windows listener query failed", status, string(data))
	}
	if _, err := time.Parse(time.RFC3339Nano, listeners.Result.CollectedAt); err != nil {
		t.Fatal("Windows listener collection timestamp invalid", err)
	}
	foundListener := false
	for _, port := range listeners.Result.Ports {
		if port.Protocol != "TCP" || port.Port != plain.Listener.Addr().(*net.TCPAddr).Port {
			continue
		}
		for _, process := range port.Processes {
			if process.ProcessID == os.Getpid() && process.ProcessName != "" && process.UptimeSeconds != nil && *process.UptimeSeconds >= 0 && len(process.Addresses) > 0 && (process.Category == "system" || process.Category == "user") {
				if _, err := time.Parse(time.RFC3339Nano, process.StartedAt); err == nil {
					foundListener = true
				}
			}
		}
	}
	if !foundListener {
		t.Fatal("Windows listener query did not preserve the local server port, process and uptime")
	}
	status, data = f.call("POST", "/api/v1/agents/PC/requests", agent.Request{Method: "query.codex.usage", Version: 1, Params: json.RawMessage(`{}`)}, f.tokens.AccessToken)
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
		return f.call("POST", "/api/v1/agents/PC/requests", agent.Request{Method: "action.network.http.check", Version: 1, Params: json.RawMessage(`{"url":` + string(mustJSON(url)) + `}`)}, f.tokens.AccessToken)
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
	status, data = f.call("POST", "/api/v1/agents/PC/requests", agent.Request{Method: "query.all", Version: 1, Params: json.RawMessage(`{}`)}, f.tokens.AccessToken)
	var aggregate struct {
		Result struct {
			Data map[string]struct {
				Version int
				Result  json.RawMessage
				Error   *agent.Error
			}
		}
		Capabilities []agent.Capability
	}
	var aggregateMetrics testMetrics
	var aggregateProcesses testProcessResources
	if status != 200 || json.Unmarshal(data, &aggregate) != nil ||
		json.Unmarshal(aggregate.Result.Data["query.system.metrics"].Result, &aggregateMetrics) != nil || !aggregateMetrics.valid() ||
		json.Unmarshal(aggregate.Result.Data["query.system.processes"].Result, &aggregateProcesses) != nil || !aggregateProcesses.valid() ||
		len(aggregate.Result.Data) != 4 || aggregate.Result.Data["query.network.listeners"].Version != 1 ||
		aggregate.Result.Data["query.system.processes"].Version != 1 || len(aggregate.Capabilities) != 0 {
		t.Fatalf("real aggregate query failed: status=%d, result count=%d, capability count=%d",
			status, len(aggregate.Result.Data), len(aggregate.Capabilities))
	}
	if _, exists := aggregate.Result.Data["admin.services.status"]; exists {
		t.Fatal("main aggregate included guardian administration")
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
	peerBefore, _ := f.s.agentHub.Lookup("PC")
	setMain := func(paused bool) {
		t.Helper()
		if paused {
			if err := os.WriteFile(keyPath+".pause-main", nil, 0600); err != nil {
				t.Fatal(err)
			}
		} else {
			if err := os.Remove(keyPath + ".pause-main"); err != nil {
				t.Fatal(err)
			}
		}
		expected := "running"
		if paused {
			expected = "stopped"
		}
		deadline := time.Now().Add(15 * time.Second)
		for {
			state, _ := os.ReadFile(keyPath + ".main-state")
			if string(state) == expected {
				return
			}
			if time.Now().After(deadline) {
				t.Fatal("main runtime did not become", expected)
			}
			time.Sleep(50 * time.Millisecond)
		}
	}
	setMain(true)
	status, data = f.call("POST", "/api/v1/agents/PC/requests", agent.Request{Method: "query.system.metrics", Version: 1, Params: json.RawMessage(`{}`)}, f.tokens.AccessToken)
	if status != 200 || !bytes.Contains(data, []byte(`"code":"process_unavailable"`)) {
		t.Fatal("main unavailability was not reported", status, string(data))
	}
	status, data = f.call("POST", "/api/v1/agents/PC/requests", agent.Request{Method: "admin.services.status", Version: 1, Params: json.RawMessage(`{}`)}, f.tokens.AccessToken)
	if status != 200 || (!bytes.Contains(data, []byte(`"services"`)) && !bytes.Contains(data, []byte(`"code":"registry_missing"`))) {
		t.Fatal("guardian admin failed with main stopped", status, string(data))
	}
	setMain(false)
	status, data = f.call("POST", "/api/v1/agents/PC/requests", agent.Request{Method: "query.system.metrics", Version: 1, Params: json.RawMessage(`{}`)}, f.tokens.AccessToken)
	if status != 200 || json.Unmarshal(data, &reply) != nil || !reply.Result.valid() {
		t.Fatal("main queries did not recover", status, string(data))
	}
	if peerAfter, _ := f.s.agentHub.Lookup("PC"); peerAfter != peerBefore {
		t.Fatal("main restart replaced the guardian's server connection")
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

type testProcessResource struct {
	ProcessID       int      `json:"processId"`
	ProcessName     string   `json:"processName"`
	CPUUsagePercent *float64 `json:"cpuUsagePercent"`
	MemoryBytes     uint64   `json:"memoryBytes"`
}

type testProcessResources struct {
	CollectedAt    string                `json:"collectedAt"`
	SampleWindowMS int                   `json:"sampleWindowMs"`
	ProcessCount   int                   `json:"processCount"`
	CPUTop         []testProcessResource `json:"cpuTop"`
	MemoryTop      []testProcessResource `json:"memoryTop"`
}

func (p testProcessResources) valid() bool {
	if _, err := time.Parse(time.RFC3339Nano, p.CollectedAt); err != nil || p.SampleWindowMS <= 0 ||
		len(p.CPUTop) == 0 || len(p.CPUTop) > min(10, p.ProcessCount) ||
		len(p.MemoryTop) == 0 || len(p.MemoryTop) > min(10, p.ProcessCount) {
		return false
	}
	for ranking, rows := range [][]testProcessResource{p.CPUTop, p.MemoryTop} {
		seen := map[int]bool{}
		for index, row := range rows {
			if row.ProcessID <= 0 || row.ProcessName == "" || seen[row.ProcessID] ||
				(row.CPUUsagePercent != nil && (*row.CPUUsagePercent < 0 || *row.CPUUsagePercent > 100)) {
				return false
			}
			seen[row.ProcessID] = true
			if ranking == 0 {
				if row.CPUUsagePercent == nil || index > 0 && *row.CPUUsagePercent > *rows[index-1].CPUUsagePercent {
					return false
				}
			} else if index > 0 && row.MemoryBytes > rows[index-1].MemoryBytes {
				return false
			}
		}
	}
	return true
}
