package notify

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"strings"
	"testing"
	"time"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestGoGatewayRoutesChannelsIndependentlyAndReplays(t *testing.T) {
	console := strings.Repeat("C", 43)
	s, err := New(Config{DataDir: t.TempDir(), TrustedConsoles: []string{console}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	received := make(chan map[string]any, 4)
	apple := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ProtoMajor != 2 || r.URL.Path != "/3/device/abcd" || r.Header.Get("apns-topic") != "me.stackli.hako" ||
			r.Header.Get("apns-push-type") != "alert" || !strings.HasPrefix(r.Header.Get("Authorization"), "bearer ") {
			http.Error(w, "unexpected Apple request", 400)
			return
		}
		var payload map[string]any
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			http.Error(w, "bad payload", 400)
			return
		}
		received <- payload
		w.WriteHeader(200)
	}))
	apple.EnableHTTP2 = true
	apple.StartTLS()
	t.Cleanup(apple.Close)
	target, _ := url.Parse(apple.URL)
	transport := apple.Client().Transport
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		copy := r.Clone(r.Context())
		copy.URL.Host = target.Host
		return transport.RoundTrip(copy)
	})}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	s.apns = &apnsClient{http: client, key: key, keyID: "KEY0000001", teamID: "TEAM000001", topic: "me.stackli.hako"}
	s.mu.Unlock()

	call := func(method, path, body string, status int) object {
		t.Helper()
		request := httptest.NewRequest(method, path, strings.NewReader(body))
		reply := httptest.NewRecorder()
		s.ServeAdmin(reply, request)
		if reply.Code != status {
			t.Fatalf("%s %s: %d %s", method, path, reply.Code, reply.Body.String())
		}
		var payload object
		if err := json.Unmarshal(reply.Body.Bytes(), &payload); err != nil {
			t.Fatal(err)
		}
		return payload
	}
	bot := call("POST", "/bots", `{"name":"测试机器人"}`, 201)
	botID := str(bot, "id")
	now := nowMS()
	if err := transact(s.db, func(tx *sql.Tx) error {
		if err := exec(tx, "UPDATE bots SET credentials=?,base_url=?,account_id=?,peer_id=?,status='online',enabled=1 WHERE id=?", s.vault.seal("fake"), wechatBase, "test-account", "test-user", botID); err != nil {
			return err
		}
		bot, err := botByID(tx, botID)
		if err != nil {
			return err
		}
		return s.ingest(tx, bot, incoming{ID: json.RawMessage("900719925474099312345"), Peer: "test-user", Context: "test-context", Time: now - windowMS - 10, Items: []incomingItem{{Type: 1}}})
	}); err != nil {
		t.Fatal(err)
	}
	call("POST", "/bots", `{"name":"未绑定的旧配置"}`, 201)
	channel := call("PUT", "/channels/wechat", `{}`, 200)
	connection, _ := channel["connection"].(map[string]any)
	if connection["id"] != botID || connection["hasCredentials"] != true {
		t.Fatalf("channel did not reuse the bound connection: %v", connection)
	}
	registration := httptest.NewRequest("PUT", "/device", strings.NewReader(`{"token":"abcd","environment":"production"}`))
	response := httptest.NewRecorder()
	s.RegisterDevice(response, registration, console)
	if response.Code != 204 {
		t.Fatalf("register: %d %s", response.Code, response.Body.String())
	}
	if stored, err := currentDevice(s.db); err != nil || str(stored, "token") == "abcd" {
		t.Fatal("push token was not encrypted")
	}

	hook := call("POST", "/webhooks", `{"name":"双渠道","botId":"`+botID+`","apnsEnabled":true,"defaultChannels":["wechat","apns"]}`, 201)
	hookID := str(hook["webhook"].(map[string]any), "id")
	send := func(payload, key string, status int) object {
		t.Helper()
		request := httptest.NewRequest("POST", str(hook, "path"), strings.NewReader(payload))
		request.SetPathValue("token", str(hook, "token"))
		if key != "" {
			request.Header.Set("Idempotency-Key", key)
		}
		reply := httptest.NewRecorder()
		s.Submit(reply, request, "test")
		if reply.Code != status {
			t.Fatalf("submit: %d %s", reply.Code, reply.Body.String())
		}
		var payloadJSON object
		if err := json.Unmarshal(reply.Body.Bytes(), &payloadJSON); err != nil {
			t.Fatal(err)
		}
		return payloadJSON
	}
	input := `{"message":{"type":"text","text":"测试通知"}}`
	first := send(input, "event", 202)
	id := str(first, "notificationId")
	list := first["deliveries"].([]any)
	if len(list) != 2 || list[0].(map[string]any)["code"] != windowCode {
		t.Fatalf("missing WeChat failure: %v", list)
	}
	select {
	case payload := <-received:
		if payload["notificationId"] != id {
			t.Fatal("unexpected notification payload")
		}
	case <-time.After(8 * time.Second):
		t.Fatal("Apple channel did not submit independently")
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		data, err := result(s.db, hookID, id)
		if err != nil {
			t.Fatal(err)
		}
		if str(data, "status") == "partial_failure" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("unexpected final status: %v", data)
		}
		time.Sleep(20 * time.Millisecond)
	}
	call("PATCH", "/webhooks/"+hookID, `{"defaultChannels":["apns"]}`, 200)
	if replay := send(input, "event", 202); str(replay, "notificationId") != id {
		t.Fatal("replay selected current defaults")
	}
	send(`{"channels":["apns"],"message":{"text":"测试通知"}}`, "event", 409)
	send(`{"channels":[],"message":{"text":"测试通知"}}`, "", 400)
	send(`{"message":{"type":"image","image":{"url":"https://example.com/picture.png"}}}`, "", 422)
	select {
	case <-received:
		t.Fatal("replay was sent again")
	default:
	}
}

func TestWeChatRequestPreservesProtocolAndMessageIDs(t *testing.T) {
	client := wechatClient{http: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "ilinkai.weixin.qq.com" || r.URL.Path != "/ilink/bot/getupdates" || r.Method != "POST" ||
			r.Header.Get("Authorization") != "Bearer test" || r.Header.Get("AuthorizationType") != "ilink_bot_token" ||
			r.Header.Get("iLink-App-ClientVersion") != "132106" || r.Header.Get("X-WECHAT-UIN") == "" {
			t.Fatalf("unexpected provider request: %v", r.URL)
		}
		content := `{"msgs":[{"message_id":900719925474099312345,"from_user_id":"user","message_type":1}],"get_updates_buf":"next"}`
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(content)), Header: make(http.Header)}, nil
	})}}
	updates, err := client.updates(context.Background(), credentials{"test", wechatBase}, "cursor")
	if err != nil || updates.Cursor != "next" || len(updates.Messages) != 1 || messageKey(updates.Messages[0]) != "900719925474099312345" {
		t.Fatalf("provider update not preserved: %v %v", updates, err)
	}
	if _, err := validatedBase("https://ilinkai.weixin.qq.com.attacker.example"); err == nil {
		t.Fatal("accepted an untrusted WeChat host")
	}
	for _, address := range []string{"127.0.0.1", "169.254.169.254", "::ffff:127.0.0.1", "fd00::1", "100.64.0.1"} {
		if publicIP(netip.MustParseAddr(address)) {
			t.Fatalf("accepted private image address: %s", address)
		}
	}
}

func TestGoWeChatLoginAndImageDelivery(t *testing.T) {
	s, err := New(Config{DataDir: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	sent := make(chan object, 1)
	stamp := nowMS()
	s.mu.Lock()
	s.wechat.http = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		value := `{"ret":0}`
		headers := make(http.Header)
		switch r.URL.Path {
		case "/ilink/bot/get_bot_qrcode":
			value = `{"qrcode":"fake-id","qrcode_img_content":"https://weixin.qq.com/qr"}`
		case "/ilink/bot/get_qrcode_status":
			value = `{"status":"need_verifycode"}`
			if r.URL.Query().Get("verify_code") == "123456" {
				value = `{"status":"confirmed","bot_token":"wechat-test","ilink_bot_id":"account","ilink_user_id":"peer","baseurl":"https://ilinkai.weixin.qq.com"}`
			}
		case "/ilink/bot/getupdates":
			msg := object{"message_id": "event-1", "from_user_id": "peer", "message_type": 1, "context_token": "context",
				"create_time_ms": stamp, "item_list": []object{{"type": 1, "text_item": object{"text": "hi"}}}}
			data, _ := json.Marshal(object{"msgs": []object{msg}, "get_updates_buf": "cursor"})
			value = string(data)
		case "/ilink/bot/getuploadurl":
			value = `{"upload_full_url":"https://novac2c.cdn.weixin.qq.com/c2c/upload"}`
		case "/c2c/upload":
			data, err := io.ReadAll(r.Body)
			if err != nil || len(data) == 0 || len(data)%16 != 0 || r.Header.Get("Content-Type") != "application/octet-stream" {
				return &http.Response{StatusCode: 400, Header: headers, Body: io.NopCloser(strings.NewReader("{}"))}, nil
			}
			headers.Set("x-encrypted-param", "download-param")
		case "/ilink/bot/sendmessage":
			var msg object
			_ = json.NewDecoder(r.Body).Decode(&msg)
			sent <- msg
		}
		return &http.Response{StatusCode: 200, Header: headers, Body: io.NopCloser(strings.NewReader(value))}, nil
	})}
	s.mu.Unlock()
	call := func(method, path, body string, status int) object {
		t.Helper()
		request := httptest.NewRequest(method, path, strings.NewReader(body))
		reply := httptest.NewRecorder()
		s.ServeAdmin(reply, request)
		if reply.Code != status {
			t.Fatalf("%s %s: %d %s", method, path, reply.Code, reply.Body.String())
		}
		var payload object
		if err := json.Unmarshal(reply.Body.Bytes(), &payload); err != nil {
			t.Fatal(err)
		}
		return payload
	}
	wait := func(check func() bool) {
		t.Helper()
		deadline := time.Now().Add(8 * time.Second)
		for !check() {
			if time.Now().After(deadline) {
				t.Fatal("timed out waiting for WeChat state")
			}
			time.Sleep(25 * time.Millisecond)
		}
	}
	bot := call("POST", "/bots", `{"name":"微信机器人"}`, 201)
	botPath := "/bots/" + str(bot, "id")
	login := call("POST", botPath+"/login-sessions", `{}`, 201)
	if !strings.HasPrefix(str(login, "qrImage"), "data:image/png;base64,") {
		t.Fatal("missing scan image")
	}
	loginPath := botPath + "/login-sessions/" + str(login, "id")
	wait(func() bool { return str(call("GET", loginPath, "", 200), "status") == "need_verifycode" })
	call("POST", loginPath+"/verify", `{"code":"123456"}`, 200)
	wait(func() bool { return call("GET", botPath+"/conversation", "", 200)["hasContext"] == true })
	if state := call("GET", botPath+"/conversation", "", 200); state["unread"] != float64(1) {
		t.Fatal("duplicate inbound message")
	}
	hook := call("POST", "/webhooks", `{"name":"图片","botId":"`+str(bot, "id")+`","apnsEnabled":false,"defaultChannels":["wechat"]}`, 201)
	hookID := str(hook["webhook"].(map[string]any), "id")
	payload := `{"message":{"type":"image","image":{"base64":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a8x8AAAAASUVORK5CYII="}}}`
	notification := call("POST", "/webhooks/"+hookID+"/test", payload, 202)
	select {
	case body := <-sent:
		msg := body["msg"].(map[string]any)
		items := msg["item_list"].([]any)
		item := items[0].(map[string]any)
		image := item["image_item"].(map[string]any)
		media := image["media"].(map[string]any)
		if msg["context_token"] != "context" || msg["to_user_id"] != "peer" || item["type"] != float64(2) ||
			media["encrypt_query_param"] != "download-param" || media["aes_key"] == "" {
			t.Fatalf("unexpected image wire format: %v", item)
		}
	case <-time.After(8 * time.Second):
		t.Fatal("WeChat image was not sent")
	}
	wait(func() bool {
		status, err := result(s.db, hookID, str(notification, "notificationId"))
		return err == nil && str(status, "status") == "provider_accepted"
	})
}
