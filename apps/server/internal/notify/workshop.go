package notify

import (
	"crypto/sha256"
	"database/sql"
	"fmt"
	"regexp"
	"strings"
)

var workshopUUID = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// Only identifiers, outcome and time cross this boundary: never prompts, output or paths.
type WorkshopTerminal struct {
	ComputerID  string `json:"-"`
	OperationID string `json:"-"`
	State       string `json:"state"`
	FinishedAt  int64  `json:"finishedAt"`
}

func (e WorkshopTerminal) Valid() bool {
	return workshopUUID.MatchString(e.OperationID) && e.FinishedAt > 0 && e.FinishedAt <= nowMS()+300_000 && in(e.State, "completed", "failed", "interrupted", "unknown")
}

func (s *Service) WorkshopReadiness(console string) (bool, bool) {
	device, err := currentDevice(s.db)
	return s.apnsProvider() != nil, err == nil && str(device, "console_id") == console && str(device, "status") == "active"
}
func (s *Service) WorkshopConsole() string {
	device, err := currentDevice(s.db)
	if err != nil {
		return ""
	}
	return str(device, "console_id")
}

func (s *Service) SuppressWorkshop(console string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return exec(s.db, `UPDATE direct_push SET status='suppressed',code='WORKSHOP_DISABLED',error='工坊通知已关闭',updated_at=?
        WHERE status='queued' AND json_extract(payload,'$.type')='workshop_terminal'
        AND target_id IN (SELECT id FROM push_devices WHERE console_id=?)`, nowMS(), console)
}

// Reuse the existing durable APNs queue. The deterministic UUID is also the APNs ID.
// First receipt wins, including skipped outcomes, so reconnects cannot create alerts later.
func (s *Service) EnqueueWorkshop(event WorkshopTerminal, console string, enabledAt int64) error {
	if !event.Valid() || event.ComputerID == "" {
		return invalid("无效的工坊任务终态")
	}
	hash := sha256.Sum256([]byte("hako-workshop-terminal/v1\n" + event.ComputerID + "\n" + strings.ToLower(event.OperationID)))
	hash[6] = (hash[6] & 0x0f) | 0x50
	hash[8] = (hash[8] & 0x3f) | 0x80
	messageID := fmt.Sprintf("%x-%x-%x-%x-%x", hash[:4], hash[4:6], hash[6:8], hash[8:10], hash[10:16])
	texts := map[string]string{"completed": "任务已完成。", "failed": "任务执行失败，请打开会话查看。", "interrupted": "任务已中断。", "unknown": "任务结果尚未确认，请打开会话核对。"}
	payload, err := marshalPayload(object{"aps": object{"alert": object{"title": "代码工坊", "body": texts[event.State]}, "sound": "default"},
		"type": "workshop_terminal", "notificationId": messageID, "computerId": event.ComputerID, "operationId": strings.ToLower(event.OperationID), "state": event.State})
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	err = transact(s.db, func(tx *sql.Tx) error {
		previous, err := one(tx, "SELECT id FROM direct_push WHERE id=?", messageID)
		if err != nil || previous != nil {
			return err
		}
		device, err := currentDevice(tx)
		if err != nil {
			return err
		}
		status, code := "queued", ""
		switch {
		case enabledAt == 0 || event.FinishedAt < enabledAt:
			status, code = "suppressed", "WORKSHOP_DISABLED"
		case event.FinishedAt < nowMS()-15*60_000:
			status, code = "suppressed", "WORKSHOP_EXPIRED"
		case str(device, "console_id") != console || str(device, "status") != "active":
			status, code = "failed", "APNS_DEVICE_UNAVAILABLE"
		case s.apns == nil:
			status, code = "failed", "APNS_NOT_CONFIGURED"
		}
		var detail any
		if code != "" {
			detail = map[string]string{"WORKSHOP_DISABLED": "工坊通知未开启，或任务在本次开启前结束", "WORKSHOP_EXPIRED": "任务结束已超过 15 分钟，跳过陈旧提醒", "APNS_DEVICE_UNAVAILABLE": "接收设备未登记、已失效或不属于当前订阅", "APNS_NOT_CONFIGURED": "服务器尚未配置 APNs"}[code]
		}
		return exec(tx, `INSERT INTO direct_push(id,target_id,target_name,payload,status,code,error,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?)`, messageID, str(device, "id"), str(device, "name"), string(payload), status, code, detail, event.FinishedAt, nowMS())
	})
	if err == nil {
		s.changed()
	}
	return err
}
