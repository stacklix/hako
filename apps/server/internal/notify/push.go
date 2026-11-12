package notify

import (
	"database/sql"
	"errors"
	"net/http"
	"strconv"
	"strings"
)

func loadAPNsConfig(db *sql.DB, key vault) (*apnsClient, error) {
	stored, err := one(db, "SELECT team_id,key_id,bundle_id,private_key FROM apns_config WHERE id=1")
	if err != nil {
		return nil, err
	}
	if stored == nil {
		return loadAPNs()
	}
	pem, err := key.open(str(stored, "private_key"))
	if err != nil {
		return nil, errors.New("cannot read stored APNs key")
	}
	return newAPNsClient(str(stored, "team_id"), str(stored, "key_id"), str(stored, "bundle_id"), "admin", []byte(pem))
}

func (s *Service) apnsProvider() *apnsClient {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.apns
}

func (s *Service) saveAPNsConfig(r *http.Request) (any, error) {
	var input struct {
		TeamID     string `json:"teamId"`
		KeyID      string `json:"keyId"`
		BundleID   string `json:"bundleId"`
		PrivateKey string `json:"privateKey"`
	}
	r.Body = http.MaxBytesReader(nil, r.Body, 8192)
	if err := decode(r, &input); err != nil {
		return nil, err
	}
	team, key, topic := strings.TrimSpace(input.TeamID), strings.TrimSpace(input.KeyID), strings.TrimSpace(input.BundleID)
	if !appleID.MatchString(team) || !appleID.MatchString(key) || len(topic) > 255 || !bundleID.MatchString(topic) {
		return nil, invalid("请输入有效的 Apple Team ID、Key ID 和 Bundle ID")
	}
	pem := strings.TrimSpace(input.PrivateKey)
	provider, err := newAPNsClient(team, key, topic, "admin", []byte(pem))
	if err != nil {
		return nil, invalid("请选择 Apple 下载的 .p8 APNs 私钥")
	}

	s.mu.Lock()
	if s.ctx.Err() != nil {
		s.mu.Unlock()
		return nil, s.ctx.Err()
	}
	err = exec(s.db, `INSERT INTO apns_config(id,team_id,key_id,bundle_id,private_key) VALUES(1,?,?,?,?)
		ON CONFLICT(id) DO UPDATE SET team_id=excluded.team_id,key_id=excluded.key_id,bundle_id=excluded.bundle_id,private_key=excluded.private_key`,
		team, key, topic, s.vault.seal(pem))
	if err != nil {
		s.mu.Unlock()
		return nil, err
	}
	previous := s.apns
	s.apns = provider
	s.mu.Unlock()
	if previous != nil {
		previous.http.CloseIdleConnections()
	}
	s.changed()
	return ok, nil
}

func (s *Service) pushDevice() (object, error) {
	item, err := one(s.db, "SELECT id,name,environment,status,updated_at updatedAt FROM push_devices WHERE status<>'revoked'")
	var config object
	if provider := s.apnsProvider(); provider != nil {
		config = object{"teamId": provider.teamID, "keyId": provider.keyID, "bundleId": provider.topic, "source": provider.source}
	}
	return object{"configured": config != nil, "config": config, "device": item}, err
}

func apnsPayload(title, text, notificationID string) (string, error) {
	payload, err := marshalPayload(object{"aps": object{"alert": object{"title": title, "body": text}, "sound": "default"},
		"type": "ilinker_notification", "notificationId": notificationID})
	if err != nil {
		return "", err
	}
	if len(payload) > 4096 {
		return "", problem(422, "APNS_PAYLOAD_TOO_LARGE", "Apple Push 消息超过 4096 字节")
	}
	return string(payload), nil
}

func (s *Service) sendDirectPush(r *http.Request) (any, error) {
	var input struct {
		Title string `json:"title"`
		Text  string `json:"text"`
	}
	r.Body = http.MaxBytesReader(nil, r.Body, 32*1024)
	if err := decode(r, &input); err != nil {
		return nil, err
	}
	title, err := validatedText(input.Title, 80)
	if err != nil {
		return nil, invalid("通知标题需为 1 至 80 个字符")
	}
	body, err := validatedText(input.Text, 4000)
	if err != nil {
		return nil, err
	}
	if s.apnsProvider() == nil {
		return nil, problem(409, "APNS_NOT_CONFIGURED", "请先配置 Apple Push")
	}
	messageID := deliveryID()
	payload, err := apnsPayload(title, body, messageID)
	if err != nil {
		return nil, err
	}

	err = transact(s.db, func(tx *sql.Tx) error {
		device, err := currentDevice(tx)
		if err != nil {
			return err
		}
		if str(device, "status") != "active" {
			return problem(409, "APNS_DEVICE_UNAVAILABLE", "请在 iPhone 上打开 Hako 并完成设备登记")
		}
		at := nowMS()
		count, err := one(tx, "SELECT COUNT(*) n FROM direct_push WHERE created_at>?", at-60_000)
		if err != nil {
			return err
		}
		if integer(count, "n") >= 30 {
			return problem(429, "APNS_RATE_LIMITED", "直接推送过于频繁，请稍后重试")
		}
		return exec(tx, `INSERT INTO direct_push(id,target_id,target_name,payload,status,created_at,updated_at)
			VALUES(?,?,?,?,'queued',?,?)`, messageID, str(device, "id"), str(device, "name"), payload, at, at)
	})
	if err != nil {
		return nil, err
	}
	s.changed()
	return object{"id": messageID, "status": "queued"}, nil
}

const pushHistory = `
	SELECT d.id,'apns' channel,'out' direction,NULL botId,d.target_name targetName,
		COALESCE(json_extract(r.apns_payload,'$.aps.alert.title'),h.name) title,
		COALESCE(json_extract(r.apns_payload,'$.aps.alert.body'),r.summary) text,
		'Webhooks · ' || h.name source,d.status,d.error,r.created_at createdAt
	FROM notification_deliveries d
	JOIN webhook_requests r ON r.id=d.notification_id
	JOIN webhooks h ON h.id=r.webhook_id WHERE d.channel='apns'
	UNION ALL
	SELECT id,'apns','out',NULL,target_name,
		json_extract(payload,'$.aps.alert.title'),json_extract(payload,'$.aps.alert.body'),
		CASE WHEN json_extract(payload,'$.type')='workshop_terminal' THEN '代码工坊' ELSE '后台直发' END,status,error,created_at FROM direct_push`

func (s *Service) pushMessages(r *http.Request) (any, error) {
	const limit = 30
	var at int64
	var id string
	if cursor := r.URL.Query().Get("before"); cursor != "" {
		stamp, key, ok := strings.Cut(cursor, ":")
		value, err := strconv.ParseInt(stamp, 10, 64)
		if !ok || err != nil || value <= 0 || len(key) != 36 {
			return nil, invalid("无效的消息分页游标")
		}
		at, id = value, key
	}
	items, err := rows(s.db, "SELECT * FROM ("+pushHistory+") WHERE (?=0 OR (createdAt,id)<(?,?)) ORDER BY createdAt DESC,id DESC LIMIT ?",
		at, at, id, limit+1)
	if err != nil {
		return nil, err
	}
	var next any
	if len(items) > limit {
		last := items[limit-1]
		next = strconv.FormatInt(integer(last, "createdAt"), 10) + ":" + str(last, "id")
		items = items[:limit]
	}
	return object{"items": items, "nextCursor": next}, nil
}
