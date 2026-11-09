package server

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"testing"
)

func TestNotificationModuleSharesHakoAuthentication(t *testing.T) {
	f := newFixture(t, true)
	a := loginAdmin(f)
	type forwarded struct {
		path string
		body []byte
		hdr  http.Header
	}
	requests := make(chan forwarded, 10)
	worker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		requests <- forwarded{r.URL.Path, body, r.Header.Clone()}
		respond(w, http.StatusOK, map[string]bool{"ok": true})
	}))
	t.Cleanup(worker.Close)
	target, _ := url.Parse(worker.URL)
	f.s.notifications = &notificationService{proxy: httputil.NewSingleHostReverseProxy(target)}
	t.Cleanup(func() { f.s.notifications = nil })

	unauthorized := &adminClient{f: f}
	if code, _, _ := unauthorized.request("GET", "/admin/api/notifications/webhooks", nil, "", ""); code != 401 {
		t.Fatalf("unauthenticated administration: %d", code)
	}
	if code, _, _ := a.request("POST", "/admin/api/notifications/webhooks", map[string]string{}, f.s.config.PublicURL, "bad"); code != 403 {
		t.Fatalf("missing CSRF rejection: %d", code)
	}
	a.call("GET", "notifications/webhooks", nil, 200)
	if got := <-requests; got.path != "/api/v1/webhooks" {
		t.Fatalf("admin path: %q", got.path)
	}
	if code, _, _ := a.request("GET", "/admin/api/notifications/auth/session", nil, "", ""); code != 404 {
		t.Fatalf("unexpected worker authentication route: %d", code)
	}
	if code, _, _ := a.request("GET", "/admin/notifications-ui/", nil, "", ""); code != 200 {
		t.Fatalf("module UI: %d", code)
	}
	if got := <-requests; got.path != "/" {
		t.Fatalf("UI path: %q", got.path)
	}
	if code, _ := f.call("PUT", "/api/v1/notifications/device", map[string]string{
		"token": "0123", "environment": "production",
	}, f.tokens.AccessToken); code != 200 {
		t.Fatalf("Console registration: %d", code)
	}
	got := <-requests
	var registration map[string]string
	_ = json.Unmarshal(got.body, &registration)
	if got.path != "/internal/push/registration" || registration["deviceId"] != f.deviceID {
		t.Fatalf("registration lost authenticated identity: %q", got.path)
	}
	payload := map[string]string{"body": strings.Repeat("a", 20_000)}
	if code, _, _ := unauthorized.request("POST", "/webhook/notifications/hk_"+strings.Repeat("x", 43), payload, "", ""); code != 200 {
		t.Fatalf("public webhook body limit: %d", code)
	}
	if got := <-requests; len(got.body) < 20_000 {
		t.Fatalf("webhook body was truncated to %d bytes", len(got.body))
	}
}

func TestBundledNotificationEngine(t *testing.T) {
	engine := os.Getenv("HAKO_TEST_NOTIFICATION_WORKER")
	if engine == "" {
		t.Skip("set HAKO_TEST_NOTIFICATION_WORKER to the built engine entry point")
	}
	f := newFixture(t, true)
	f.s.config.NotificationWorker = engine
	f.s.config.NotificationDataDir = t.TempDir()
	if err := f.s.startNotifications(); err != nil {
		t.Fatal(err)
	}
	a := loginAdmin(f)
	a.call("GET", "notifications/overview", nil, 200)
	status, markup, response := a.request("GET", "/admin/notifications-ui/?view=webhooks", nil, "", "")
	if status != 200 || !strings.Contains(string(markup), "/admin/notifications-ui/assets/") ||
		response.Header.Get("X-Frame-Options") != "SAMEORIGIN" {
		t.Fatalf("embedded assets unavailable: %d", status)
	}
	data := a.call("POST", "notifications/webhooks", map[string]any{
		"name": "APNs", "botId": nil, "apnsEnabled": true, "defaultChannels": []string{"apns"},
	}, 201)
	var hook struct{ Path string }
	_ = json.Unmarshal(data, &hook)
	if !strings.HasPrefix(hook.Path, "/webhook/notifications/hk_") {
		t.Fatal("worker did not create a Hako webhook")
	}
	external := &adminClient{f: f}
	code, data, _ := external.request("POST", hook.Path, map[string]any{
		"message": map[string]string{"type": "text", "text": "test"},
	}, "", "")
	if code != 202 || !strings.Contains(string(data), "APNS_DEVICE_UNAVAILABLE") {
		t.Fatalf("unexpected public webhook result: %d %s", code, data)
	}
}
