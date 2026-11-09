package notify

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"slices"
	"sort"
	"strings"
)

const webhookPrefix = "/webhook/notifications/"

var webhookToken = regexp.MustCompile("^hk_[A-Za-z0-9_-]{43}$")
var deviceToken = regexp.MustCompile("^[0-9a-fA-F]+$")

const webhookView = `SELECT h.id,h.name,h.bot_id botId,h.enabled,h.token_hint tokenHint,h.rate_limit rateLimit,
	h.expires_at expiresAt,h.created_at createdAt,h.apns_enabled apnsEnabled,h.default_channels defaultChannels,
	b.name botName,c.id conversationId,COALESCE(NULLIF(c.remark,''),c.name) conversationName,
	(SELECT COUNT(*) FROM webhook_requests r WHERE r.webhook_id=h.id) requestCount,
	(SELECT COUNT(*) FROM webhook_requests r WHERE r.webhook_id=h.id AND (r.status='rejected' OR EXISTS(
		SELECT 1 FROM notification_deliveries d LEFT JOIN messages m ON m.id=d.message_id
		WHERE d.notification_id=r.id AND COALESCE(m.status,d.status) IN ('failed','unknown')))) failureCount,
	(SELECT MAX(created_at) FROM webhook_requests r WHERE r.webhook_id=h.id) lastUsedAt
	FROM webhooks h LEFT JOIN bots b ON b.id=h.bot_id LEFT JOIN conversations c ON c.bot_id=h.bot_id `

func renderWebhook(item object) (object, error) {
	channels, err := readChannels([]byte(str(item, "defaultChannels")))
	if err != nil {
		return nil, errors.New("invalid stored channel configuration")
	}
	item["defaultChannels"] = channels
	item["apnsEnabled"] = enabled(item, "apnsEnabled")
	item["enabled"] = enabled(item, "enabled")
	return item, nil
}
func readChannels(raw []byte) ([]string, error) {
	var values []string
	if json.Unmarshal(raw, &values) != nil || len(values) < 1 || len(values) > 2 {
		return nil, invalid("请选择至少一个通知渠道")
	}
	for i, value := range values {
		if !in(value, "wechat", "apns") || slices.Contains(values[:i], value) {
			return nil, invalid("通知渠道无效或重复")
		}
	}
	sort.Strings(values)
	return values, nil
}
func webhookByID(db sqlRunner, id string) (object, error) {
	return required(db, "WEBHOOK_NOT_FOUND", "Webhooks 不存在", "SELECT * FROM webhooks WHERE id=?", id)
}
func (s *Service) webhookView(id string) (object, error) {
	item, err := required(s.db, "WEBHOOK_NOT_FOUND", "Webhooks 不存在", webhookView+" WHERE h.id=?", id)
	if err != nil {
		return nil, err
	}
	return renderWebhook(item)
}
func (s *Service) listWebhooks(_ *http.Request) (any, error) {
	items, err := rows(s.db, webhookView+" ORDER BY h.created_at DESC")
	if err != nil {
		return nil, err
	}
	for _, item := range items {
		if _, err := renderWebhook(item); err != nil {
			return nil, err
		}
	}
	return items, nil
}

type webhookSettings struct {
	Name            *string         `json:"name"`
	BotID           json.RawMessage `json:"botId"`
	APNs            *bool           `json:"apnsEnabled"`
	DefaultChannels json.RawMessage `json:"defaultChannels"`
	Rate            *int64          `json:"rateLimit"`
	Expiry          json.RawMessage `json:"expiresAt"`
	Enabled         *bool           `json:"enabled"`
}

func settings(current object, input webhookSettings) (object, error) {
	result := object{"name": str(current, "name"), "bot": current["bot_id"], "apns": enabled(current, "apns_enabled"),
		"channels": str(current, "default_channels"), "rate": integer(current, "rate_limit"), "expires": current["expires_at"], "enabled": enabled(current, "enabled")}
	if current == nil {
		if input.Name == nil || input.BotID == nil || input.APNs == nil || input.DefaultChannels == nil || input.Enabled != nil {
			return nil, invalid("请填写 Webhook 和默认渠道")
		}
		result["rate"], result["enabled"] = int64(60), true
	}
	if input.Name != nil {
		value, err := validatedText(*input.Name, 80)
		if err != nil {
			return nil, err
		}
		result["name"] = value
	}
	if input.BotID != nil {
		var bot *string
		if json.Unmarshal(input.BotID, &bot) != nil || (bot != nil && (*bot == "" || len(*bot) > 80)) {
			return nil, invalid("机器人 ID 无效")
		}
		result["bot"] = nil
		if bot != nil {
			result["bot"] = *bot
		}
	}
	if input.APNs != nil {
		result["apns"] = *input.APNs
	}
	if input.Rate != nil {
		if *input.Rate < 1 || *input.Rate > 600 {
			return nil, invalid("每分钟上限应为 1 至 600")
		}
		result["rate"] = *input.Rate
	}
	if input.Expiry != nil {
		var expires *int64
		if json.Unmarshal(input.Expiry, &expires) != nil || (expires != nil && *expires <= 0) {
			return nil, invalid("过期时间无效")
		}
		result["expires"] = nil
		if expires != nil {
			result["expires"] = *expires
		}
	}
	if input.Enabled != nil {
		result["enabled"] = *input.Enabled
	}
	if input.DefaultChannels != nil {
		result["channels"] = string(input.DefaultChannels)
	}
	channels, err := readChannels([]byte(str(result, "channels")))
	if err != nil {
		return nil, err
	}
	if (slices.Contains(channels, "wechat") && result["bot"] == nil) || (slices.Contains(channels, "apns") && result["apns"] != true) {
		return nil, problem(400, "INVALID_DEFAULT_CHANNELS", "默认渠道必须在启用的渠道中选择")
	}
	data, _ := json.Marshal(channels)
	result["channels"] = string(data)
	return result, nil
}
func (s *Service) saveWebhook(r *http.Request, create bool) (any, error) {
	var input webhookSettings
	if err := decode(r, &input); err != nil {
		return nil, err
	}
	hookID := r.PathValue("hook")
	newToken := ""
	err := transact(s.db, func(tx *sql.Tx) error {
		var existing object
		if !create {
			var err error
			existing, err = webhookByID(tx, hookID)
			if err != nil {
				return err
			}
		}
		value, err := settings(existing, input)
		if err != nil {
			return err
		}
		if bot := str(value, "bot"); bot != "" && bot != str(existing, "bot_id") {
			if _, err := botByID(tx, bot); err != nil {
				return err
			}
		}
		if create {
			hookID, newToken = id("webhook"), token()
			return exec(tx, `INSERT INTO webhooks(id,name,bot_id,token_hash,token_hint,rate_limit,expires_at,created_at,apns_enabled,default_channels)
				VALUES(?,?,?,?,?,?,?,?,?,?)`, hookID, value["name"], value["bot"], sha([]byte(newToken)), newToken[:9], value["rate"], value["expires"], nowMS(), value["apns"], value["channels"])
		}
		return exec(tx, `UPDATE webhooks SET name=?,bot_id=?,apns_enabled=?,default_channels=?,rate_limit=?,expires_at=?,enabled=? WHERE id=?`,
			value["name"], value["bot"], value["apns"], value["channels"], value["rate"], value["expires"], value["enabled"], hookID)
	})
	if err != nil {
		return nil, err
	}
	s.changed()
	view, err := s.webhookView(hookID)
	if err != nil || !create {
		return view, err
	}
	return object{"webhook": view, "token": newToken, "path": webhookPrefix + newToken}, nil
}
func (s *Service) rotateWebhook(r *http.Request) (any, error) {
	key := token()
	result, err := s.db.Exec("UPDATE webhooks SET token_hash=?,token_hint=? WHERE id=?", sha([]byte(key)), key[:9], r.PathValue("hook"))
	if err != nil {
		return nil, err
	}
	n, err := result.RowsAffected()
	if err != nil {
		return nil, err
	}
	if n == 0 {
		return nil, notFound("WEBHOOK_NOT_FOUND", "Webhooks 不存在")
	}
	s.changed()
	return object{"token": key, "path": webhookPrefix + key}, nil
}
func (s *Service) deleteWebhook(r *http.Request) (any, error) {
	id := r.PathValue("hook")
	err := transact(s.db, func(tx *sql.Tx) error {
		if _, err := webhookByID(tx, id); err != nil {
			return err
		}
		for _, sql := range []string{"DELETE FROM idempotency WHERE webhook_id=?", "DELETE FROM webhook_requests WHERE webhook_id=?", "DELETE FROM webhooks WHERE id=?"} {
			if err := exec(tx, sql, id); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	s.changed()
	return object{"ok": true}, nil
}
func activeWebhook(hook object) error {
	if !enabled(hook, "enabled") {
		return problem(403, "WEBHOOK_DISABLED", "Webhooks 已停用")
	}
	if at := integer(hook, "expires_at"); at > 0 && at <= nowMS() {
		return problem(410, "WEBHOOK_EXPIRED", "Webhooks 已过期")
	}
	return nil
}
func authenticatedWebhook(db sqlRunner, key string) (object, error) {
	if !webhookToken.MatchString(key) {
		return nil, notFound("INVALID_WEBHOOK", "Webhooks 地址无效")
	}
	hook, err := required(db, "INVALID_WEBHOOK", "Webhooks 地址无效", "SELECT * FROM webhooks WHERE token_hash=?", sha([]byte(key)))
	if err != nil {
		return nil, err
	}
	return hook, activeWebhook(hook)
}
func notificationState(deliveries []object) string {
	queued, active, unknown, accepted := 0, 0, 0, 0
	for _, delivery := range deliveries {
		switch str(delivery, "status") {
		case "queued":
			queued++
		case "sending":
			active++
		case "unknown":
			unknown++
		case "provider_accepted":
			accepted++
		}
	}
	switch {
	case len(deliveries) == 0:
		return "failed"
	case queued == len(deliveries):
		return "queued"
	case queued+active > 0:
		return "sending"
	case unknown > 0:
		return "unknown"
	case accepted == len(deliveries):
		return "provider_accepted"
	case accepted > 0:
		return "partial_failure"
	default:
		return "failed"
	}
}
func deliveries(db sqlRunner, id string) ([]object, error) {
	return rows(db, `SELECT d.id,d.channel,d.target_id targetId,d.target_name targetName,d.message_id messageId,
		COALESCE(m.status,d.status) status,COALESCE(m.updated_at,d.updated_at) updatedAt,
		CASE WHEN m.id IS NULL THEN d.code WHEN m.error=? THEN ? END code,
		CASE WHEN m.id IS NULL THEN d.error ELSE m.error END error
		FROM notification_deliveries d LEFT JOIN messages m ON m.id=d.message_id WHERE d.notification_id=? ORDER BY d.rowid`, windowMessage, windowCode, id)
}
func result(db sqlRunner, hook, id string) (object, error) {
	_, err := required(db, "NOTIFICATION_NOT_FOUND", "通知不存在", "SELECT id FROM webhook_requests WHERE id=? AND webhook_id=? AND status<>'rejected'", id, hook)
	if err != nil {
		return nil, err
	}
	items, err := deliveries(db, id)
	if err != nil {
		return nil, err
	}
	return object{"notificationId": id, "status": notificationState(items), "deliveries": items}, nil
}
func (s *Service) requests(r *http.Request) (any, error) {
	const query = `SELECT id,webhook_id webhookId,message_id messageId,status,summary,error,ip,created_at createdAt FROM webhook_requests `
	const tail = " ORDER BY created_at DESC,rowid DESC LIMIT 100"
	var items []object
	var err error
	if id := r.PathValue("hook"); id != "" {
		if _, err := webhookByID(s.db, id); err != nil {
			return nil, err
		}
		items, err = rows(s.db, query+"WHERE webhook_id=?"+tail, id)
	} else {
		items, err = rows(s.db, query+tail)
	}
	if err != nil {
		return nil, err
	}
	for _, item := range items {
		if str(item, "status") == "rejected" {
			continue
		}
		list, err := deliveries(s.db, str(item, "id"))
		if err != nil {
			return nil, err
		}
		item["status"], item["deliveries"] = notificationState(list), list
	}
	return items, nil
}

type notificationInput struct {
	Channels json.RawMessage `json:"channels"`
	Message  messageInput    `json:"message"`
}

func (s *Service) Submit(w http.ResponseWriter, r *http.Request, ip string) {
	key := r.PathValue("token")
	hook, err := authenticatedWebhook(s.db, key)
	if err != nil {
		writeError(w, err)
		return
	}
	data, err := s.submit(r, hook, key, ip, false)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, 202, data)
}
func (s *Service) Status(w http.ResponseWriter, r *http.Request) {
	hook, err := authenticatedWebhook(s.db, r.PathValue("token"))
	if err != nil {
		writeError(w, err)
		return
	}
	data, err := result(s.db, str(hook, "id"), r.PathValue("notificationID"))
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, 200, data)
}
func (s *Service) submit(r *http.Request, hook object, key, ip string, test bool) (object, error) {
	var input notificationInput
	var message notification
	var selected []string
	parseErr := decode(r, &input)
	if parseErr == nil {
		message, parseErr = parseMessage(input.Message)
	}
	if parseErr == nil && input.Channels != nil {
		selected, parseErr = readChannels(input.Channels)
	}
	idempotency := ""
	if !test {
		idempotency = r.Header.Get("Idempotency-Key")
	}
	if parseErr == nil && len(idempotency) > 128 {
		parseErr = invalid("幂等键超过长度上限")
	}
	hookID := str(hook, "id")
	at := nowMS()
	var data object
	err := parseErr
	if err == nil {
		err = transact(s.db, func(tx *sql.Tx) error {
			// Recheck after decoding large requests, since the token can be rotated concurrently.
			var err error
			if test {
				hook, err = webhookByID(tx, hookID)
				if err == nil {
					err = activeWebhook(hook)
				}
			} else {
				hook, err = authenticatedWebhook(tx, key)
			}
			if err != nil {
				return err
			}
			id, err := s.enqueueWebhook(tx, hook, message, selected, idempotency, ip, test, at)
			if err != nil {
				return err
			}
			data, err = result(tx, hookID, id)
			return err
		})
	}
	if err != nil {
		var expected *apiError
		if errors.As(err, &expected) {
			_ = exec(s.db, `INSERT INTO webhook_requests(id,webhook_id,status,summary,error,ip,created_at)
				SELECT ?,id,'rejected',?,?,?,? FROM webhooks WHERE id=?`, id("req"), shorten(message.summary(), 120), expected.message, ip, at, hookID)
		}
		return nil, err
	}
	s.changed()
	return data, nil
}
func (s *Service) enqueueWebhook(tx *sql.Tx, hook object, message notification, selected []string, idempotency, ip string, test bool, at int64) (string, error) {
	hookID := str(hook, "id")
	fingerprint := message.fingerprint()
	if idempotency != "" {
		prior, err := one(tx, `SELECT i.fingerprint,i.notification_id,r.channels FROM idempotency i JOIN webhook_requests r ON r.id=i.notification_id
			WHERE i.webhook_id=? AND i.key=? AND i.created_at>?`, hookID, idempotency, at-windowMS)
		if err != nil {
			return "", err
		}
		if prior != nil {
			channels, err := readChannels([]byte(str(prior, "channels")))
			if err != nil {
				return "", err
			}
			if fingerprint != str(prior, "fingerprint") || (selected != nil && !slices.Equal(channels, selected)) {
				return "", problem(409, "IDEMPOTENCY_CONFLICT", "同一个幂等键不能用于不同消息或渠道")
			}
			return str(prior, "notification_id"), nil
		}
	}
	if selected == nil {
		var err error
		selected, err = readChannels([]byte(str(hook, "default_channels")))
		if err != nil {
			return "", err
		}
	}
	wechat, apns := slices.Contains(selected, "wechat"), slices.Contains(selected, "apns")
	if (wechat && str(hook, "bot_id") == "") || (apns && !enabled(hook, "apns_enabled")) {
		return "", problem(403, "CHANNEL_NOT_ALLOWED", "Webhook 未授权所选通知渠道")
	}
	notificationID := id("ntf")
	var payload any
	if apns {
		if message.kind != "text" {
			return "", problem(422, "CHANNEL_MESSAGE_UNSUPPORTED", "Apple Push 只支持文本消息")
		}
		data, err := marshalPayload(object{"aps": object{"alert": object{"title": str(hook, "name"), "body": message.text}, "sound": "default"},
			"type": "ilinker_notification", "notificationId": notificationID})
		if err != nil {
			return "", err
		}
		if len(data) > 4096 {
			return "", problem(422, "APNS_PAYLOAD_TOO_LARGE", "Apple Push 消息超过 4096 字节")
		}
		payload = string(data)
	}
	count, err := one(tx, "SELECT COUNT(*) n FROM webhook_requests WHERE webhook_id=? AND created_at>? AND status<>'rejected'", hookID, at-60_000)
	if err != nil {
		return "", err
	}
	if integer(count, "n") >= integer(hook, "rate_limit") {
		return "", problem(429, "WEBHOOK_RATE_LIMITED", "Webhooks 调用频率超过限制")
	}
	channels, _ := json.Marshal(selected)
	if err := exec(tx, `INSERT INTO webhook_requests(id,webhook_id,status,summary,ip,created_at,channels,apns_payload)
		VALUES(?,?,'queued',?,?,?,?,?)`, notificationID, hookID, shorten(message.summary(), 120), ip, at, string(channels), payload); err != nil {
		return "", err
	}
	insert := func(channel, target, name string, messageID any, failure *apiError) error {
		status := "queued"
		var code, detail any
		if failure != nil {
			status, code, detail = "failed", failure.code, failure.message
		}
		return exec(tx, `INSERT INTO notification_deliveries(id,notification_id,channel,target_id,target_name,message_id,status,code,error,updated_at)
			VALUES(?,?,?,?,?,?,?,?,?,?)`, deliveryID(), notificationID, channel, target, name, messageID, status, code, detail, at)
	}
	if wechat {
		botID := str(hook, "bot_id")
		bot, err := one(tx, "SELECT name FROM bots WHERE id=?", botID)
		if err != nil {
			return "", err
		}
		source := "Webhooks · " + str(hook, "name")
		if test {
			source += "（后台测试）"
		}
		messageID, err := s.enqueue(tx, botID, message, source, hookID)
		var failure *apiError
		if err != nil && !errors.As(err, &failure) {
			return "", err
		}
		var link any
		if messageID != "" {
			link = messageID
		}
		if err := insert("wechat", botID, str(bot, "name"), link, failure); err != nil {
			return "", err
		}
		if link != nil {
			if err := exec(tx, "UPDATE webhook_requests SET message_id=? WHERE id=?", link, notificationID); err != nil {
				return "", err
			}
		}
	}
	if apns {
		device, err := currentDevice(tx)
		if err != nil {
			return "", err
		}
		target, name := "hako", "Hako"
		if device != nil {
			target, name = str(device, "id"), str(device, "name")
		}
		var failure *apiError
		if str(device, "status") != "active" {
			failure = &apiError{409, "APNS_DEVICE_UNAVAILABLE", "Apple Push 设备未绑定或已失效"}
		}
		if err := insert("apns", target, name, nil, failure); err != nil {
			return "", err
		}
	}
	if idempotency != "" {
		if err := exec(tx, `INSERT OR REPLACE INTO idempotency(webhook_id,key,fingerprint,notification_id,created_at) VALUES(?,?,?,?,?)`,
			hookID, idempotency, fingerprint, notificationID, at); err != nil {
			return "", err
		}
	}
	return notificationID, nil
}

func (s *Service) RegisterDevice(w http.ResponseWriter, r *http.Request, consoleID string) {
	if s.apns == nil {
		w.WriteHeader(204)
		return
	}
	if !in(consoleID, s.consoles...) {
		writeError(w, problem(403, "CONSOLE_NOT_TRUSTED", "设备未在 Hako 登记"))
		return
	}
	var input struct {
		Token       string `json:"token"`
		Environment string `json:"environment"`
	}
	if err := decode(r, &input); err != nil {
		writeError(w, err)
		return
	}
	if !deviceToken.MatchString(input.Token) || len(input.Token) > 1024 || len(input.Token)%2 != 0 || !in(input.Environment, "production", "sandbox") {
		writeError(w, invalid("Apple Push 设备登记参数无效"))
		return
	}
	err := transact(s.db, func(tx *sql.Tx) error {
		current, err := currentDevice(tx)
		if err != nil {
			return err
		}
		sealed := s.vault.seal(strings.ToLower(input.Token))
		if current == nil {
			return exec(tx, `INSERT INTO push_devices(id,name,environment,console_id,token,status,updated_at)
				VALUES(?,'Hako iPhone',?,?,?,'active',?)`, id("device"), input.Environment, consoleID, sealed, nowMS())
		}
		if str(current, "console_id") != consoleID {
			return problem(409, "PUSH_DEVICE_OCCUPIED", "已有 Hako 设备接收通知")
		}
		return exec(tx, "UPDATE push_devices SET token=?,environment=?,status='active',updated_at=? WHERE id=?", sealed, input.Environment, nowMS(), str(current, "id"))
	})
	if err != nil {
		writeError(w, err)
		return
	}
	s.changed()
	w.WriteHeader(204)
}
func (s *Service) pushDevice(_ *http.Request) (any, error) {
	item, err := one(s.db, "SELECT id,name,environment,status,updated_at updatedAt FROM push_devices WHERE status<>'revoked'")
	return object{"configured": s.apns != nil, "device": item}, err
}
