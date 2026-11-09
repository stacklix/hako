package notify

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/ecdsa"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const wechatBase = "https://ilinkai.weixin.qq.com"

type providerError struct {
	message  string
	definite bool
	code     int
}

func (e *providerError) Error() string { return e.message }

func noRedirectClient() *http.Client {
	return &http.Client{
		Transport:     http.DefaultTransport.(*http.Transport).Clone(),
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

type wechatClient struct{ http *http.Client }
type credentials struct{ token, base string }

func newWechatClient() wechatClient { return wechatClient{noRedirectClient()} }
func validatedHost(value, suffix string) (*url.URL, error) {
	if !strings.Contains(value, "://") {
		value = "https://" + value
	}
	u, err := url.Parse(value)
	if err != nil || u.Scheme != "https" || u.User != nil || !strings.HasSuffix(strings.ToLower(u.Hostname()), suffix) || (u.Port() != "" && u.Port() != "443") {
		return nil, &providerError{message: "微信返回了不受支持的服务地址", definite: true}
	}
	return u, nil
}
func validatedBase(value string) (string, error) {
	u, err := validatedHost(value, ".weixin.qq.com")
	if err != nil {
		return "", err
	}
	return "https://" + u.Host, nil
}
func body(extra object) object {
	extra["base_info"] = object{"channel_version": "2.4.10", "bot_agent": "iLinker/0.1.0"}
	return extra
}

var windowTime = regexp.MustCompile("(?i)24\\s*(小时|hours?\\b|h\\b)")
var windowReason = regexp.MustCompile("(?i)未收到|未回复|没有收到|超[过时]|过期|expired|exceed|outside|no\\s+(message|reply)|not\\s+(received|replied)")

func (c wechatClient) call(ctx context.Context, base, path string, payload any, token string, timeout time.Duration, result any) error {
	origin, err := validatedBase(base)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	method := http.MethodGet
	var input io.Reader
	if payload != nil {
		data, err := json.Marshal(payload)
		if err != nil {
			return err
		}
		input = bytes.NewReader(data)
		method = http.MethodPost
	}
	req, err := http.NewRequestWithContext(ctx, method, origin+path, input)
	if err != nil {
		return err
	}
	req.Header.Set("iLink-App-Id", "bot")
	req.Header.Set("iLink-App-ClientVersion", strconv.Itoa(2<<16|4<<8|10))
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("AuthorizationType", "ilink_bot_token")
		uin := strconv.FormatUint(uint64(binary.BigEndian.Uint32(random(4))), 10)
		req.Header.Set("X-WECHAT-UIN", base64.StdEncoding.EncodeToString([]byte(uin)))
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return &providerError{message: "微信请求超时或网络不可用；若为发送请求，结果待确认"}
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return &providerError{message: fmt.Sprintf("微信服务返回 HTTP %d", resp.StatusCode), definite: resp.StatusCode < 500}
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 16*1024*1024+1))
	var envelope struct {
		Ret, ErrCode int
		Message      string `json:"errmsg"`
	}
	if err != nil || len(data) > 16*1024*1024 || json.Unmarshal(data, &envelope) != nil {
		return &providerError{message: "微信服务响应格式异常，结果待确认"}
	}
	code := envelope.Ret
	if code == 0 {
		code = envelope.ErrCode
	}
	if code != 0 {
		message := fmt.Sprintf("微信服务拒绝请求（错误码 %d）", code)
		if code == -14 {
			message = "微信授权已失效，请重新扫码登录"
		} else if path == "/ilink/bot/sendmessage" && windowTime.MatchString(envelope.Message) && windowReason.MatchString(envelope.Message) {
			message = windowMessage
		}
		return &providerError{message: message, definite: true, code: code}
	}
	if result != nil && json.Unmarshal(data, result) != nil {
		return &providerError{message: "微信服务响应格式异常，结果待确认"}
	}
	return nil
}

type loginQR struct {
	QR      string `json:"qrcode"`
	Content string `json:"qrcode_img_content"`
}
type loginResult struct {
	Status   string `json:"status"`
	Token    string `json:"bot_token"`
	Account  string `json:"ilink_bot_id"`
	Peer     string `json:"ilink_user_id"`
	Base     string `json:"baseurl"`
	Redirect string `json:"redirect_host"`
}
type incomingItem struct {
	Type int `json:"type"`
	Text struct {
		Text string `json:"text"`
	} `json:"text_item"`
	Voice struct {
		Text string `json:"text"`
	} `json:"voice_item"`
	File struct {
		Name string `json:"file_name"`
	} `json:"file_item"`
}
type incoming struct {
	ID          json.RawMessage `json:"message_id"`
	AlternateID json.RawMessage `json:"msg_id"`
	ClientID    string          `json:"client_id"`
	Peer        string          `json:"from_user_id"`
	Context     string          `json:"context_token"`
	Type        *int            `json:"message_type"`
	Time        int64           `json:"create_time_ms"`
	Items       []incomingItem  `json:"item_list"`
}
type wechatUpdates struct {
	Messages []incoming `json:"msgs"`
	Cursor   string     `json:"get_updates_buf"`
}

func (c wechatClient) createLogin(ctx context.Context, tokens []string) (result loginQR, err error) {
	err = c.call(ctx, wechatBase, "/ilink/bot/get_bot_qrcode?bot_type=3", object{"local_token_list": tokens}, "", 45*time.Second, &result)
	return
}
func (c wechatClient) pollLogin(ctx context.Context, base, qr, code string) (result loginResult, err error) {
	q := url.Values{"qrcode": {qr}}
	if code != "" {
		q.Set("verify_code", code)
	}
	err = c.call(ctx, base, "/ilink/bot/get_qrcode_status?"+q.Encode(), nil, "", 38*time.Second, &result)
	return
}
func (c wechatClient) updates(ctx context.Context, cred credentials, cursor string) (result wechatUpdates, err error) {
	err = c.call(ctx, cred.base, "/ilink/bot/getupdates", body(object{"get_updates_buf": cursor}), cred.token, 45*time.Second, &result)
	return
}
func (c wechatClient) presence(ctx context.Context, cred credentials, start bool) {
	path := "/ilink/bot/msg/notifystop"
	if start {
		path = "/ilink/bot/msg/notifystart"
	}
	_ = c.call(ctx, cred.base, path, body(object{}), cred.token, 5*time.Second, nil)
}
func (c wechatClient) send(ctx context.Context, cred credentials, peer, conversation, clientID string, item object) error {
	return c.call(ctx, cred.base, "/ilink/bot/sendmessage", body(object{"msg": object{
		"from_user_id": "", "to_user_id": peer, "client_id": clientID, "message_type": 2, "message_state": 2,
		"context_token": conversation, "item_list": []object{item},
	}}), cred.token, 30*time.Second, nil)
}
func (c wechatClient) imageItem(ctx context.Context, cred credentials, peer string, image []byte) (object, error) {
	key, filekey := random(16), hex.EncodeToString(random(16))
	keyHex := hex.EncodeToString(key)
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	pad := block.BlockSize() - len(image)%block.BlockSize()
	data := append(append([]byte{}, image...), bytes.Repeat([]byte{byte(pad)}, pad)...)
	for i := 0; i < len(data); i += block.BlockSize() {
		block.Encrypt(data[i:i+block.BlockSize()], data[i:i+block.BlockSize()])
	}
	digest := md5.Sum(image)
	var upload struct {
		URL   string `json:"upload_full_url"`
		Param string `json:"upload_param"`
	}
	err = c.call(ctx, cred.base, "/ilink/bot/getuploadurl", body(object{
		"filekey": filekey, "media_type": 1, "to_user_id": peer, "rawsize": len(image), "rawfilemd5": hex.EncodeToString(digest[:]),
		"filesize": len(data), "no_need_thumb": true, "aeskey": keyHex,
	}), cred.token, 30*time.Second, &upload)
	if err != nil {
		return nil, err
	}
	address := strings.TrimSpace(upload.URL)
	if address == "" && upload.Param != "" {
		address = "https://novac2c.cdn.weixin.qq.com/c2c/upload?" + url.Values{"encrypted_query_param": {upload.Param}, "filekey": {filekey}}.Encode()
	}
	if !strings.HasPrefix(address, "https://") {
		return nil, errors.New("invalid image upload URL")
	}
	u, err := validatedHost(address, ".cdn.weixin.qq.com")
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.String(), bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/octet-stream")
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, &providerError{message: "微信图片上传失败或中断，尚未提交图片消息", definite: true}
	}
	defer resp.Body.Close()
	param := resp.Header.Get("x-encrypted-param")
	if resp.StatusCode != 200 || param == "" {
		return nil, &providerError{message: "微信图片上传失败，尚未提交图片消息", definite: true}
	}
	return object{"type": 2, "image_item": object{"media": object{
		"encrypt_query_param": param, "aes_key": base64.StdEncoding.EncodeToString([]byte(keyHex)), "encrypt_type": 1,
	}, "mid_size": len(data)}}, nil
}

type apnsClient struct {
	http                 *http.Client
	key                  *ecdsa.PrivateKey
	keyID, teamID, topic string
	mu                   sync.Mutex
	jwt                  string
	issued               time.Time
}

var appleID = regexp.MustCompile("^[A-Z0-9]{10}$")
var bundleID = regexp.MustCompile("^[A-Za-z0-9.-]+$")
var apnsReason = regexp.MustCompile("^[A-Za-z0-9]{1,64}$")

func loadAPNs() (*apnsClient, error) {
	team, kid, topic, path := os.Getenv("APNS_TEAM_ID"), os.Getenv("APNS_KEY_ID"), os.Getenv("APNS_BUNDLE_ID"), os.Getenv("APNS_KEY_FILE")
	if team == "" && kid == "" && topic == "" && path == "" {
		return nil, nil
	}
	if !appleID.MatchString(team) || !appleID.MatchString(kid) || !bundleID.MatchString(topic) || path == "" {
		return nil, errors.New("invalid APNs configuration")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, errors.New("cannot read APNs key file")
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("invalid APNs key file")
	}
	value, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	key, ok := value.(*ecdsa.PrivateKey)
	if err != nil || !ok || key.Params().Name != "P-256" {
		return nil, errors.New("APNs requires an Apple P-256 private key")
	}
	return &apnsClient{http: noRedirectClient(), key: key, keyID: kid, teamID: team, topic: topic}, nil
}
func (c *apnsClient) authorization() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := time.Now()
	if c.jwt != "" && now.Sub(c.issued) < 45*time.Minute {
		return c.jwt, nil
	}
	b64 := func(v object) string { data, _ := json.Marshal(v); return base64.RawURLEncoding.EncodeToString(data) }
	claims := b64(object{"alg": "ES256", "kid": c.keyID}) + "." + b64(object{"iss": c.teamID, "iat": now.Unix()})
	digest := sha256.Sum256([]byte(claims))
	r, s, err := ecdsa.Sign(rand.Reader, c.key, digest[:])
	if err != nil {
		return "", err
	}
	raw := make([]byte, 64)
	r.FillBytes(raw[:32])
	s.FillBytes(raw[32:])
	c.jwt = "bearer " + claims + "." + base64.RawURLEncoding.EncodeToString(raw)
	c.issued = now
	return c.jwt, nil
}

type apnsResponse struct {
	status    int
	Reason    string `json:"reason"`
	Timestamp int64  `json:"timestamp"`
}

func (c *apnsClient) send(ctx context.Context, id, environment, token, payload string, expires int64) (apnsResponse, error) {
	host := "api.push.apple.com"
	if environment == "sandbox" {
		host = "api.sandbox.push.apple.com"
	}
	auth, err := c.authorization()
	if err != nil {
		return apnsResponse{}, err
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://"+host+"/3/device/"+token, strings.NewReader(payload))
	if err != nil {
		return apnsResponse{}, err
	}
	req.Header.Set("Authorization", auth)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("apns-topic", c.topic)
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-id", id)
	req.Header.Set("apns-expiration", strconv.FormatInt(expires/1000, 10))
	resp, err := c.http.Do(req)
	if err != nil {
		return apnsResponse{}, err
	}
	defer resp.Body.Close()
	if resp.ProtoMajor != 2 {
		return apnsResponse{}, errors.New("APNs requires HTTP/2")
	}
	result := apnsResponse{status: resp.StatusCode}
	_ = json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&result)
	return result, nil
}

func deliveryID() string {
	b := random(16)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
}
