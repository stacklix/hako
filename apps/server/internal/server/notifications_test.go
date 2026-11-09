package server

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNativeNotificationGatewayUsesHakoAuthentication(t *testing.T) {
	f := newFixture(t, true)
	f.s.config.NotificationDataDir = t.TempDir()
	f.s.config.NotificationWebDir = t.TempDir()
	if err := os.WriteFile(filepath.Join(f.s.config.NotificationWebDir, "index.html"), []byte("<title>通知网关</title>"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := f.s.startNotifications(); err != nil {
		t.Fatal(err)
	}
	a := loginAdmin(f)
	external := &adminClient{f: f}
	if code, _, _ := external.request("GET", "/admin/api/notifications/webhooks", nil, "", ""); code != 401 {
		t.Fatalf("unauthenticated administration: %d", code)
	}
	if code, _, _ := a.request("POST", "/admin/api/notifications/webhooks", map[string]string{}, f.s.config.PublicURL, "bad"); code != 403 {
		t.Fatalf("invalid CSRF: %d", code)
	}
	if code, body, response := a.request("GET", "/admin/notifications-ui/?view=webhooks", nil, "", ""); code != 200 || !strings.Contains(string(body), "通知网关") || response.Header.Get("X-Frame-Options") != "SAMEORIGIN" {
		t.Fatalf("embedded page: %d", code)
	}
	if code, body, _ := a.request("GET", "/admin/notifications/channels", nil, "", ""); code != 200 || !strings.Contains(string(body), "通知渠道") {
		t.Fatalf("channel page: %d", code)
	}
	if code, _, _ := a.request("PUT", "/admin/api/notifications/channels/wechat", map[string]any{}, f.s.config.PublicURL, "bad"); code != 403 {
		t.Fatalf("invalid channel initialization CSRF: %d", code)
	}
	initial := a.call("GET", "notifications/channels/wechat", nil, 200)
	if !strings.Contains(string(initial), `"connection":null`) {
		t.Fatalf("new gateway has a configured channel: %s", initial)
	}
	first := a.call("PUT", "notifications/channels/wechat", map[string]any{}, 200)
	second := a.call("PUT", "notifications/channels/wechat", map[string]any{}, 200)
	if string(first) != string(second) || string(first) == string(initial) {
		t.Fatalf("channel initialization must return the same connection: %s %s", first, second)
	}
	if code, _, _ := external.request("PUT", "/api/v1/notifications/device", nil, "", ""); code != 401 {
		t.Fatalf("unauthenticated registration: %d", code)
	}
	if code, _ := f.call("PUT", "/api/v1/notifications/device", map[string]string{"token": "1234", "environment": "production"}, f.tokens.AccessToken); code != http.StatusNoContent {
		t.Fatalf("Console registration with APNs disabled: %d", code)
	}
	a.call("GET", "notifications/overview", nil, 200)
	data := a.call("POST", "notifications/webhooks", map[string]any{"name": "部署通知", "botId": nil, "apnsEnabled": true, "defaultChannels": []string{"apns"}}, 201)
	var hook struct{ Path string }
	_ = json.Unmarshal(data, &hook)
	if !strings.HasPrefix(hook.Path, "/webhook/notifications/hk_") {
		t.Fatal("incorrect webhook path")
	}
	payload := map[string]any{"message": map[string]string{"type": "text", "text": "部署成功"}}
	code, data, _ := external.request("POST", hook.Path, payload, "", "")
	if code != 202 || !strings.Contains(string(data), "APNS_DEVICE_UNAVAILABLE") {
		t.Fatalf("public webhook: %d %s", code, data)
	}
	var result struct{ NotificationID string }
	_ = json.Unmarshal(data, &result)
	if code, _, _ := external.request("GET", hook.Path+"/"+result.NotificationID, nil, "", ""); code != 200 {
		t.Fatalf("status: %d", code)
	}
}
