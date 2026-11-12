package server

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"hako/server/internal/workshop"
)

func TestWorkshopPushRequiresOptInAndAuthenticatedAgent(t *testing.T) {
	t.Setenv("APNS_TEAM_ID", "")
	t.Setenv("APNS_KEY_ID", "")
	t.Setenv("APNS_BUNDLE_ID", "")
	t.Setenv("APNS_KEY_FILE", "")
	f := newFixture(t, true)
	f.s.config.NotificationDataDir = t.TempDir()
	if err := f.s.startNotifications(); err != nil {
		t.Fatal(err)
	}
	if code, _ := f.call("GET", "/api/v1/notifications/workshop", nil, ""); code != 401 {
		t.Fatal("unauthenticated settings", code)
	}
	code, body := f.call("GET", "/api/v1/notifications/workshop", nil, f.tokens.AccessToken)
	if code != 200 || !strings.Contains(string(body), `"enabled":false`) || !strings.Contains(string(body), `"configured":false`) {
		t.Fatal(code, string(body))
	}
	for _, body := range []map[string]any{{}, {"enabled": "true"}, {"enabled": true, "consoleId": "forged"}} {
		if code, _ := f.call("PUT", "/api/v1/notifications/workshop", body, f.tokens.AccessToken); code != 400 {
			t.Fatal("bad settings accepted", code)
		}
	}
	if code, _ := f.call("PUT", "/api/v1/notifications/workshop", map[string]any{"enabled": true}, f.tokens.AccessToken); code != 200 {
		t.Fatal(code)
	}
	var since int64
	f.s.store.inspect(func(st state) {
		for _, v := range st.WorkshopPush {
			since = v
		}
	})
	if since == 0 {
		t.Fatal("opt in not persisted")
	}
	_, _ = f.call("PUT", "/api/v1/notifications/workshop", map[string]any{"enabled": true}, f.tokens.AccessToken)
	f.s.store.inspect(func(st state) {
		for _, v := range st.WorkshopPush {
			if since != v {
				t.Error("enable moved replay boundary")
			}
		}
	})
	worker := connectWorkshop(t, f)
	operation := "11111111-1111-4111-8111-111111111111"
	for range 2 {
		payload, _ := json.Marshal(map[string]any{"state": "completed", "finishedAt": time.Now().UnixMilli(), "projectName": "hako", "sessionName": "通知测试", "summary": "本轮任务已完成"})
		writeAgentFrame(t, worker, workshop.Frame{Kind: "terminal", OperationID: operation, Result: payload})
		if ack := readAgentFrame[workshop.Frame](t, worker); ack.Kind != "terminal_ack" || ack.OperationID != operation {
			t.Fatal("receipt not acknowledged", ack)
		}
	}
	for range 2 {
		questionPayload, _ := json.Marshal(map[string]any{"state": "input_required", "finishedAt": time.Now().UnixMilli(),
			"projectName": "hako", "sessionName": "通知测试", "summary": "请选择升级方式", "threadId": operation, "questionId": "async-question"})
		writeAgentFrame(t, worker, workshop.Frame{Kind: "terminal", OperationID: operation, QuestionID: "async-question", Result: questionPayload})
		if ack := readAgentFrame[workshop.Frame](t, worker); ack.Kind != "terminal_ack" || ack.OperationID != operation || ack.QuestionID != "async-question" {
			t.Fatal("Question acknowledgement lost its identity", ack)
		}
	}
	// iOS cannot inject terminal frames through its authenticated client channel.
	client := openWorkshopClient(t, f, "/ws/workshop/client")
	writeAgentFrame(t, client, workshop.Frame{Kind: "terminal", ID: "inject", OperationID: operation, Result: json.RawMessage(`{"state":"completed"}`)})
	if reply := readAgentFrame[workshop.Frame](t, client); reply.Kind != "failure" {
		t.Fatal("client forged completion", reply)
	}
	// An Agent may not supply a device, another computer or arbitrary payload fields.
	writeAgentFrame(t, worker, workshop.Frame{Kind: "terminal", OperationID: operation, Result: json.RawMessage(`{"state":"completed","finishedAt":1,"computerId":"other"}`)})
	_ = worker.SetReadDeadline(time.Now().Add(time.Second))
	if err := worker.ReadJSON(new(any)); err == nil {
		t.Fatal("forged event accepted")
	}
	if code, body := f.call("PUT", "/api/v1/notifications/workshop", map[string]any{"enabled": false}, f.tokens.AccessToken); code != 200 || !strings.Contains(string(body), `"enabled":false`) {
		t.Fatal(code, string(body))
	}
}
