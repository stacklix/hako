package notify

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
)

func updateFor(stage string) AgentUpdate {
	return AgentUpdate{ComputerID: "PC", ComputerName: "工作电脑", UpdateID: fmtUUID(0), Stage: stage, FromVersion: "1.4.3", ToVersion: "1.4.4", OccurredAt: nowMS(), Running: true}
}

func TestAgentUpgradeNotificationsDeduplicateAndReusePushQueue(t *testing.T) {
	s, calls := workshopGateway(t)
	s.apns.http = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		data, _ := io.ReadAll(r.Body)
		if !strings.Contains(string(data), `"type":"agent_update"`) || !strings.Contains(string(data), "工作电脑") {
			t.Error("missing update identity")
		}
		var payload struct {
			APS struct {
				Alert struct{ Title string } `json:"alert"`
			} `json:"aps"`
			Stage string `json:"stage"`
		}
		if err := json.Unmarshal(data, &payload); err != nil {
			t.Error(err)
		}
		expected := map[string]string{"started": "Kage 开始升级", "completed": "Kage 升级完成", "failed": "Kage 升级失败"}
		if payload.APS.Alert.Title != expected[payload.Stage] {
			t.Errorf("upgrade title must identify the product: %q", payload.APS.Alert.Title)
		}
		return &http.Response{StatusCode: 200, ProtoMajor: 2, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(`{}`))}, nil
	})}
	var group sync.WaitGroup
	for _, stage := range []string{"started", "completed", "failed"} {
		for i := 0; i < 8; i++ {
			group.Add(1)
			go func(stage string) {
				defer group.Done()
				if _, err := s.EnqueueAgentUpdate(updateFor(stage)); err != nil {
					t.Error(err)
				}
			}(stage)
		}
	}
	group.Wait()
	row, _ := one(s.db, "SELECT COUNT(*) n FROM direct_push")
	if integer(row, "n") != 3 {
		t.Fatal("duplicate upgrade notifications", row)
	}
	if err := s.drainAPNs(); err != nil {
		t.Fatal(err)
	}
	s.workers.Wait()
	row, _ = one(s.db, "SELECT COUNT(*) n FROM direct_push WHERE status='provider_accepted'")
	if calls.Load() != 3 || integer(row, "n") != 3 {
		t.Fatal("phase notifications not delivered through APNs", row)
	}
	status, err := s.EnqueueAgentUpdate(updateFor("completed"))
	if err != nil || status != "provider_accepted" {
		t.Fatal("retry lost delivery status", status, err)
	}
}

func TestAgentUpgradeUnavailableExpiredAndUnknown(t *testing.T) {
	s, calls := workshopGateway(t)
	s.apns.http = &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) { calls.Add(1); return nil, errors.New("interrupted") })}
	event := updateFor("completed")
	_, _ = s.EnqueueAgentUpdate(event)
	_ = s.drainAPNs()
	s.workers.Wait()
	status, err := s.EnqueueAgentUpdate(event)
	_ = s.drainAPNs()
	s.workers.Wait()
	if err != nil || status != "unknown" || calls.Load() != 1 {
		t.Fatal("uncertain push resent", status, err)
	}
	event.Stage = "started"
	event.OccurredAt = nowMS() - 16*60_000
	if status, err := s.EnqueueAgentUpdate(event); err != nil || status != "suppressed" {
		t.Fatal(status, err)
	}
	s.apns = nil
	event = updateFor("failed")
	if status, err := s.EnqueueAgentUpdate(event); err != nil || status != "failed" {
		t.Fatal(status, err)
	}
	for _, stage := range []string{"running", "ready", "", "cancelled"} {
		event.Stage = stage
		if _, err := s.EnqueueAgentUpdate(event); err == nil {
			t.Fatal("invalid stage accepted", stage)
		}
	}
}
