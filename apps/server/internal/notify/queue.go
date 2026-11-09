package notify

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	qrcode "github.com/skip2/go-qrcode"
)

const botPlatform = "wechat_ilink"

func botByID(db sqlRunner, botID string) (object, error) {
	return required(db, "BOT_NOT_FOUND", "机器人不存在", "SELECT * FROM bots WHERE id=? AND deleted_at IS NULL", botID)
}
func required(db sqlRunner, code, message, query string, args ...any) (object, error) {
	item, err := one(db, query, args...)
	if err == nil && item == nil {
		err = notFound(code, message)
	}
	return item, err
}
func (s *Service) credentials(bot object) (credentials, error) {
	if str(bot, "credentials") == "" || str(bot, "base_url") == "" {
		return credentials{}, problem(409, "BOT_NOT_LOGGED_IN", "机器人尚未登录")
	}
	token, err := s.vault.open(str(bot, "credentials"))
	return credentials{token, str(bot, "base_url")}, err
}
func (s *Service) log(bot, event, detail, level string) {
	if err := exec(s.db, "INSERT INTO bot_logs VALUES (?,?,?,?,?,?)", id("log"), bot, level, event, detail, nowMS()); err != nil {
		slog.Warn("could not save notification log")
	}
}
func (s *Service) start() error {
	for _, stmt := range []string{
		"UPDATE messages SET status='unknown',error='网关在发送过程中重启，请确认接收情况' WHERE status='sending'",
		"UPDATE notification_deliveries SET status='unknown',code='APNS_OUTCOME_UNKNOWN',error='网关在发送过程中重启，请确认接收情况' WHERE channel='apns' AND status='sending'",
		"UPDATE direct_push SET status='unknown',code='APNS_OUTCOME_UNKNOWN',error='网关在发送过程中重启，请确认接收情况' WHERE status='sending'",
		"UPDATE bots SET status=CASE WHEN credentials IS NULL THEN 'pending' ELSE 'stopped' END WHERE enabled=0 OR status='logging_in'",
	} {
		if err := exec(s.db, stmt); err != nil {
			return err
		}
	}
	if current, err := currentDevice(s.db); err != nil {
		return err
	} else if current != nil && !in(str(current, "console_id"), s.consoles...) {
		if err := exec(s.db, "UPDATE push_devices SET token=NULL,status='revoked',updated_at=? WHERE id=?", nowMS(), str(current, "id")); err != nil {
			return err
		}
	}
	bots, err := rows(s.db, "SELECT id FROM bots WHERE enabled=1 AND credentials IS NOT NULL AND deleted_at IS NULL")
	if err != nil {
		return err
	}
	for _, bot := range bots {
		if err := s.connect(str(bot, "id")); err != nil {
			slog.Warn("could not restore notification bot")
		}
	}
	s.workers.Go(s.runQueue)
	return nil
}
func (s *Service) connect(botID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.connectLocked(botID)
}
func (s *Service) connectLocked(botID string) error {
	if s.ctx.Err() != nil {
		return s.ctx.Err()
	}
	for _, login := range s.logins {
		if login.BotID == botID && !in(login.Status, "confirmed", "expired", "error", "verify_code_blocked") {
			return problem(409, "LOGIN_IN_PROGRESS", "微信正在扫码授权")
		}
	}
	if s.polls[botID] != nil {
		return nil
	}
	bot, err := botByID(s.db, botID)
	if err != nil {
		return err
	}
	cred, err := s.credentials(bot)
	if err != nil {
		return err
	}
	if err := exec(s.db, "UPDATE bots SET enabled=1,status='connecting',last_error=NULL WHERE id=?", botID); err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(s.ctx)
	op := &operation{cancel}
	s.polls[botID] = op
	s.log(botID, "connect", "启动微信消息连接", "info")
	s.changed()
	s.workers.Go(func() {
		defer cancel()
		s.pollBot(ctx, botID, cred)
		s.mu.Lock()
		if s.polls[botID] == op {
			delete(s.polls, botID)
		}
		s.mu.Unlock()
	})
	return nil
}
func (s *Service) stopLocked(botID string, clear, remove bool) error {
	bot, err := botByID(s.db, botID)
	if err != nil {
		return err
	}
	if op := s.polls[botID]; op != nil {
		op.cancel()
		delete(s.polls, botID)
	}
	if op := s.sending[botID]; op != nil {
		op.cancel()
	}
	for _, login := range s.logins {
		if login.BotID == botID {
			login.cancel()
			login.Status = "expired"
		}
	}
	err = transact(s.db, func(tx *sql.Tx) error {
		status := "stopped"
		if clear {
			status = "pending"
		}
		if err := exec(tx, "UPDATE bots SET enabled=0,status=?,last_error=NULL WHERE id=?", status, botID); err != nil {
			return err
		}
		if err := exec(tx, "UPDATE messages SET status='failed',error='机器人连接已停止',updated_at=? WHERE bot_id=? AND status='queued'", nowMS(), botID); err != nil {
			return err
		}
		if clear {
			if err := exec(tx, "UPDATE bots SET credentials=NULL,base_url=NULL,cursor='' WHERE id=?", botID); err != nil {
				return err
			}
			if err := exec(tx, "UPDATE conversations SET context=NULL WHERE bot_id=?", botID); err != nil {
				return err
			}
		}
		if remove {
			if err := exec(tx, "UPDATE bots SET deleted_at=? WHERE id=?", nowMS(), botID); err != nil {
				return err
			}
			return exec(tx, "UPDATE webhooks SET enabled=0 WHERE bot_id=? AND apns_enabled=0", botID)
		}
		return nil
	})
	if err != nil {
		return err
	}
	if s.ctx.Err() == nil {
		if cred, err := s.credentials(bot); err == nil {
			s.workers.Go(func() { s.wechat.presence(s.ctx, cred, false) })
		}
	}
	s.log(botID, "disconnect", "已停止微信消息连接", "info")
	s.changed()
	return nil
}
func (s *Service) disconnect(botID string, clear, remove bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.stopLocked(botID, clear, remove)
}
func (s *Service) expireLocked(botID string) {
	if op := s.polls[botID]; op != nil {
		op.cancel()
		delete(s.polls, botID)
	}
	if err := transact(s.db, func(tx *sql.Tx) error {
		if err := exec(tx, "UPDATE bots SET enabled=0,status='expired',last_error='微信授权已失效，请重新扫码登录' WHERE id=?", botID); err != nil {
			return err
		}
		if err := exec(tx, "UPDATE conversations SET context=NULL WHERE bot_id=?", botID); err != nil {
			return err
		}
		return exec(tx, "UPDATE messages SET status='failed',error='微信授权已失效',updated_at=? WHERE bot_id=? AND status='queued'", nowMS(), botID)
	}); err != nil {
		slog.Warn("could not expire notification bot")
	}
	s.log(botID, "expired", "微信授权已失效，请重新扫码登录", "error")
	s.changed()
}

type loginSession struct {
	ID               string  `json:"id"`
	BotID            string  `json:"botId"`
	Status           string  `json:"status"`
	QRImage          string  `json:"qrImage"`
	QRContent        string  `json:"qrContent"`
	ExpiresAt        int64   `json:"expiresAt"`
	Error            *string `json:"error"`
	qr, base, verify string
	cancel           context.CancelFunc
}

func (s *Service) createLogin(ctx context.Context, botID string) (loginSession, error) {
	if _, err := botByID(s.db, botID); err != nil {
		return loginSession{}, err
	}
	stored, err := rows(s.db, "SELECT credentials FROM bots WHERE credentials IS NOT NULL AND deleted_at IS NULL ORDER BY created_at DESC LIMIT 10")
	if err != nil {
		return loginSession{}, err
	}
	tokens := make([]string, 0, len(stored))
	for _, item := range stored {
		value, err := s.vault.open(str(item, "credentials"))
		if err != nil {
			return loginSession{}, err
		}
		tokens = append(tokens, value)
	}
	qr, err := s.wechat.createLogin(ctx, tokens)
	if err != nil {
		return loginSession{}, err
	}
	if qr.QR == "" || qr.Content == "" {
		return loginSession{}, problem(502, "INVALID_QR", "微信未返回有效二维码")
	}
	image, err := qrcode.Encode(qr.Content, qrcode.Medium, 280)
	if err != nil {
		return loginSession{}, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ctx.Err() != nil {
		return loginSession{}, s.ctx.Err()
	}
	for key, old := range s.logins {
		if old.ExpiresAt < nowMS() {
			old.cancel()
			delete(s.logins, key)
		}
	}
	if err := s.stopLocked(botID, false, false); err != nil {
		return loginSession{}, err
	}
	if err := exec(s.db, "UPDATE bots SET status='logging_in' WHERE id=?", botID); err != nil {
		return loginSession{}, err
	}
	pollCtx, cancel := context.WithTimeout(s.ctx, 5*time.Minute)
	entry := &loginSession{
		ID: id("login"), BotID: botID, Status: "wait", QRImage: "data:image/png;base64," + base64.StdEncoding.EncodeToString(image),
		QRContent: qr.Content, ExpiresAt: nowMS() + 300_000, qr: qr.QR, base: wechatBase, cancel: cancel,
	}
	s.logins[entry.ID] = entry
	s.changed()
	s.workers.Go(func() { defer cancel(); s.pollLogin(pollCtx, entry) })
	return *entry, nil
}
func (s *Service) login(botID, loginID string, code *string) (loginSession, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entry := s.logins[loginID]
	if entry == nil || entry.BotID != botID {
		return loginSession{}, notFound("LOGIN_NOT_FOUND", "登录会话已失效，请刷新二维码")
	}
	if code != nil {
		if entry.Status != "need_verifycode" {
			return loginSession{}, problem(409, "VERIFY_NOT_REQUIRED", "当前登录流程无需验证码")
		}
		entry.verify = *code
	}
	return *entry, nil
}
func pause(ctx context.Context, d time.Duration) bool {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}
func (s *Service) pollLogin(ctx context.Context, entry *loginSession) {
	for ctx.Err() == nil {
		s.mu.Lock()
		base, qr, code := entry.base, entry.qr, entry.verify
		entry.verify = ""
		s.mu.Unlock()
		result, err := s.wechat.pollLogin(ctx, base, qr, code)
		s.mu.Lock()
		if ctx.Err() != nil {
			s.mu.Unlock()
			break
		}
		if err != nil {
			message := "扫码状态获取失败，正在重试"
			var provider *providerError
			if errors.As(err, &provider) {
				message = provider.message
			}
			entry.Error = &message
			s.changed()
			s.mu.Unlock()
			if !pause(ctx, 2*time.Second) {
				break
			}
			continue
		}
		entry.Status = result.Status
		entry.Error = nil
		switch result.Status {
		case "scaned_but_redirect":
			if result.Redirect != "" {
				entry.base, err = validatedBase(result.Redirect)
			}
		case "confirmed", "binded_redirect":
			err = s.confirmLoginLocked(entry, result)
		}
		if err != nil {
			message := "微信登录失败，请刷新二维码重新尝试"
			var known *apiError
			if errors.As(err, &known) {
				message = known.message
			}
			entry.Error = &message
			entry.Status = "error"
		}
		done := in(entry.Status, "confirmed", "expired", "verify_code_blocked", "error")
		s.changed()
		s.mu.Unlock()
		if done || !pause(ctx, time.Second) {
			break
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if entry.Status == "confirmed" || ctx.Err() == context.Canceled {
		return
	}
	if !in(entry.Status, "error", "expired", "verify_code_blocked") {
		entry.Status = "expired"
	}
	_ = exec(s.db, "UPDATE bots SET status=CASE WHEN credentials IS NULL THEN 'pending' ELSE 'stopped' END WHERE id=? AND status='logging_in'", entry.BotID)
	s.changed()
}
func (s *Service) confirmLoginLocked(entry *loginSession, result loginResult) error {
	bot, err := botByID(s.db, entry.BotID)
	if err != nil {
		return err
	}
	if result.Status == "binded_redirect" {
		if str(bot, "credentials") == "" {
			return problem(409, "ALREADY_BOUND", "该账号已有微信连接，请使用原绑定账号扫码")
		}
		entry.Status = "confirmed"
		return s.connectLocked(entry.BotID)
	}
	if result.Token == "" || result.Account == "" || result.Peer == "" {
		return errors.New("missing WeChat credentials")
	}
	if result.Base == "" {
		result.Base = wechatBase
	}
	base, err := validatedBase(result.Base)
	if err != nil {
		return err
	}
	if (str(bot, "account_id") != "" && str(bot, "account_id") != result.Account) || (str(bot, "peer_id") != "" && str(bot, "peer_id") != result.Peer) {
		return problem(409, "BOT_ALREADY_BOUND", "微信渠道已绑定其他账号，请使用原账号扫码")
	}
	err = transact(s.db, func(tx *sql.Tx) error {
		duplicate, err := one(tx, "SELECT id FROM bots WHERE platform=? AND account_id=? AND id<>? AND deleted_at IS NULL", botPlatform, result.Account, entry.BotID)
		if err != nil {
			return err
		}
		if duplicate != nil {
			return problem(409, "ACCOUNT_ALREADY_BOUND", "该微信账号已有其他连接")
		}
		if err := exec(tx, "UPDATE bots SET credentials=?,base_url=?,account_id=?,peer_id=?,cursor='' WHERE id=?", s.vault.seal(result.Token), base, result.Account, result.Peer, entry.BotID); err != nil {
			return err
		}
		return exec(tx, "UPDATE conversations SET context=NULL WHERE bot_id=?", entry.BotID)
	})
	if err != nil {
		return err
	}
	s.log(entry.BotID, "login", "微信扫码登录成功", "info")
	return s.connectLocked(entry.BotID)
}

func (s *Service) pollBot(ctx context.Context, botID string, cred credentials) {
	s.wechat.presence(ctx, cred, true)
	failures := 0
	for ctx.Err() == nil {
		bot, err := botByID(s.db, botID)
		if err != nil {
			return
		}
		result, err := s.wechat.updates(ctx, cred, str(bot, "cursor"))
		s.mu.Lock()
		if ctx.Err() != nil {
			s.mu.Unlock()
			return
		}
		if err == nil {
			err = transact(s.db, func(tx *sql.Tx) error {
				for _, message := range result.Messages {
					if err := s.ingest(tx, bot, message); err != nil {
						return err
					}
				}
				if result.Cursor != "" {
					if err := exec(tx, "UPDATE bots SET cursor=? WHERE id=?", result.Cursor, botID); err != nil {
						return err
					}
				}
				return exec(tx, "UPDATE bots SET status='online',last_error=NULL,last_seen_at=? WHERE id=?", nowMS(), botID)
			})
		}
		if err != nil {
			message := "消息同步失败，正在重新连接"
			var provider *providerError
			if errors.As(err, &provider) {
				if provider.code == -14 {
					s.expireLocked(botID)
					s.mu.Unlock()
					return
				}
				message = provider.message
			}
			failures++
			_ = exec(s.db, "UPDATE bots SET status='reconnecting',last_error=? WHERE id=?", message, botID)
			if failures == 1 {
				s.log(botID, "reconnecting", message, "warn")
			}
			s.changed()
			s.mu.Unlock()
			if !pause(ctx, min(30*time.Second, time.Second<<min(failures, 5))) {
				return
			}
			continue
		}
		if failures > 0 || str(bot, "status") != "online" {
			s.log(botID, "online", "微信消息连接正常", "info")
		}
		failures = 0
		s.changed()
		s.mu.Unlock()
		if !pause(ctx, 150*time.Millisecond) {
			return
		}
	}
}
func messageKey(message incoming) string {
	for _, raw := range []json.RawMessage{message.ID, message.AlternateID} {
		value := string(raw)
		if !in(value, "", "null", "0", "\"\"") {
			var text string
			if json.Unmarshal(raw, &text) == nil {
				return text
			}
			return value
		}
	}
	if message.ClientID != "" {
		return message.ClientID
	}
	data, _ := json.Marshal(message)
	return sha(data)
}
func (s *Service) ingest(tx *sql.Tx, bot object, message incoming) error {
	if message.Peer == "" || message.Peer != str(bot, "peer_id") || (message.Type != nil && *message.Type != 1) {
		return nil
	}
	botID := str(bot, "id")
	key := messageKey(message)
	duplicate, err := one(tx, "SELECT id FROM messages WHERE bot_id=? AND provider_key=?", botID, key)
	if duplicate != nil || err != nil {
		return err
	}
	conversation, err := one(tx, "SELECT id,peer_id FROM conversations WHERE bot_id=?", botID)
	if err != nil {
		return err
	}
	conversationID := str(conversation, "id")
	if conversation == nil {
		conversationID = id("conv")
		if err := exec(tx, "INSERT INTO conversations (id,bot_id,peer_id,name,last_message_at) VALUES (?,?,?,?,0)", conversationID, botID, message.Peer, message.Peer); err != nil {
			return err
		}
	} else if str(conversation, "peer_id") != message.Peer {
		return nil
	}
	if message.Context != "" {
		if err := exec(tx, "UPDATE conversations SET context=? WHERE id=?", s.vault.seal(message.Context), conversationID); err != nil {
			return err
		}
	}
	kind := "text"
	parts := make([]string, 0, len(message.Items))
	for _, item := range message.Items {
		if item.Type != 1 {
			kind = "mixed"
		}
		part := item.Text.Text
		if part == "" {
			part = item.Voice.Text
		}
		if part == "" {
			switch item.Type {
			case 2:
				part = "[图片]"
			case 3:
				part = "[语音]"
			case 4:
				part = "[文件] " + item.File.Name
			case 5:
				part = "[视频]"
			default:
				part = "[暂不支持的消息]"
			}
		}
		parts = append(parts, part)
	}
	text := strings.Join(parts, "\n")
	now := nowMS()
	at := message.Time
	if at <= 0 || at >= now+windowMS {
		at = now
	}
	if err := exec(tx, `INSERT INTO messages (id,bot_id,conversation_id,direction,type,text,status,source,provider_key,created_at,updated_at)
		VALUES (?,?,?,'in',?,?,'received','微信',?,?,?)`, id("msg"), botID, conversationID, kind, text, key, at, now); err != nil {
		return err
	}
	return exec(tx, `UPDATE conversations SET unread=unread+1,last_message=CASE WHEN last_message_at<=? THEN ? ELSE last_message END,
		last_message_at=MAX(last_message_at,?) WHERE id=?`, at, shorten(text, 200), at, conversationID)
}

func lastInbound(db sqlRunner, conversation string) (int64, error) {
	item, err := one(db, "SELECT MAX(MIN(created_at,updated_at)) time FROM messages WHERE conversation_id=? AND direction='in'", conversation)
	return integer(item, "time"), err
}
func checkWindow(db sqlRunner, conversation string) error {
	last, err := lastInbound(db, conversation)
	if err != nil {
		return err
	}
	if last == 0 || nowMS()-last >= windowMS {
		return problem(409, windowCode, windowMessage)
	}
	return nil
}
func (s *Service) enqueue(tx *sql.Tx, botID string, n notification, source string, webhook any) (string, error) {
	bot, err := botByID(tx, botID)
	if err != nil {
		return "", err
	}
	conversation, err := one(tx, "SELECT id,context FROM conversations WHERE bot_id=?", botID)
	if err != nil {
		return "", err
	}
	if str(conversation, "context") == "" {
		return "", problem(409, "CONTEXT_REQUIRED", "请先在微信中给机器人发送消息，建立会话上下文")
	}
	conversationID := str(conversation, "id")
	if err := checkWindow(tx, conversationID); err != nil {
		return "", err
	}
	if !enabled(bot, "enabled") || str(bot, "credentials") == "" || !in(str(bot, "status"), "online", "connecting", "reconnecting") {
		return "", problem(409, "BOT_OFFLINE", "机器人未连接，请先登录并启动连接")
	}
	messageID, at, text := id("msg"), nowMS(), n.summary()
	if err := exec(tx, `INSERT INTO messages (id,bot_id,conversation_id,direction,type,text,status,source,webhook_id,created_at,updated_at)
		VALUES (?,?,?,'out',?,?,'queued',?,?,?,?)`, messageID, botID, conversationID, n.kind, text, source, webhook, at, at); err != nil {
		return "", err
	}
	if n.kind == "image" {
		var link, data, mime any
		if n.url != "" {
			link = s.vault.seal(n.url)
		} else {
			data, mime = n.data, n.mime
		}
		if err := exec(tx, "INSERT INTO message_images (message_id,source_url,data,mime) VALUES (?,?,?,?)", messageID, link, data, mime); err != nil {
			return "", err
		}
	}
	return messageID, exec(tx, "UPDATE conversations SET last_message=?,last_message_at=? WHERE id=?", shorten(text, 200), at, conversationID)
}
func (s *Service) reminders() error {
	now := nowMS()
	items, err := rows(s.db, `SELECT c.id,c.bot_id,MAX(MIN(m.created_at,m.updated_at)) window_start
		FROM conversations c JOIN bots b ON b.id=c.bot_id JOIN messages m ON m.conversation_id=c.id AND m.direction='in'
		WHERE b.deleted_at IS NULL AND b.enabled=1 AND b.status='online' AND b.credentials IS NOT NULL AND c.context IS NOT NULL
		GROUP BY c.id HAVING window_start>? AND window_start<=?`, now-windowMS, now-windowMS+30*60_000)
	if err != nil {
		return err
	}
	for _, item := range items {
		created := false
		err := transact(s.db, func(tx *sql.Tx) error {
			conversation, window := str(item, "id"), integer(item, "window_start")
			last, err := lastInbound(tx, conversation)
			if err != nil || last != window {
				return err
			}
			previous, err := one(tx, "SELECT window_start FROM send_window_reminders WHERE conversation_id=?", conversation)
			if err != nil || integer(previous, "window_start") == window {
				return err
			}
			text := fmt.Sprintf("微信通知接收提醒：距离本次 24 小时发送窗口关闭约 %d 分钟。请主动给当前机器人发送一条消息（例如“续期”），以继续接收通知。仅收到这条提醒不会延长窗口。", max(1, (window+windowMS-now+59_999)/60_000))
			id, err := s.enqueue(tx, str(item, "bot_id"), notification{kind: "text", text: text}, reminderSource, nil)
			if err != nil {
				return err
			}
			created = true
			return exec(tx, "INSERT INTO send_window_reminders VALUES (?,?,?) ON CONFLICT(conversation_id) DO UPDATE SET window_start=excluded.window_start,message_id=excluded.message_id", conversation, window, id)
		})
		if err != nil {
			var expected *apiError
			if !errors.As(err, &expected) {
				return err
			}
		} else if created {
			s.log(str(item, "bot_id"), "send_window_reminder", "已创建微信发送窗口临期提醒", "info")
			s.changed()
		}
	}
	return nil
}
func (s *Service) runQueue() {
	timer := time.NewTicker(500 * time.Millisecond)
	defer timer.Stop()
	nextReminder := time.Time{}
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-timer.C:
			if time.Now().After(nextReminder) {
				nextReminder = time.Now().Add(time.Minute)
				if err := s.reminders(); err != nil {
					slog.Warn("notification reminder scan failed")
				}
			}
			if err := s.drainWechat(); err != nil {
				slog.Warn("WeChat queue scan failed")
			}
			if err := s.drainAPNs(); err != nil {
				slog.Warn("APNs queue scan failed")
			}
		}
	}
}
func (s *Service) drainWechat() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ctx.Err() != nil {
		return nil
	}
	items, err := rows(s.db, `SELECT m.*,b.status bot_status FROM messages m JOIN bots b ON b.id=m.bot_id
		WHERE m.status='queued' AND m.direction='out' ORDER BY m.seq LIMIT 100`)
	if err != nil {
		return err
	}
	for _, item := range items {
		botID, id := str(item, "bot_id"), str(item, "id")
		if s.sending[botID] != nil {
			continue
		}
		if str(item, "bot_status") != "online" {
			if nowMS()-integer(item, "created_at") > 10*60_000 {
				if err := exec(s.db, "UPDATE messages SET status='failed',error='等待机器人连接超时',updated_at=? WHERE id=? AND status='queued'", nowMS(), id); err != nil {
					return err
				}
				s.changed()
			}
			continue
		}
		result, err := s.db.Exec("UPDATE messages SET status='sending',updated_at=? WHERE id=? AND status='queued'", nowMS(), id)
		if err != nil {
			return err
		}
		n, err := result.RowsAffected()
		if err != nil {
			return err
		}
		if n == 0 {
			continue
		}
		ctx, cancel := context.WithCancel(s.ctx)
		s.sending[botID] = &operation{cancel}
		s.changed()
		s.workers.Go(func() {
			defer cancel()
			s.deliverWechat(ctx, item)
			s.mu.Lock()
			delete(s.sending, botID)
			s.mu.Unlock()
		})
	}
	return nil
}
func (s *Service) sendWechat(ctx context.Context, message object) (bool, error) {
	conversationID, botID := str(message, "conversation_id"), str(message, "bot_id")
	conversation, err := one(s.db, "SELECT * FROM conversations WHERE id=? AND bot_id=?", conversationID, botID)
	if err != nil {
		return false, err
	}
	if str(conversation, "context") == "" {
		return false, problem(409, "CONTEXT_REQUIRED", "会话上下文已失效，请在微信中重新发一条消息")
	}
	if str(message, "source") == reminderSource {
		reminder, err := one(s.db, "SELECT window_start FROM send_window_reminders WHERE conversation_id=? AND message_id=?", conversationID, str(message, "id"))
		if err != nil {
			return false, err
		}
		last, err := lastInbound(s.db, conversationID)
		if err != nil {
			return false, err
		}
		if reminder == nil || last != integer(reminder, "window_start") {
			return false, problem(409, "REMINDER_STALE", "用户已发送新消息，已取消旧窗口提醒")
		}
	}
	if err := checkWindow(s.db, conversationID); err != nil {
		return false, err
	}
	bot, err := botByID(s.db, botID)
	if err != nil {
		return false, err
	}
	cred, err := s.credentials(bot)
	if err != nil {
		return false, err
	}
	contextToken, err := s.vault.open(str(conversation, "context"))
	if err != nil {
		return false, err
	}
	peer := str(conversation, "peer_id")
	item := object{"type": 1, "text_item": object{"text": str(message, "text")}}
	if str(message, "type") == "image" {
		media, err := one(s.db, "SELECT data,mime,source_url FROM message_images WHERE message_id=?", str(message, "id"))
		if err != nil {
			return false, err
		}
		data, _ := media["data"].([]byte)
		if len(data) == 0 {
			link, err := s.vault.open(str(media, "source_url"))
			if err != nil {
				return false, problem(409, "IMAGE_NOT_FOUND", "图片数据不存在或无法解密")
			}
			bytes, mime, err := downloadImage(ctx, link)
			if err != nil {
				return false, err
			}
			data = bytes
			if err := exec(s.db, "UPDATE message_images SET data=?,mime=? WHERE message_id=?", data, mime, str(message, "id")); err != nil {
				return false, err
			}
		}
		item, err = s.wechat.imageItem(ctx, cred, peer, data)
		if err != nil {
			return false, err
		}
	}
	if err := checkWindow(s.db, conversationID); err != nil {
		return false, err
	}
	if ctx.Err() != nil {
		return false, ctx.Err()
	}
	return true, s.wechat.send(ctx, cred, peer, contextToken, str(message, "id"), item)
}
func (s *Service) deliverWechat(ctx context.Context, message object) {
	attempted, err := s.sendWechat(ctx, message)
	status := "provider_accepted"
	var detail any
	if err != nil {
		status = "failed"
		detail = "消息准备失败，尚未提交平台"
		var provider *providerError
		var known *apiError
		switch {
		case errors.As(err, &provider):
			detail = provider.message
			if attempted && !provider.definite {
				status = "unknown"
			}
			if provider.code == -14 {
				s.mu.Lock()
				if ctx.Err() == nil {
					s.expireLocked(str(message, "bot_id"))
				}
				s.mu.Unlock()
			}
		case errors.As(err, &known):
			detail = known.message
		case attempted:
			status, detail = "unknown", "发送被中断，结果待确认，请核实接收情况"
		}
	}
	if err := exec(s.db, "UPDATE messages SET status=?,error=?,updated_at=? WHERE id=? AND status='sending'", status, detail, nowMS(), str(message, "id")); err != nil {
		slog.Warn("could not update WeChat delivery status")
	}
	s.changed()
}

func currentDevice(db sqlRunner) (object, error) {
	return one(db, "SELECT * FROM push_devices WHERE status<>'revoked'")
}
func (s *Service) drainAPNs() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ctx.Err() != nil || s.busyAPNs >= 8 {
		return nil
	}
	items, err := rows(s.db, `SELECT d.id,d.target_id,r.apns_payload,r.created_at,d.updated_at,0 direct
		FROM notification_deliveries d JOIN webhook_requests r ON r.id=d.notification_id WHERE d.channel='apns' AND d.status='queued'
		UNION ALL SELECT id,target_id,payload,created_at,updated_at,1 FROM direct_push WHERE status='queued'
		ORDER BY updated_at,id LIMIT ?`, 8-s.busyAPNs)
	if err != nil {
		return err
	}
	for _, job := range items {
		table := "notification_deliveries"
		if enabled(job, "direct") {
			table = "direct_push"
		}
		res, err := s.db.Exec("UPDATE "+table+" SET status='sending',updated_at=? WHERE id=? AND status='queued'", nowMS(), str(job, "id"))
		if err != nil {
			return err
		}
		n, err := res.RowsAffected()
		if err != nil {
			return err
		}
		if n == 0 {
			continue
		}
		s.busyAPNs++
		s.changed()
		s.workers.Go(func() {
			s.deliverAPNs(job, table)
			s.mu.Lock()
			s.busyAPNs--
			s.mu.Unlock()
		})
	}
	return nil
}
func (s *Service) deliverAPNs(job object, table string) {
	status, code, detail := s.sendAPNs(job)
	var failureCode, failureDetail any
	if code != "" {
		failureCode, failureDetail = code, detail
	}
	if err := exec(s.db, "UPDATE "+table+" SET status=?,code=?,error=?,updated_at=? WHERE id=? AND status='sending'", status, failureCode, failureDetail, nowMS(), str(job, "id")); err != nil {
		slog.Warn("could not update APNs delivery status")
	}
	s.changed()
}
func (s *Service) sendAPNs(job object) (string, string, string) {
	expires := integer(job, "created_at") + 15*60_000
	if nowMS() >= expires {
		return "failed", "APNS_DELIVERY_EXPIRED", "等待发送 Apple Push 超时"
	}
	provider := s.apnsProvider()
	if provider == nil {
		return "failed", "APNS_NOT_CONFIGURED", "网关尚未配置 APNs"
	}
	device, err := one(s.db, "SELECT * FROM push_devices WHERE id=? AND status='active'", str(job, "target_id"))
	if err != nil || device == nil {
		return "failed", "APNS_DEVICE_UNAVAILABLE", "Apple Push 设备已失效或解绑"
	}
	sealed := str(device, "token")
	token, err := s.vault.open(sealed)
	if err != nil {
		return "failed", "APNS_DEVICE_UNAVAILABLE", "无法读取 Apple Push 设备凭证"
	}
	result, err := provider.send(s.ctx, str(job, "id"), str(device, "environment"), token, str(job, "apns_payload"), expires)
	if err != nil {
		return "unknown", "APNS_OUTCOME_UNKNOWN", "APNs 请求中断，结果待确认"
	}
	if result.status == 200 {
		return "provider_accepted", "", ""
	}
	if result.status == 410 && in(result.Reason, "ExpiredToken", "Unregistered") && (result.Timestamp == 0 || integer(device, "updated_at") <= result.Timestamp) {
		_ = exec(s.db, "UPDATE push_devices SET status='invalid',token=NULL,updated_at=? WHERE id=? AND token=?", nowMS(), str(device, "id"), sealed)
	}
	reason := ""
	if apnsReason.MatchString(result.Reason) {
		reason = " · " + result.Reason
	}
	return "failed", fmt.Sprintf("APNS_HTTP_%d", result.status), fmt.Sprintf("APNs 拒绝请求（%d%s）", result.status, reason)
}
