package notify

import (
	"crypto/sha256"
	"database/sql"
	"fmt"
	"regexp"
	"strings"
)

var agentRelease = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)

type AgentUpdate struct {
	ComputerID   string `json:"-"`
	ComputerName string `json:"-"`
	UpdateID     string `json:"updateId"`
	Stage        string `json:"stage"`
	FromVersion  string `json:"fromVersion"`
	ToVersion    string `json:"toVersion"`
	OccurredAt   int64  `json:"occurredAt"`
	Running      bool   `json:"running"`
}

func (e AgentUpdate) Valid() bool {
	return workshopUUID.MatchString(e.UpdateID) && in(e.Stage, "started", "completed", "failed") &&
		len(e.FromVersion) <= 40 && (e.FromVersion == "" || agentRelease.MatchString(e.FromVersion)) &&
		len(e.ToVersion) <= 40 && agentRelease.MatchString(e.ToVersion) && e.OccurredAt > 0 && e.OccurredAt <= nowMS()+300_000
}

// A signed update phase is immutable. Retries, including after a guardian
// restart, reuse both the durable queue identity and the APNs notification ID.
func (s *Service) EnqueueAgentUpdate(event AgentUpdate) (string, error) {
	if !event.Valid() || event.ComputerID == "" {
		return "", invalid("无效的 Agent 升级事件")
	}
	hash := sha256.Sum256([]byte("hako-agent-update/v1\n" + event.ComputerID + "\n" + strings.ToLower(event.UpdateID) + "\n" + event.Stage))
	hash[6], hash[8] = (hash[6]&0x0f)|0x50, (hash[8]&0x3f)|0x80
	id := fmt.Sprintf("%x-%x-%x-%x-%x", hash[:4], hash[4:6], hash[6:8], hash[8:10], hash[10:16])
	title, body := "Kage 开始升级", "即将替换程序，连接可能短暂中断。"
	if event.Stage == "completed" {
		title, body = "Kage 升级完成", "新 Agent 已通过本机接口回查。"
		if !event.Running {
			body = "程序文件已更新，保留手动停止状态。"
		}
	} else if event.Stage == "failed" {
		title, body = "Kage 升级失败", "请查看电脑上的更新记录，确认恢复状态。"
	}
	versions := event.ToVersion
	if event.FromVersion != "" {
		versions = event.FromVersion + " → " + event.ToVersion
	}
	payload, err := marshalPayload(object{"aps": object{"alert": object{"title": title, "subtitle": event.ComputerName, "body": versions + "\n" + body}, "sound": "default"},
		"type": "agent_update", "notificationId": id, "computerId": event.ComputerID, "updateId": event.UpdateID, "stage": event.Stage})
	if err != nil || len(payload) > 4096 {
		return "", invalid("Agent 升级通知超过大小限制")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	status := "queued"
	err = transact(s.db, func(tx *sql.Tx) error {
		previous, err := one(tx, "SELECT status FROM direct_push WHERE id=?", id)
		if err != nil {
			return err
		}
		if previous != nil {
			status = str(previous, "status")
			return nil
		}
		device, err := currentDevice(tx)
		if err != nil {
			return err
		}
		code, detail := "", ""
		switch {
		case event.OccurredAt < nowMS()-15*60_000:
			status, code, detail = "suppressed", "AGENT_UPDATE_EXPIRED", "升级事件超过 15 分钟，跳过陈旧提醒"
		case str(device, "status") != "active":
			status, code, detail = "failed", "APNS_DEVICE_UNAVAILABLE", "接收设备未登记或已失效"
		case s.apns == nil:
			status, code, detail = "failed", "APNS_NOT_CONFIGURED", "服务器尚未配置 APNs"
		}
		return exec(tx, `INSERT INTO direct_push(id,target_id,target_name,payload,status,code,error,created_at,updated_at)
			VALUES(?,?,?,?,?,?,?,?,?)`, id, str(device, "id"), str(device, "name"), string(payload), status, code, detail, event.OccurredAt, nowMS())
	})
	if err == nil {
		s.changed()
	}
	return status, err
}
