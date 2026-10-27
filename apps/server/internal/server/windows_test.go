package server

import (
	"bytes"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
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
	if err = command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = command.Process.Kill(); _ = command.Wait() })
	deadline := time.Now().Add(15 * time.Second)
	for {
		f.s.mu.Lock()
		online := f.s.online["pc"] != nil
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
	if status != 200 || !bytes.Contains(data, []byte(`"methods":[{"name":"system.metrics","version":1}]`)) {
		t.Fatal("Windows capabilities missing", status, string(data))
	}
	status, data = f.call("POST", "/api/v1/agents/pc/requests", map[string]any{"method": "system.metrics", "params": map[string]any{}}, f.tokens.AccessToken)
	if status != 200 {
		t.Fatal(status, string(data))
	}
	var reply struct{ Result testMetrics }
	if json.Unmarshal(data, &reply) != nil || !reply.Result.valid() {
		t.Fatal("Windows metrics invalid")
	}
	t.Logf("Real Windows metrics received: CPU %.1f%%, memory %.1f%%", reply.Result.CPUUsagePercent, reply.Result.MemoryUsagePercent)
	status, data = f.call("POST", "/api/v1/agents/pc/requests", map[string]any{"method": "system.metrics", "params": map[string]any{"unexpected": true}}, f.tokens.AccessToken)
	if status != 200 || !bytes.Contains(data, []byte(`"code":"invalid_params"`)) {
		t.Fatal("Windows action error not forwarded", status, string(data))
	}
}

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
