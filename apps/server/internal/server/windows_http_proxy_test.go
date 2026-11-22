package server

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

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
	status, data := f.call("POST", "/api/v1/agents/PC/requests", agent.Request{Method: "action.network.http.proxy", Version: 1, Params: params}, f.tokens.AccessToken)
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
	t.Log("Real HTTP → Sora → Agent WebSocket → guardian/main RPC → target HTTP proxy passed with 512 KiB upload and 8 MiB binary response")
}
