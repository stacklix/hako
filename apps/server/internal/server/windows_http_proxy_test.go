package server

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"hako/server/internal/agent"
)

func checkWindowsHTTPProxy(t *testing.T, f *fixture) {
	t.Helper()
	upload := bytes.Repeat([]byte{251, 239, 190}, 512*1024/3)
	download := bytes.Repeat([]byte{251, 239, 190}, 8*1024*1024/3)
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, err := io.ReadAll(r.Body)
		if err != nil || !bytes.Equal(data, upload) || r.URL.EscapedPath() != "/a%2Fb" || r.URL.RawQuery != "q=hello%20world" ||
			r.Method != "POST" || r.Header.Get("Authorization") != "Bearer target-fixture" || r.Header.Get("X-Proxy") != "" || r.Header.Get("X-Hop") != "" {
			t.Errorf("proxy changed request: method=%s path=%s bytes=%d", r.Method, r.URL.EscapedPath(), len(data))
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.WriteHeader(http.StatusTeapot)
		_, _ = w.Write(download)
	}))
	defer target.Close()
	params, _ := json.Marshal(map[string]any{
		"url": "http://original.invalid/a%2Fb?q=hello%20world", "target": strings.TrimPrefix(target.URL, "http://"),
		"method": "POST", "headers": map[string]string{"Authorization": "Bearer target-fixture", "X-Proxy": "hidden", "Connection": "X-Hop", "X-Hop": "private"},
		"body": base64.URLEncoding.EncodeToString(upload), "timeoutMs": 8000,
	})
	// The proxy service connects independently from the monitoring socket.
	if peer, _ := f.s.proxyHub.Lookup("PC"); peer != nil {
		t.Fatal("proxy connected before a module-open request")
	}
	opened := f.s.callAgentModule(context.Background(), "PC", agent.Request{Payload: json.RawMessage(`{"module":"proxy","version":1}`)})
	if opened.Status != 200 {
		t.Fatal("module-open transport failed", opened.Status)
	}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if peer, _ := f.s.proxyHub.Lookup("PC"); peer != nil {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	client := openConsoleAgentSocket(t, f, "/ws/proxy/client/PC")
	writeAgentFrame(t, client, map[string]any{"type": "request", "id": "proxy-roundtrip", "body": map[string]any{"version": 1, "request": json.RawMessage(params)}})
	_ = client.SetReadDeadline(time.Now().Add(30 * time.Second))
	var frame struct {
		Status int
		Body   json.RawMessage
	}
	if err := client.ReadJSON(&frame); err != nil {
		t.Fatal(err)
	}
	status, data := frame.Status, []byte(frame.Body)
	var reply struct {
		Result struct {
			Status  int
			Headers map[string]string
			Body    string
		}
		Error *agent.Error
	}
	if status != 200 || json.Unmarshal(data, &reply) != nil || reply.Error != nil || reply.Result.Status != http.StatusTeapot {
		t.Fatalf("Windows proxy relay failed: status=%d bytes=%d error=%+v", status, len(data), reply.Error)
	}
	decoded, err := base64.URLEncoding.DecodeString(reply.Result.Body)
	if err != nil || !bytes.Equal(decoded, download) {
		t.Fatalf("Windows proxy response corrupted: %d", len(decoded))
	}
	t.Log("Independent client WebSocket → Sora → proxy WebSocket → target HTTP service passed with 512 KiB upload and 8 MiB binary response")
}
