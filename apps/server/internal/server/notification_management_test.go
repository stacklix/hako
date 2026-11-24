package server

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

func TestConsoleNotificationManagementAuthenticationAndLifecycle(t *testing.T) {
	f := newFixture(t, true)
	const base = "/api/v1/notifications/manage"
	if status, _ := f.call("GET", base+"/webhooks", nil, ""); status != http.StatusUnauthorized {
		t.Fatalf("anonymous notification management: %d", status)
	}
	if status, _ := f.call("GET", base+"/webhooks", nil, f.tokens.AccessToken+"invalid"); status != http.StatusUnauthorized {
		t.Fatalf("invalid Console token: %d", status)
	}
	web := loginAdmin(f)
	if status, _, _ := web.request("GET", base+"/webhooks", nil, "", ""); status != http.StatusUnauthorized {
		t.Fatalf("web cookie accepted as native Console authority: %d", status)
	}
	if status, _ := f.call("GET", base+"/webhooks", nil, f.tokens.AccessToken); status != http.StatusServiceUnavailable {
		t.Fatalf("disabled notification service: %d", status)
	}
	f.s.config.NotificationDataDir = t.TempDir()
	if err := f.s.startNotifications(); err != nil {
		t.Fatal(err)
	}
	call := func(method, path string, body any, expected int) []byte {
		t.Helper()
		status, data := f.call(method, base+path, body, f.tokens.AccessToken)
		if status != expected {
			t.Fatalf("%s %s: got %d, expected %d", method, path, status, expected)
		}
		return data
	}
	// Native access only exposes webhook management and WeChat binding. Server
	// provider keys and bot lifecycle remain in the existing web administration.
	call("PUT", "/push/config", map[string]string{}, http.StatusNotFound)
	call("PUT", "/channels/wechat", map[string]string{}, http.StatusNotFound)
	call("GET", "/channels/wechat", nil, http.StatusOK)
	call("GET", "/push/device", nil, http.StatusNotFound)
	call("PUT", "/webhooks", map[string]string{}, http.StatusNotFound)
	call("POST", "/webhooks", map[string]any{"name": "invalid", "apnsEnabled": false}, http.StatusBadRequest)
	data := call("POST", "/webhooks", map[string]any{"name": "原生部署通知", "apnsEnabled": true, "rateLimit": 60}, http.StatusCreated)
	var created struct {
		Webhook struct {
			ID string `json:"id"`
		}
		Path string
	}
	if err := json.Unmarshal(data, &created); err != nil || created.Webhook.ID == "" || created.Path == "" {
		t.Fatal("missing created webhook")
	}
	path := "/webhooks/" + created.Webhook.ID
	listed := call("GET", "/webhooks", nil, http.StatusOK)
	if strings.Contains(string(listed), created.Path) || !strings.Contains(string(listed), "tokenHint") {
		t.Fatal("list must only expose a token hint")
	}
	call("PATCH", path, map[string]any{"name": "更新通知", "rateLimit": 90, "enabled": false}, http.StatusOK)
	if status, _ := f.call("POST", created.Path, map[string]any{"channel": "apns", "message": map[string]string{"type": "text", "text": "停用地址"}}, ""); status != http.StatusForbidden {
		t.Fatalf("disabled webhook accepted a notification: %d", status)
	}
	call("POST", path+"/test", map[string]any{}, http.StatusNotFound)
	call("PATCH", path, map[string]any{"enabled": true}, http.StatusOK)
	call("GET", path+"/requests", nil, http.StatusNotFound)
	call("GET", path+"/notifications/example", nil, http.StatusNotFound)
	var rotated struct{ Path string }
	if err := json.Unmarshal(call("POST", path+"/rotate-token", nil, http.StatusOK), &rotated); err != nil || rotated.Path == created.Path {
		t.Fatal("rotation did not change token")
	}
	if status, _ := f.call("POST", created.Path, map[string]any{}, ""); status != http.StatusNotFound {
		t.Fatalf("old token remains valid: %d", status)
	}
	call("DELETE", path, nil, http.StatusOK)
	call("GET", path, nil, http.StatusNotFound)
	if status, _ := f.call("POST", rotated.Path, map[string]any{}, ""); status != http.StatusNotFound {
		t.Fatalf("deleted webhook token remains valid: %d", status)
	}
}
