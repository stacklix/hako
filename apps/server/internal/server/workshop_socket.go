package server

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/websocket"
	"hako/server/internal/workshop"
)

var workshopOperationID = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func (s *Server) workshopAgentSocket(w http.ResponseWriter, r *http.Request) {
	if !s.allow("workshop-auth", 30, time.Minute) {
		reject(w, 429, "rate_limited")
		return
	}
	u := websocket.Upgrader{HandshakeTimeout: 5 * time.Second, CheckOrigin: func(r *http.Request) bool { return r.Header.Get("Origin") == "" }}
	ws, err := u.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer ws.Close()
	ws.SetReadLimit(64 * 1024)
	_ = ws.SetReadDeadline(time.Now().Add(10 * time.Second))
	fail := func() {
		_ = ws.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.ClosePolicyViolation, "workshop authentication failed"), time.Now().Add(time.Second))
	}
	var hello workshop.Frame
	if ws.ReadJSON(&hello) != nil || hello.Kind != "hello" || hello.Protocol != workshop.Protocol || !equal(hello.Account, s.config.Username) {
		fail()
		return
	}
	var configured *AgentConfig
	for _, entry := range s.registry.Load().Agents {
		if equal(entry.keyID, hello.KeyID) {
			copy := entry
			configured = &copy
			break
		}
	}
	if configured == nil {
		fail()
		return
	}
	c := workshop.New(ws, randomToken)
	payload := []byte("hako-workshop-auth/v1\n" + s.config.PublicURL + "\n" + hello.Account + "\n" + hello.KeyID + "\n" + randomToken())
	if c.Send(map[string]any{"kind": "challenge", "protocol": workshop.Protocol, "payload": base64.StdEncoding.EncodeToString(payload)}) != nil {
		return
	}
	var proof workshop.Frame
	if ws.ReadJSON(&proof) != nil || proof.Kind != "proof" {
		fail()
		return
	}
	signature, err := base64.StdEncoding.DecodeString(proof.Signature)
	hash := sha256.Sum256(payload)
	if err != nil || rsa.VerifyPSS(configured.key, crypto.SHA256, hash[:], signature, &rsa.PSSOptions{SaltLength: rsa.PSSSaltLengthEqualsHash}) != nil {
		fail()
		return
	}
	s.registryMu.Lock()
	trusted := false
	for _, entry := range s.registry.Load().Agents {
		if entry.ID == configured.ID && entry.keyID == configured.keyID {
			trusted = true
			break
		}
	}
	if !trusted {
		s.registryMu.Unlock()
		fail()
		return
	}
	if c.Send(workshop.Frame{Kind: "welcome", Protocol: workshop.Protocol, ComputerID: configured.ID}) != nil {
		s.registryMu.Unlock()
		return
	}
	old := s.workshopHub.Register(configured.ID, c)
	s.registryMu.Unlock()
	if old != nil {
		old.Close()
	}
	s.workshopHub.Run(configured.ID, c)
}

func workshopFailure(id, code, message string) workshop.Frame {
	return workshop.Frame{Kind: "failure", ID: id, Error: &workshop.Error{Code: code, Message: message}}
}

func (s *Server) workshopComputers() any {
	items := []map[string]any{}
	for _, entry := range s.registry.Load().Agents {
		c, _ := s.workshopHub.Lookup(entry.ID)
		online := c != nil
		if online {
			select {
			case <-c.Done():
				online = false
			default:
			}
		}
		items = append(items, map[string]any{"id": entry.ID, "name": entry.Name, "online": online, "protocolVersion": 1})
	}
	return map[string]any{"computers": items}
}

func (s *Server) workshopCall(ctx context.Context, request workshop.Frame) workshop.Frame {
	id := request.ID
	if request.Kind != "call" || !identifier.MatchString(id) || len(request.Params) > 16*1024 || !json.Valid(request.Params) || len(request.Params) == 0 || request.Params[0] != '{' {
		return workshopFailure(id, "invalid_request", "无效的代码工坊请求。")
	}
	if request.Method == "computers.list" {
		data, _ := json.Marshal(s.workshopComputers())
		return workshop.Frame{Kind: "result", ID: id, Result: data}
	}
	if !workshop.ValidMethod(request.Method) {
		return workshopFailure(id, "unsupported_method", "代码工坊不支持此操作。")
	}
	if !identifier.MatchString(request.ComputerID) {
		return workshopFailure(id, "invalid_request", "无效的执行电脑。")
	}
	c, _ := s.workshopHub.Lookup(request.ComputerID)
	if c == nil {
		return workshopFailure(id, "computer_offline", "执行电脑未连接代码工坊。")
	}
	select {
	case s.workshopRequests <- struct{}{}:
		defer func() { <-s.workshopRequests }()
	default:
		return workshopFailure(id, "workshop_busy", "代码工坊请求已满。")
	}
	ctx, cancel := context.WithTimeout(ctx, s.config.RequestTimeout)
	defer cancel()
	result, err := c.Call(ctx, request)
	if err != nil {
		code := "workshop_disconnected"
		if errors.Is(err, workshop.ErrBusy) {
			code = "workshop_busy"
		} else if errors.Is(err, context.DeadlineExceeded) {
			code = "workshop_timeout"
		}
		return workshopFailure(id, code, "代码工坊暂时无法响应，请核对任务结果后重试。")
	}
	result.ID = id
	return result
}

func (s *Server) workshopClientSocket(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Origin") != "" {
		reject(w, 403, "origin_not_allowed")
		return
	}
	sessionID, ok := s.authorized(w, r)
	if !ok {
		return
	}
	if !s.allow("workshop-client:"+sessionID, 30, time.Minute) {
		reject(w, 429, "rate_limited")
		return
	}
	u := websocket.Upgrader{HandshakeTimeout: 5 * time.Second}
	ws, err := u.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer ws.Close()
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	tokenDigest := digest(strings.TrimPrefix(r.Header.Get("Authorization"), "DPoP "))
	valid := func() bool {
		active := false
		s.store.inspect(func(st state) {
			ss := st.Sessions[sessionID]
			active = ss != nil && ss.Access[tokenDigest] > time.Now().Unix() && trustedConsoleState(&st, ss.Thumb)
		})
		return active
	}
	write := func(value any) bool {
		_ = ws.SetWriteDeadline(time.Now().Add(5 * time.Second))
		return ws.WriteJSON(value) == nil
	}
	if !valid() || !write(workshop.Frame{Kind: "welcome", Protocol: workshop.Protocol}) {
		return
	}
	commands := make(chan workshop.Frame, 16)
	ws.SetReadLimit(17 * 1024)
	_ = ws.SetReadDeadline(time.Now().Add(45 * time.Second))
	ws.SetPongHandler(func(string) error { return ws.SetReadDeadline(time.Now().Add(45 * time.Second)) })
	stream := r.PathValue("computerID") != ""
	go func() {
		defer cancel()
		for {
			kind, data, err := ws.ReadMessage()
			if err != nil || stream || kind != websocket.TextMessage {
				return
			}
			var frame workshop.Frame
			if !decodeJSON(strings.NewReader(string(data)), &frame) {
				return
			}
			select {
			case commands <- frame:
			case <-ctx.Done():
				return
			default:
				return
			}
		}
	}()
	heartbeat := time.NewTicker(15 * time.Second)
	defer heartbeat.Stop()
	ping := func() bool {
		return valid() && ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second)) == nil
	}
	if stream {
		s.workshopEvents(ctx, r, heartbeat.C, ping, valid, write)
		return
	}
	replies := make(chan workshop.Frame, 16)
	inFlight := 0
	for {
		select {
		case <-ctx.Done():
			return
		case <-heartbeat.C:
			if !ping() {
				return
			}
		case command := <-commands:
			if !valid() {
				return
			}
			if inFlight >= 16 || !s.allow("workshop-api", 600, time.Minute) {
				if !write(workshopFailure(command.ID, "workshop_busy", "代码工坊请求已满。")) {
					return
				}
				continue
			}
			inFlight++
			go func() {
				reply := s.workshopCall(ctx, command)
				select {
				case replies <- reply:
				case <-ctx.Done():
				}
			}()
		case reply := <-replies:
			inFlight--
			if !valid() || !write(reply) {
				return
			}
		}
	}
}

func (s *Server) workshopEvents(ctx context.Context, r *http.Request, heartbeat <-chan time.Time, ping, valid func() bool, write func(any) bool) {
	fail := func(code, message string) {
		if ctx.Err() == nil && valid() {
			write(workshopFailure("", code, message))
		}
	}
	operation := r.PathValue("operationID")
	cursor, err := strconv.ParseInt(r.PathValue("cursor"), 10, 64)
	if err != nil || cursor < 0 || !workshopOperationID.MatchString(operation) {
		fail("invalid_request", "无效的代码工坊事件游标。")
		return
	}
	c, _ := s.workshopHub.Lookup(r.PathValue("computerID"))
	if c == nil {
		fail("computer_offline", "执行电脑未连接代码工坊。")
		return
	}
	sub, err := c.Subscribe(operation, cursor)
	if err != nil {
		fail("workshop_busy", "代码工坊订阅已满。")
		return
	}
	defer c.Unsubscribe(sub)
	for {
		select {
		case <-ctx.Done():
			return
		case <-c.Done():
			fail("workshop_disconnected", "代码工坊连接已中断。")
			return
		case <-sub.Overflow:
			fail("stream_overflow", "代码工坊事件积压，请重新连接。")
			return
		case <-heartbeat:
			if !ping() {
				return
			}
		case frame := <-sub.Updates:
			frame.ID = ""
			if !valid() || !write(frame) || frame.Error != nil {
				return
			}
		}
	}
}
