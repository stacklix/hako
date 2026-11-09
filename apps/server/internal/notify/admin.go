package notify

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"math"
	"net/http"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"
)

const botView = `SELECT b.id,b.name,b.platform,b.status,b.note,b.account_id accountId,b.last_error lastError,
	b.last_seen_at lastSeenAt,b.created_at createdAt,b.credentials IS NOT NULL hasCredentials,
	COALESCE(c.unread,0) unread,c.id conversationId,COALESCE(NULLIF(c.remark,''),c.name) conversationName,
	(SELECT COUNT(*) FROM webhooks WHERE bot_id=b.id) webhookCount
	FROM bots b LEFT JOIN conversations c ON c.bot_id=b.id WHERE b.deleted_at IS NULL `
const conversationView = `SELECT id,bot_id botId,peer_id peerId,name,remark,unread,last_message lastMessage,
	last_message_at lastMessageAt,context IS NOT NULL hasContext FROM conversations WHERE bot_id=?`
const messageView = `messages.id,messages.bot_id botId,messages.conversation_id conversationId,messages.direction,
	messages.type,messages.text,messages.status,messages.source,messages.webhook_id webhookId,messages.error,
	messages.created_at createdAt,messages.updated_at updatedAt,
	CASE WHEN EXISTS(SELECT 1 FROM message_images img WHERE img.message_id=messages.id AND img.data IS NOT NULL)
		THEN '/admin/api/notifications/messages/' || messages.id || '/image' ELSE NULL END imageUrl`

var verificationCode = regexp.MustCompile("^[A-Za-z0-9-]{1,32}$")
var ok = object{"ok": true}

func marshalPayload(value any) ([]byte, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buffer.Bytes(), []byte{'\n'}), nil
}

func (s *Service) adminRoutes() {
	mux := s.admin
	mux.HandleFunc("GET /events", s.events)
	route(mux, "GET /overview", 200, s.overview)
	route(mux, "GET /push/device", 200, s.pushDevice)
	route(mux, "GET /channels/wechat", 200, func(*http.Request) (any, error) { return wechatChannel(s.db) })
	route(mux, "PUT /channels/wechat", 200, s.ensureWechatChannel)
	route(mux, "GET /platforms", 200, func(*http.Request) (any, error) {
		return []object{{"id": botPlatform, "name": "微信 iLink", "loginMethod": "qrcode", "capabilities": object{
			"receive": []string{"text", "media_summary"}, "send": []string{"text", "image"}, "groups": false,
		}}}, nil
	})

	route(mux, "GET /bots", 200, s.bots)
	route(mux, "POST /bots", 201, func(r *http.Request) (any, error) { return s.saveBot(r, true) })
	route(mux, "GET /bots/{bot}", 200, func(r *http.Request) (any, error) { return renderBot(s.db, r.PathValue("bot")) })
	route(mux, "PATCH /bots/{bot}", 200, func(r *http.Request) (any, error) { return s.saveBot(r, false) })
	route(mux, "POST /bots/{bot}/login-sessions", 201, func(r *http.Request) (any, error) { return s.createLogin(r.Context(), r.PathValue("bot")) })
	route(mux, "GET /bots/{bot}/login-sessions/{login}", 200, func(r *http.Request) (any, error) {
		return s.login(r.PathValue("bot"), r.PathValue("login"), nil)
	})
	route(mux, "POST /bots/{bot}/login-sessions/{login}/verify", 200, s.verifyLogin)
	route(mux, "POST /bots/{bot}/connect", 200, func(r *http.Request) (any, error) { return ok, s.connect(r.PathValue("bot")) })
	route(mux, "POST /bots/{bot}/disconnect", 200, func(r *http.Request) (any, error) { return ok, s.disconnect(r.PathValue("bot"), false, false) })
	route(mux, "DELETE /bots/{bot}/credentials", 200, func(r *http.Request) (any, error) { return ok, s.disconnect(r.PathValue("bot"), true, false) })
	route(mux, "DELETE /bots/{bot}", 200, func(r *http.Request) (any, error) { return ok, s.disconnect(r.PathValue("bot"), true, true) })
	route(mux, "GET /bots/{bot}/logs", 200, s.botLogs)
	route(mux, "GET /bots/{bot}/conversation", 200, s.conversation)
	route(mux, "PATCH /bots/{bot}/conversation", 200, s.remark)
	route(mux, "POST /bots/{bot}/conversation/read", 200, s.readConversation)
	route(mux, "GET /bots/{bot}/conversation/messages", 200, s.chatMessages)
	route(mux, "POST /bots/{bot}/conversation/messages", 202, s.chatSend)

	route(mux, "GET /messages/{message}", 200, func(r *http.Request) (any, error) { return getMessage(s.db, r.PathValue("message")) })
	mux.HandleFunc("GET /messages/{message}/image", s.messageImage)
	route(mux, "POST /messages/{message}/retry", 202, s.retryMessage)

	route(mux, "GET /webhooks", 200, s.listWebhooks)
	route(mux, "POST /webhooks", 201, func(r *http.Request) (any, error) { return s.saveWebhook(r, true) })
	route(mux, "GET /webhooks/{hook}", 200, func(r *http.Request) (any, error) { return s.webhookView(r.PathValue("hook")) })
	route(mux, "PATCH /webhooks/{hook}", 200, func(r *http.Request) (any, error) { return s.saveWebhook(r, false) })
	route(mux, "DELETE /webhooks/{hook}", 200, s.deleteWebhook)
	route(mux, "POST /webhooks/{hook}/rotate-token", 200, s.rotateWebhook)
	route(mux, "POST /webhooks/{hook}/test", 202, s.testWebhook)
	route(mux, "GET /webhooks/{hook}/messages", 200, s.hookMessages)
	route(mux, "GET /webhooks/{hook}/requests", 200, s.requests)
	route(mux, "GET /webhook-requests", 200, s.requests)
	route(mux, "GET /webhooks/{hook}/notifications/{notification}", 200, func(r *http.Request) (any, error) {
		return result(s.db, r.PathValue("hook"), r.PathValue("notification"))
	})
}

func wechatChannel(db sqlRunner) (object, error) {
	// Prefer an existing binding, including one that needs to be reauthorized.
	connection, err := one(db, botView+` AND b.platform=?
		ORDER BY (b.account_id IS NOT NULL) DESC, b.created_at, b.id LIMIT 1`, botPlatform)
	if err != nil {
		return nil, err
	}
	if connection != nil {
		connection["hasCredentials"] = enabled(connection, "hasCredentials")
	}
	return object{"connection": connection}, nil
}

func (s *Service) ensureWechatChannel(_ *http.Request) (any, error) {
	result, err := s.db.Exec(`INSERT INTO bots(id,name,platform,created_at)
		SELECT ?,?,?,? WHERE NOT EXISTS (SELECT 1 FROM bots WHERE platform=? AND deleted_at IS NULL)`,
		id("bot"), "微信", botPlatform, nowMS(), botPlatform)
	if err != nil {
		return nil, err
	}
	if count, _ := result.RowsAffected(); count > 0 {
		s.changed()
	}
	return wechatChannel(s.db)
}

func (s *Service) bots(_ *http.Request) (any, error) {
	result, err := rows(s.db, botView+" ORDER BY b.created_at DESC")
	if err != nil {
		return nil, err
	}
	for _, item := range result {
		item["hasCredentials"] = enabled(item, "hasCredentials")
	}
	return result, nil
}
func renderBot(db sqlRunner, id string) (object, error) {
	item, err := required(db, "BOT_NOT_FOUND", "机器人不存在", botView+" AND b.id=?", id)
	if err != nil {
		return nil, err
	}
	item["hasCredentials"] = enabled(item, "hasCredentials")
	return item, nil
}
func (s *Service) saveBot(r *http.Request, create bool) (any, error) {
	var input struct {
		Name     *string `json:"name"`
		Note     *string `json:"note"`
		Platform *string `json:"platform"`
	}
	if err := decode(r, &input); err != nil {
		return nil, err
	}
	if (create && input.Name == nil) || (input.Platform != nil && (!create || *input.Platform != botPlatform)) {
		return nil, invalid("机器人名称或平台无效")
	}
	if input.Note != nil && len(utf16.Encode([]rune(*input.Note))) > 500 {
		return nil, invalid("机器人备注超过长度上限")
	}
	botID := r.PathValue("bot")
	err := transact(s.db, func(tx *sql.Tx) error {
		var old object
		if !create {
			var err error
			old, err = botByID(tx, botID)
			if err != nil {
				return err
			}
		}
		name, note := str(old, "name"), str(old, "note")
		if input.Name != nil {
			var err error
			name, err = validatedText(*input.Name, 80)
			if err != nil {
				return err
			}
		}
		if input.Note != nil {
			note = *input.Note
		}
		if create {
			botID = id("bot")
			return exec(tx, "INSERT INTO bots(id,name,platform,note,created_at) VALUES(?,?,?,?,?)", botID, name, botPlatform, note, nowMS())
		}
		return exec(tx, "UPDATE bots SET name=?,note=? WHERE id=?", name, note, botID)
	})
	if err != nil {
		return nil, err
	}
	s.changed()
	return renderBot(s.db, botID)
}
func (s *Service) verifyLogin(r *http.Request) (any, error) {
	var input struct {
		Code string `json:"code"`
	}
	if err := decode(r, &input); err != nil {
		return nil, err
	}
	code := strings.TrimSpace(input.Code)
	if !verificationCode.MatchString(code) {
		return nil, invalid("验证码格式无效")
	}
	_, err := s.login(r.PathValue("bot"), r.PathValue("login"), &code)
	return ok, err
}
func (s *Service) botLogs(r *http.Request) (any, error) {
	id := r.PathValue("bot")
	if _, err := botByID(s.db, id); err != nil {
		return nil, err
	}
	return rows(s.db, "SELECT id,level,event,detail,created_at createdAt FROM bot_logs WHERE bot_id=? ORDER BY created_at DESC LIMIT 100", id)
}

func (s *Service) conversation(r *http.Request) (any, error) {
	id := r.PathValue("bot")
	if _, err := botByID(s.db, id); err != nil {
		return nil, err
	}
	row, err := one(s.db, conversationView, id)
	if row != nil {
		row["hasContext"] = enabled(row, "hasContext")
	}
	return row, err
}
func getConversation(db sqlRunner, bot string) (object, error) {
	if _, err := botByID(db, bot); err != nil {
		return nil, err
	}
	result, err := one(db, "SELECT * FROM conversations WHERE bot_id=?", bot)
	if err == nil && result == nil {
		err = problem(409, "CONTEXT_REQUIRED", "请先在微信中给机器人发送消息")
	}
	return result, err
}
func (s *Service) remark(r *http.Request) (any, error) {
	var input struct {
		Remark *string `json:"remark"`
	}
	if err := decode(r, &input); err != nil {
		return nil, err
	}
	if input.Remark == nil || len(utf16.Encode([]rune(*input.Remark))) > 80 {
		return nil, invalid("会话备注无效")
	}
	err := transact(s.db, func(tx *sql.Tx) error {
		item, err := getConversation(tx, r.PathValue("bot"))
		if err != nil {
			return err
		}
		return exec(tx, "UPDATE conversations SET remark=? WHERE id=?", *input.Remark, str(item, "id"))
	})
	if err != nil {
		return nil, err
	}
	s.changed()
	return s.conversation(r)
}
func (s *Service) readConversation(r *http.Request) (any, error) {
	err := transact(s.db, func(tx *sql.Tx) error {
		item, err := getConversation(tx, r.PathValue("bot"))
		if err != nil {
			return err
		}
		return exec(tx, "UPDATE conversations SET unread=0 WHERE id=?", str(item, "id"))
	})
	if err == nil {
		s.changed()
	}
	return ok, err
}
func pageLimit(r *http.Request, fallback int) (int, error) {
	value := r.URL.Query().Get("limit")
	if value == "" {
		return fallback, nil
	}
	limit, err := strconv.Atoi(value)
	if err != nil || limit < 1 || limit > 100 {
		return 0, invalid("分页大小应为 1 至 100")
	}
	return limit, nil
}
func cursor(db sqlRunner, before, predicate, scope string) (int64, error) {
	if before == "" {
		return math.MaxInt64, nil
	}
	item, err := one(db, "SELECT seq FROM messages WHERE id=? AND "+predicate, before, scope)
	if err != nil {
		return 0, err
	}
	if item == nil {
		return 0, problem(400, "INVALID_CURSOR", "分页游标无效")
	}
	return integer(item, "seq"), nil
}
func page(items []object, limit int) object {
	var next any
	if len(items) > limit {
		items = items[:limit]
		next = items[len(items)-1]["id"]
	}
	slices.Reverse(items)
	return object{"items": items, "nextCursor": next}
}
func (s *Service) chatMessages(r *http.Request) (any, error) {
	conv, err := getConversation(s.db, r.PathValue("bot"))
	if err != nil {
		return nil, err
	}
	conversationID := str(conv, "id")
	limit, err := pageLimit(r, 40)
	if err != nil {
		return nil, err
	}
	before, err := cursor(s.db, r.URL.Query().Get("before"), "conversation_id=?", conversationID)
	if err != nil {
		return nil, err
	}
	list, err := rows(s.db, "SELECT "+messageView+` FROM messages WHERE conversation_id=? AND seq<?
		AND text LIKE ? ORDER BY seq DESC LIMIT ?`, conversationID, before, "%"+shorten(r.URL.Query().Get("search"), 100)+"%", limit+1)
	if err != nil {
		return nil, err
	}
	return page(list, limit), nil
}
func getMessage(db sqlRunner, id string) (object, error) {
	return required(db, "MESSAGE_NOT_FOUND", "消息不存在", "SELECT "+messageView+" FROM messages WHERE id=?", id)
}
func (s *Service) chatSend(r *http.Request) (any, error) {
	var input struct {
		Text string `json:"text"`
	}
	if err := decode(r, &input); err != nil {
		return nil, err
	}
	text, err := validatedText(input.Text, 4000)
	if err != nil {
		return nil, err
	}
	var result object
	err = transact(s.db, func(tx *sql.Tx) error {
		id, err := s.enqueue(tx, r.PathValue("bot"), notification{kind: "text", text: text}, "后台管理员", nil)
		if err != nil {
			return err
		}
		result, err = getMessage(tx, id)
		return err
	})
	if err == nil {
		s.changed()
	}
	return result, err
}
func (s *Service) messageImage(w http.ResponseWriter, r *http.Request) {
	image, err := required(s.db, "IMAGE_NOT_FOUND", "图片尚未准备好或不存在", "SELECT data,mime FROM message_images WHERE message_id=? AND data IS NOT NULL", r.PathValue("message"))
	if err != nil {
		writeError(w, err)
		return
	}
	data, _ := image["data"].([]byte)
	w.Header().Set("Content-Type", str(image, "mime"))
	w.Header().Set("Content-Security-Policy", "default-src 'none'; sandbox")
	_, _ = w.Write(data)
}
func (s *Service) retryMessage(r *http.Request) (any, error) {
	id := r.PathValue("message")
	var result object
	err := transact(s.db, func(tx *sql.Tx) error {
		message, err := getMessage(tx, id)
		if err != nil {
			return err
		}
		if str(message, "direction") != "out" {
			return notFound("MESSAGE_NOT_FOUND", "消息不存在")
		}
		if str(message, "status") != "failed" {
			return problem(409, "RETRY_NOT_ALLOWED", "仅明确发送失败的消息可以重试")
		}
		bot, err := botByID(tx, str(message, "botId"))
		if err != nil {
			return err
		}
		conversation, err := getConversation(tx, str(bot, "id"))
		if err != nil {
			return err
		}
		if !enabled(bot, "enabled") || str(conversation, "context") == "" {
			return problem(409, "BOT_UNAVAILABLE", "机器人未连接或会话上下文已失效")
		}
		if err := checkWindow(tx, str(conversation, "id")); err != nil {
			return err
		}
		if err := exec(tx, "UPDATE messages SET status='queued',error=NULL,updated_at=? WHERE id=?", nowMS(), id); err != nil {
			return err
		}
		result, err = getMessage(tx, id)
		return err
	})
	if err == nil {
		s.changed()
	}
	return result, err
}

func (s *Service) testWebhook(r *http.Request) (any, error) {
	hook, err := webhookByID(s.db, r.PathValue("hook"))
	if err != nil {
		return nil, err
	}
	if err := activeWebhook(hook); err != nil {
		return nil, err
	}
	return s.submit(r, hook, "", clientIP(r), true)
}
func (s *Service) hookMessages(r *http.Request) (any, error) {
	id := r.PathValue("hook")
	if _, err := webhookByID(s.db, id); err != nil {
		return nil, err
	}
	q := r.URL.Query()
	limit, err := pageLimit(r, 30)
	if err != nil {
		return nil, err
	}
	before, err := cursor(s.db, q.Get("before"), "webhook_id=? AND direction='out'", id)
	if err != nil {
		return nil, err
	}
	where := " WHERE messages.webhook_id=? AND messages.direction='out'"
	args := []any{id}
	if text := strings.TrimSpace(q.Get("search")); text != "" {
		if len(utf16.Encode([]rune(text))) > 100 {
			return nil, invalid("搜索词超过长度上限")
		}
		where += " AND messages.text LIKE ? ESCAPE '\\'"
		args = append(args, "%"+strings.NewReplacer("\\", "\\\\", "%", "\\%", "_", "\\_").Replace(text)+"%")
	}
	if kind := q.Get("type"); kind != "" {
		if !in(kind, "text", "image") {
			return nil, invalid("消息类型无效")
		}
		where += " AND messages.type=?"
		args = append(args, kind)
	}
	if status := q.Get("status"); status != "" {
		if !in(status, "queued", "sending", "provider_accepted", "failed", "unknown") {
			return nil, invalid("消息状态无效")
		}
		where += " AND messages.status=?"
		args = append(args, status)
	}
	total, err := one(s.db, "SELECT COUNT(*) n FROM messages"+where, args...)
	if err != nil {
		return nil, err
	}
	list, err := rows(s.db, "SELECT "+messageView+`,b.name botName,COALESCE(NULLIF(c.remark,''),c.name) conversationName,
		c.peer_id peerId,b.deleted_at IS NOT NULL botDeleted FROM messages JOIN bots b ON b.id=messages.bot_id
		JOIN conversations c ON c.id=messages.conversation_id`+where+" AND messages.seq<? ORDER BY messages.seq DESC LIMIT ?", append(args, before, limit+1)...)
	if err != nil {
		return nil, err
	}
	for _, item := range list {
		item["botDeleted"] = enabled(item, "botDeleted")
	}
	result := page(list, limit)
	result["total"] = integer(total, "n")
	return result, nil
}

func (s *Service) overview(_ *http.Request) (any, error) {
	zone := time.FixedZone("Shanghai", 8*3600)
	now := time.Now().In(zone)
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, zone)
	result := object{}
	totals := []struct {
		key, query string
		args       []any
	}{
		{"bots", "SELECT COUNT(*) n FROM bots WHERE deleted_at IS NULL", nil},
		{"onlineBots", "SELECT COUNT(*) n FROM bots WHERE deleted_at IS NULL AND status='online'", nil},
		{"receivedToday", "SELECT COUNT(*) n FROM messages WHERE direction='in' AND created_at>=?", []any{today.UnixMilli()}},
		{"sentToday", "SELECT COUNT(*) n FROM messages WHERE direction='out' AND status='provider_accepted' AND created_at>=?", []any{today.UnixMilli()}},
		{"failedToday", "SELECT COUNT(*) n FROM messages WHERE status IN ('failed','unknown') AND created_at>=?", []any{today.UnixMilli()}},
		{"queued", "SELECT COUNT(*) n FROM messages WHERE status IN ('queued','sending')", nil},
		{"webhooks", "SELECT COUNT(*) n FROM webhooks WHERE enabled=1", nil},
	}
	for _, metric := range totals {
		item, err := one(s.db, metric.query, metric.args...)
		if err != nil {
			return nil, err
		}
		result[metric.key] = integer(item, "n")
	}
	recent, err := rows(s.db, "SELECT "+messageView+`, b.name botName,COALESCE(NULLIF(c.remark,''),c.name) conversationName
		FROM messages JOIN bots b ON b.id=messages.bot_id JOIN conversations c ON c.id=messages.conversation_id
		WHERE b.deleted_at IS NULL ORDER BY messages.seq DESC LIMIT 8`)
	if err != nil {
		return nil, err
	}
	result["recentMessages"] = recent
	activity := make([]object, 0, 7)
	for i := 6; i >= 0; i-- {
		start := today.AddDate(0, 0, -i)
		item, err := one(s.db, `SELECT COALESCE(SUM(direction='in'),0) incoming,
			COALESCE(SUM(direction='out' AND status='provider_accepted'),0) outgoing
			FROM messages WHERE created_at>=? AND created_at<?`, start.UnixMilli(), start.AddDate(0, 0, 1).UnixMilli())
		if err != nil {
			return nil, err
		}
		item["date"] = start.Format("2006-01-02")
		activity = append(activity, item)
	}
	result["activity"] = activity
	return result, nil
}

type clientIPKey struct{}

func WithClientIP(r *http.Request, ip string) *http.Request {
	return r.WithContext(context.WithValue(r.Context(), clientIPKey{}, ip))
}
func clientIP(r *http.Request) string {
	value, _ := r.Context().Value(clientIPKey{}).(string)
	return value
}
