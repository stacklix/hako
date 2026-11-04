package server

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strings"
	"time"

	jose "github.com/go-jose/go-jose/v4"
	qrcode "github.com/skip2/go-qrcode"
)

type OIDCClient struct {
	Enabled      bool     `json:"enabled"`
	RedirectURIs []string `json:"redirectURIs"`
	Scopes       []string `json:"scopes"`
	RequirePKCE  bool     `json:"requirePKCE"`
	AuthMethod   string   `json:"authMethod"`
}

func validateOIDCClient(c *OIDCClient) error {
	if c == nil {
		return nil
	}
	if len(c.RedirectURIs) == 0 || len(c.RedirectURIs) > 16 || len(c.Scopes) == 0 || len(c.Scopes) > 2 || !slices.Contains(c.Scopes, "openid") || (c.AuthMethod != "client_secret_basic" && c.AuthMethod != "client_secret_post") {
		return fmt.Errorf("invalid OIDC configuration")
	}
	seen := map[string]bool{}
	for _, scope := range c.Scopes {
		if (scope != "openid" && scope != "profile") || seen[scope] {
			return fmt.Errorf("invalid OIDC scope")
		}
		seen[scope] = true
	}
	seen = map[string]bool{}
	for _, value := range c.RedirectURIs {
		u, err := url.Parse(value)
		if err != nil || len(value) > 2048 || u.Hostname() == "" || u.User != nil || strings.ContainsAny(u.Host, "'\";<>") || u.Fragment != "" || strings.ContainsAny(value, "#\\*\r\n\t ") || seen[value] {
			return fmt.Errorf("invalid OIDC redirect URI")
		}
		if !validApplicationOrigin(u.Scheme + "://" + u.Host) {
			return fmt.Errorf("invalid OIDC redirect origin")
		}
		if u.Scheme != "https" && !(u.Scheme == "http" && (u.Hostname() == "localhost" || net.ParseIP(u.Hostname()).IsLoopback())) {
			return fmt.Errorf("OIDC requires HTTPS except loopback")
		}
		q, e := url.ParseQuery(u.RawQuery)
		if e != nil {
			return e
		}
		for _, key := range []string{"code", "state", "error", "error_description", "iss"} {
			if _, ok := q[key]; ok {
				return fmt.Errorf("reserved redirect query")
			}
		}
		seen[value] = true
	}
	return nil
}

// HTTP callbacks are development-only, with an HTTP loopback issuer as well.
func (s *Server) validateOIDCRegistration(c *OIDCClient) error {
	if err := validateOIDCClient(c); err != nil {
		return err
	}
	if c != nil && strings.HasPrefix(s.config.PublicURL, "https:") {
		for _, value := range c.RedirectURIs {
			if !strings.HasPrefix(value, "https://") {
				return fmt.Errorf("HTTPS issuer requires HTTPS callbacks")
			}
		}
	}
	return nil
}
func oidcConfiguration(c AuthClientConfig) string {
	if c.OIDC == nil {
		return ""
	}
	return "OIDC_REDIRECT_URIS=" + strings.Join(c.OIDC.RedirectURIs, ",") + "\nOIDC_SCOPES=" + strings.Join(c.OIDC.Scopes, " ") + "\nOIDC_AUTH_METHOD=" + c.OIDC.AuthMethod + "\n"
}

type oidcAuthorization struct{ ClientID, Revision, Redirect, Scope, State, Nonce, Challenge string }
type oidcGrant struct {
	Auth                         oidcAuthorization
	Approver, Thumb, ID, Browser string
	Created, Expires             time.Time
}
type oidcProvider struct {
	signer        jose.Signer
	jwk           jose.JSONWebKey
	codes, access map[string]oidcGrant
}

func oidcScopes(r *adminLoginRequest) string {
	if r.OIDC == nil {
		return ""
	}
	return r.OIDC.Scope
}
func (s *Server) initOIDC() error {
	var key *rsa.PrivateKey
	err := s.store.update(func(st *state) error {
		if st.OIDCKey == "" {
			k, e := rsa.GenerateKey(rand.Reader, 2048)
			if e != nil {
				return e
			}
			b, e := x509.MarshalPKCS8PrivateKey(k)
			if e != nil {
				return e
			}
			st.OIDCKey = raw64.EncodeToString(b)
		}
		b, e := raw64.DecodeString(st.OIDCKey)
		if e != nil {
			return e
		}
		k, e := x509.ParsePKCS8PrivateKey(b)
		if e != nil {
			return e
		}
		var ok bool
		key, ok = k.(*rsa.PrivateKey)
		if !ok || key.N.BitLen() < 2048 {
			return fmt.Errorf("invalid OIDC signing key")
		}
		return nil
	})
	if err != nil {
		return err
	}
	jwk := jose.JSONWebKey{Key: &key.PublicKey, Use: "sig", Algorithm: "RS256"}
	b, _ := x509.MarshalPKIXPublicKey(&key.PublicKey)
	jwk.KeyID = digest(string(b))
	signer, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: key}, (&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", jwk.KeyID))
	if err != nil {
		return err
	}
	s.oidc = &oidcProvider{signer: signer, jwk: jwk, codes: map[string]oidcGrant{}, access: map[string]oidcGrant{}}
	s.mux.HandleFunc("GET /.well-known/openid-configuration", s.oidcDiscovery)
	s.mux.HandleFunc("GET /oidc/jwks", func(w http.ResponseWriter, r *http.Request) {
		respond(w, 200, jose.JSONWebKeySet{Keys: []jose.JSONWebKey{s.oidc.jwk}})
	})
	s.mux.HandleFunc("GET /oidc/authorize", s.oidcAuthorize)
	s.mux.HandleFunc("GET /api/v1/auth/oidc/requests", s.pendingLoginPrompts)
	s.mux.HandleFunc("POST /api/v1/auth/oidc/requests/{id}/approve", s.approveAdminLogin)
	s.mux.HandleFunc("POST /api/v1/auth/oidc/requests/{id}/deny", s.approveAdminLogin)
	s.mux.HandleFunc("GET /oidc/consent.js", func(w http.ResponseWriter, r *http.Request) {
		b, _ := adminFiles.ReadFile("web/oidc.js")
		w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
		_, _ = w.Write(b)
	})
	s.mux.HandleFunc("GET /oidc/consent.css", func(w http.ResponseWriter, r *http.Request) {
		b, _ := adminFiles.ReadFile("web/oidc.css")
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
		_, _ = w.Write(b)
	})
	s.mux.HandleFunc("GET /oidc/requests/{id}/status", s.oidcStatus)
	s.mux.HandleFunc("GET /oidc/requests/{id}", s.oidcPage)
	s.mux.HandleFunc("GET /oidc/requests/{id}/qr", s.oidcQR)
	s.mux.HandleFunc("POST /oidc/requests/{id}/complete", s.oidcComplete)
	s.mux.HandleFunc("POST /oidc/token", s.oidcToken)
	s.mux.HandleFunc("GET /oidc/userinfo", s.oidcUserInfo)
	s.mux.HandleFunc("POST /oidc/userinfo", s.oidcUserInfo)
	return nil
}
func (s *Server) oidcDiscovery(w http.ResponseWriter, r *http.Request) {
	p := s.config.PublicURL
	respond(w, 200, map[string]any{"issuer": p, "authorization_endpoint": p + "/oidc/authorize", "token_endpoint": p + "/oidc/token", "userinfo_endpoint": p + "/oidc/userinfo", "jwks_uri": p + "/oidc/jwks", "response_types_supported": []string{"code"}, "response_modes_supported": []string{"query"}, "grant_types_supported": []string{"authorization_code"}, "subject_types_supported": []string{"public"}, "id_token_signing_alg_values_supported": []string{"RS256"}, "scopes_supported": []string{"openid", "profile"}, "claims_supported": []string{"iss", "sub", "aud", "iat", "exp", "nonce", "name", "preferred_username"}, "token_endpoint_auth_methods_supported": []string{"client_secret_basic", "client_secret_post"}, "code_challenge_methods_supported": []string{"S256"}})
}
func oidcParams(raw string, allowed string) (url.Values, error) {
	if len(raw) > 8192 {
		return nil, fmt.Errorf("oversized request")
	}
	v, e := url.ParseQuery(raw)
	if e != nil {
		return nil, e
	}
	for k, x := range v {
		if len(x) != 1 || len(x[0]) > 2048 || strings.ContainsAny(x[0], "\x00\r\n") || !slices.Contains(strings.Fields(allowed), k) {
			return nil, fmt.Errorf("invalid parameter")
		}
	}
	return v, nil
}
func oidcError(w http.ResponseWriter, status int, code string) {
	if status == http.StatusUnauthorized && code == "invalid_client" {
		w.Header().Set("WWW-Authenticate", `Basic realm="Hako OIDC"`)
	}
	respond(w, status, map[string]string{"error": code})
}
func (s *Server) oidcRedirect(w http.ResponseWriter, r *http.Request, a oidcAuthorization, key, value string) {
	u, _ := url.Parse(a.Redirect)
	// Chrome applies form-action to the final redirect too. Permit only this registered
	// callback origin; scripts, images and other subresources remain same-origin.
	w.Header().Set("Content-Security-Policy", "default-src 'none'; form-action 'self' "+u.Scheme+"://"+u.Host+"; base-uri 'none'; frame-ancestors 'none'")
	q := u.Query()
	q.Set(key, value)
	if a.State != "" {
		q.Set("state", a.State)
	}
	u.RawQuery = q.Encode()
	http.Redirect(w, r, u.String(), http.StatusSeeOther)
}

var pkceVerifier = regexp.MustCompile(`^[A-Za-z0-9._~-]{43,128}$`)

func (s *Server) oidcAuthorize(w http.ResponseWriter, r *http.Request) {
	if !s.allow("oidc-authorize:"+s.loginClientIP(r), 20, time.Minute) || !s.allow("oidc-authorize:global", 120, time.Minute) {
		oidcError(w, 429, "temporarily_unavailable")
		return
	}
	v, e := oidcParams(r.URL.RawQuery, "client_id redirect_uri response_type scope state nonce code_challenge code_challenge_method response_mode prompt")
	if e != nil {
		oidcError(w, 400, "invalid_request")
		return
	}
	c, ok := s.authClient(v.Get("client_id"))
	if !ok || c.OIDC == nil || !c.OIDC.Enabled || !slices.Contains(c.OIDC.RedirectURIs, v.Get("redirect_uri")) {
		oidcError(w, 400, "invalid_request")
		return
	}
	a := oidcAuthorization{ClientID: c.ID, Revision: c.Revision, Redirect: v.Get("redirect_uri"), Scope: v.Get("scope"), State: v.Get("state"), Nonce: v.Get("nonce"), Challenge: v.Get("code_challenge")}
	fail := func(code string) { s.oidcRedirect(w, r, a, "error", code) }
	if v.Get("response_type") != "code" {
		fail("unsupported_response_type")
		return
	}
	if v.Has("response_mode") && v.Get("response_mode") != "query" {
		fail("invalid_request")
		return
	}
	if v.Has("prompt") && v.Get("prompt") != "consent" && v.Get("prompt") != "login" {
		if v.Get("prompt") == "none" {
			fail("interaction_required")
		} else {
			fail("invalid_request")
		}
		return
	}
	scopes := strings.Split(a.Scope, " ")
	seen := map[string]bool{}
	for _, scope := range scopes {
		if !slices.Contains(c.OIDC.Scopes, scope) || seen[scope] {
			fail("invalid_scope")
			return
		}
		seen[scope] = true
	}
	if !seen["openid"] {
		fail("invalid_scope")
		return
	}
	if a.Challenge != "" {
		if !validLoginID(a.Challenge) || v.Get("code_challenge_method") != "S256" {
			fail("invalid_request")
			return
		}
	} else if c.OIDC.RequirePKCE || v.Has("code_challenge") || v.Has("code_challenge_method") {
		fail("invalid_request")
		return
	}
	if !s.hasAdminConsole() {
		fail("temporarily_unavailable")
		return
	}
	id, browser := randomToken(), randomToken()
	now := time.Now()
	codeBytes := make([]byte, 4)
	if _, e = rand.Read(codeBytes); e != nil {
		fail("temporarily_unavailable")
		return
	}
	code := fmt.Sprintf("%06d", (uint32(codeBytes[0])<<16|uint32(codeBytes[1])<<8|uint32(codeBytes[2]))%1000000)
	payload := "hako://web-login?" + url.Values{"v": {"3"}, "server": {s.config.PublicURL}, "request": {id}}.Encode()
	png, e := qrcode.Encode(payload, qrcode.Medium, -5)
	if e != nil {
		fail("temporarily_unavailable")
		return
	}
	s.adminMu.Lock()
	defer s.unlockAdminAndNotifyLoginPrompts()
	s.cleanupAdminLogins(now)
	s.cleanupOIDCLocked(now)
	if len(s.adminLogins) >= 256 {
		fail("temporarily_unavailable")
		return
	}
	// A new authorization supersedes the previous flow in this browser.
	if old, e := r.Cookie(s.oidcCookieName()); e == nil {
		for k, req := range s.adminLogins {
			if req.OIDC != nil && equal(req.BrowserHash, digest(old.Value)) {
				delete(s.adminLogins, k)
			}
		}
	}
	req := &adminLoginRequest{OIDC: &a, ClientID: c.ID, ClientName: c.Name, ClientOrigin: c.Origin, ClientKeyHash: c.SecretHash, Purpose: "oidc", BrowserHash: digest(browser), Code: code, Nonce: randomToken(), Browser: browserLabel(r.UserAgent()), ClientIP: s.loginClientIP(r), Status: "pending", Created: now, Expires: now.Add(adminLoginLifetime), QR: png}
	req.RequestID = id
	if !s.validApplicationRequest(req) {
		fail("temporarily_unavailable")
		return
	}
	s.adminLogins[digest(id)] = req
	http.SetCookie(w, &http.Cookie{Name: s.oidcCookieName(), Value: browser, Path: "/", HttpOnly: true, Secure: strings.HasPrefix(s.config.PublicURL, "https:"), SameSite: http.SameSiteLaxMode, MaxAge: 90})
	http.Redirect(w, r, "/oidc/requests/"+id, http.StatusSeeOther)
}
func (s *Server) oidcCookieName() string {
	if strings.HasPrefix(s.config.PublicURL, "https:") {
		return "__Host-hako_oidc"
	}
	return "hako_oidc"
}
func (s *Server) oidcBrowser(w http.ResponseWriter, r *http.Request) *adminLoginRequest {
	req := s.adminLogins[digest(r.PathValue("id"))]
	c, e := r.Cookie(s.oidcCookieName())
	if e != nil || !validLoginID(c.Value) || !validLoginID(r.PathValue("id")) || req == nil || req.OIDC == nil || !equal(req.BrowserHash, digest(c.Value)) {
		oidcError(w, 404, "invalid_request")
		return nil
	}
	return req
}

var oidcPageTemplate = template.Must(template.New("consent").Parse(`<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark"><title>使用 Hako 登录</title>
<link rel="icon" type="image/svg+xml" href="/admin/hako-logo.svg">
<link rel="stylesheet" href="/oidc/consent.css"><script src="/oidc/consent.js" defer></script></head>
<body><main class="auth-shell">
<div class="brand"><img src="/admin/hako-logo.svg" width="28" height="28" alt=""><span>hako<span class="brand-dot">.</span></span></div>
<section class="auth-card" aria-labelledby="auth-title">
<div class="auth-details">
<p class="eyebrow">账号授权</p><h1 id="auth-title">使用 Hako 登录</h1>
<p class="intro">即将登录到 <strong>{{.Name}}</strong></p>
<div class="app-identity"><span class="app-icon" aria-hidden="true">↗</span><div><h2>{{.Name}}</h2><p class="origin-label">登记来源</p><p class="origin">{{.Origin}}</p></div></div>
<section class="permissions" aria-labelledby="permissions-title"><h3 id="permissions-title">此应用将获取</h3>
<ul><li><span class="permission-check" aria-hidden="true">✓</span><div>账号标识<small>用于识别你的 Hako 账号</small></div></li>
{{if .Profile}}<li><span class="permission-check" aria-hidden="true">✓</span><div>账号名称<small>用于显示你的个人资料</small></div></li>{{end}}</ul><p class="scope-note">授权范围：{{.Scope}}</p></section>
<p class="privacy-note">请只批准你本人发起的登录。扫码或打开 Hako 后，仍需在手机上明确确认。</p>
</div>
<div class="auth-approval">
<h2>在手机上确认</h2><p class="scan-hint">打开 Hako，扫描下方二维码</p>
<div class="qr-frame"><img src="{{.QR}}" alt="使用 Hako 扫描授权二维码" width="224" height="224"></div>
<div class="confirmation"><span>核对确认码</span><strong>{{.Code}}</strong></div>
<div class="status-row" role="status" aria-live="polite" aria-atomic="true"><span class="status-dot" aria-hidden="true"></span><span id="status">{{.Status}}</span></div>
<p class="expiry" id="expiry" data-expires="{{.Expires}}">请求有效期 90 秒</p>
<a class="open-app" href="{{.DeepLink}}">在本机 Hako 中确认 <span aria-hidden="true">↗</span></a>
<p class="same-device-hint">正在用手机浏览？直接打开 Hako，无需扫码。</p>
</div></section>
<form method="post" action="{{.Complete}}" class="auth-actions"><input type="hidden" name="csrf" value="{{.CSRF}}">
<button name="action" value="continue" class="continue">已在手机确认，继续 <span aria-hidden="true">→</span></button>
<button name="action" value="cancel" class="cancel">取消登录</button></form>
<p class="footer-note">手机确认后将自动返回应用。同机确认后，请回到此浏览器继续。</p>
</main></body></html>`))

func (s *Server) oidcPage(w http.ResponseWriter, r *http.Request) {
	s.adminMu.Lock()
	defer s.unlockAdminAndNotifyLoginPrompts()
	req := s.oidcBrowser(w, r)
	if req == nil {
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	// no-referrer suppresses Origin on some native form POSTs. same-origin keeps
	// the strict Origin check usable while still sending no referrer to clients.
	w.Header().Set("Referrer-Policy", "same-origin")
	callback, _ := url.Parse(req.OIDC.Redirect)
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; form-action 'self' "+callback.Scheme+"://"+callback.Host+"; base-uri 'none'; frame-ancestors 'none'")
	id := r.PathValue("id")
	link := "hako://web-login?" + url.Values{"v": {"3"}, "server": {s.config.PublicURL}, "request": {id}}.Encode()
	status := map[string]string{"pending": "等待手机确认", "scanned": "请在 Hako 中核对并确认", "approved": "已确认，正在返回应用", "denied": "已拒绝此请求"}[req.Status]
	_ = oidcPageTemplate.Execute(w, map[string]any{"Name": req.ClientName, "Origin": req.ClientOrigin, "Scope": req.OIDC.Scope, "Profile": slices.Contains(strings.Fields(req.OIDC.Scope), "profile"), "Code": req.Code, "Status": status, "Expires": req.Expires.UnixMilli(), "QR": "/oidc/requests/" + id + "/qr", "DeepLink": template.URL(link), "Complete": "/oidc/requests/" + id + "/complete", "CSRF": req.Nonce})
}
func (s *Server) oidcStatus(w http.ResponseWriter, r *http.Request) {
	s.adminMu.Lock()
	defer s.unlockAdminAndNotifyLoginPrompts()
	req := s.oidcBrowser(w, r)
	if req == nil {
		return
	}
	if !s.allow("oidc-poll:"+digest(r.PathValue("id")), 60, time.Minute) {
		oidcError(w, 429, "temporarily_unavailable")
		return
	}
	if !time.Now().Before(req.Expires) || !s.validApplicationRequest(req) {
		oidcError(w, 410, "expired_request")
		return
	}
	if req.Status == "approved" && !s.validAdminApprover(req.ApproverSessionID, req.ApproverThumb) {
		req.Status = "denied"
	}
	respond(w, 200, map[string]string{"status": req.Status})
}
func (s *Server) oidcQR(w http.ResponseWriter, r *http.Request) {
	s.adminMu.Lock()
	defer s.unlockAdminAndNotifyLoginPrompts()
	req := s.oidcBrowser(w, r)
	if req == nil {
		return
	}
	w.Header().Set("Content-Type", "image/png")
	_, _ = w.Write(req.QR)
}
func (s *Server) oidcComplete(w http.ResponseWriter, r *http.Request) {
	adminHeaders(w)
	if r.Header.Get("Origin") != s.config.PublicURL || r.Header.Get("Sec-Fetch-Site") == "cross-site" || strings.Split(r.Header.Get("Content-Type"), ";")[0] != "application/x-www-form-urlencoded" {
		oidcError(w, 403, "invalid_request")
		return
	}
	raw, e := io.ReadAll(r.Body)
	if e != nil {
		oidcError(w, 400, "invalid_request")
		return
	}
	v, e := oidcParams(string(raw), "csrf action")
	if e != nil {
		oidcError(w, 400, "invalid_request")
		return
	}
	s.adminMu.Lock()
	defer s.unlockAdminAndNotifyLoginPrompts()
	req := s.oidcBrowser(w, r)
	if req == nil {
		return
	}
	if !equal(v.Get("csrf"), req.Nonce) || (v.Get("action") != "continue" && v.Get("action") != "cancel") {
		oidcError(w, 400, "invalid_request")
		return
	}
	a := *req.OIDC
	fail := func(code string) {
		delete(s.adminLogins, digest(r.PathValue("id")))
		s.oidcRedirect(w, r, a, "error", code)
	}
	if !time.Now().Before(req.Expires) || !s.validApplicationRequest(req) {
		fail("access_denied")
		return
	}
	if v.Get("action") == "cancel" || req.Status == "denied" {
		fail("access_denied")
		return
	}
	if req.Status != "approved" {
		oidcError(w, 409, "interaction_required")
		return
	}
	if !s.validAdminApprover(req.ApproverSessionID, req.ApproverThumb) {
		fail("access_denied")
		return
	}
	now := time.Now()
	s.cleanupOIDCLocked(now)
	if len(s.oidc.codes) >= 256 {
		oidcError(w, 429, "temporarily_unavailable")
		return
	}
	code := randomToken()
	s.oidc.codes[digest(code)] = oidcGrant{Auth: a, Approver: req.ApproverSessionID, Thumb: req.ApproverThumb, ID: randomToken(), Browser: req.Browser, Created: now, Expires: now.Add(time.Minute)}
	delete(s.adminLogins, digest(r.PathValue("id")))
	s.oidcRedirect(w, r, a, "code", code)
}
func (s *Server) validOIDCGrant(g oidcGrant) bool {
	c, ok := s.authClient(g.Auth.ClientID)
	return ok && c.OIDC != nil && c.OIDC.Enabled && c.Revision == g.Auth.Revision && s.validAdminApprover(g.Approver, g.Thumb) && time.Now().Before(g.Expires)
}

// All transient OIDC state uses adminMu, then store.mu, matching QR/session lock order.
func (s *Server) cleanupOIDCLocked(now time.Time) {
	for k, g := range s.oidc.codes {
		if !now.Before(g.Expires) {
			delete(s.oidc.codes, k)
		}
	}
	for k, g := range s.oidc.access {
		if !now.Before(g.Expires) {
			delete(s.oidc.access, k)
		}
	}
}
func (s *Server) invalidateOIDCLocked(id string) {
	for k, g := range s.oidc.codes {
		if g.Auth.ClientID == id {
			delete(s.oidc.codes, k)
		}
	}
	for k, g := range s.oidc.access {
		if g.Auth.ClientID == id {
			delete(s.oidc.access, k)
		}
	}
}
func (s *Server) oidcToken(w http.ResponseWriter, r *http.Request) {
	if !s.allow("oidc-token:"+s.loginClientIP(r), 120, time.Minute) {
		oidcError(w, 429, "temporarily_unavailable")
		return
	}
	if strings.Split(r.Header.Get("Content-Type"), ";")[0] != "application/x-www-form-urlencoded" || r.URL.RawQuery != "" {
		oidcError(w, 400, "invalid_request")
		return
	}
	raw, e := io.ReadAll(r.Body)
	if e != nil {
		oidcError(w, 400, "invalid_request")
		return
	}
	v, e := oidcParams(string(raw), "grant_type code redirect_uri code_verifier client_id client_secret")
	if e != nil {
		oidcError(w, 400, "invalid_request")
		return
	}
	id, secret, method := v.Get("client_id"), v.Get("client_secret"), "client_secret_post"
	if len(r.Header.Values("Authorization")) > 1 {
		oidcError(w, 400, "invalid_request")
		return
	}
	if r.Header.Get("Authorization") != "" {
		if v.Has("client_secret") || v.Has("client_id") {
			oidcError(w, 400, "invalid_request")
			return
		}
		var ok bool
		id, secret, ok = r.BasicAuth()
		if !ok {
			oidcError(w, 401, "invalid_client")
			return
		}
		id, e = url.QueryUnescape(id)
		if e != nil {
			oidcError(w, 401, "invalid_client")
			return
		}
		secret, e = url.QueryUnescape(secret)
		if e != nil {
			oidcError(w, 401, "invalid_client")
			return
		}
		method = "client_secret_basic"
	}
	c, ok := s.authClient(id)
	if !ok || c.OIDC == nil || !c.OIDC.Enabled || c.OIDC.AuthMethod != method || !validLoginID(secret) || !equal(digest(secret), c.SecretHash) {
		w.Header().Set("WWW-Authenticate", `Basic realm="Hako OIDC"`)
		oidcError(w, 401, "invalid_client")
		return
	}
	if v.Get("grant_type") != "authorization_code" {
		oidcError(w, 400, "unsupported_grant_type")
		return
	}
	s.adminMu.Lock()
	defer s.unlockAdminAndNotifyLoginPrompts()
	s.cleanupOIDCLocked(time.Now())
	g, ok := s.oidc.codes[digest(v.Get("code"))]
	if !ok || !validLoginID(v.Get("code")) || g.Auth.ClientID != c.ID || g.Auth.Redirect != v.Get("redirect_uri") || !s.validOIDCGrant(g) {
		oidcError(w, 400, "invalid_grant")
		return
	}
	if g.Auth.Challenge != "" {
		verifier := v.Get("code_verifier")
		sum := sha256.Sum256([]byte(verifier))
		if !pkceVerifier.MatchString(verifier) || !equal(raw64.EncodeToString(sum[:]), g.Auth.Challenge) {
			oidcError(w, 400, "invalid_grant")
			return
		}
	} else if v.Has("code_verifier") {
		oidcError(w, 400, "invalid_grant")
		return
	}
	if len(s.oidc.access) >= 512 {
		oidcError(w, 503, "temporarily_unavailable")
		return
	}
	now := time.Now()
	claims := s.oidcIdentity(g.Auth.Scope)
	claims["iss"] = s.config.PublicURL
	claims["aud"] = c.ID
	claims["iat"] = now.Unix()
	claims["exp"] = now.Add(5 * time.Minute).Unix()
	if g.Auth.Nonce != "" {
		claims["nonce"] = g.Auth.Nonce
	}
	b, e := json.Marshal(claims)
	if e != nil {
		oidcError(w, 503, "server_error")
		return
	}
	signed, e := s.oidc.signer.Sign(b)
	if e != nil {
		oidcError(w, 503, "server_error")
		return
	}
	jwt, e := signed.CompactSerialize()
	if e != nil {
		oidcError(w, 503, "server_error")
		return
	}
	token := randomToken()
	g.Expires = now.Add(5 * time.Minute)
	g.Created = now
	s.oidc.access[digest(token)] = g
	delete(s.oidc.codes, digest(v.Get("code")))
	respond(w, 200, map[string]any{"access_token": token, "token_type": "Bearer", "expires_in": 300, "id_token": jwt, "scope": g.Auth.Scope})
}
func (s *Server) oidcIdentity(scope string) map[string]any {
	var sub string
	s.store.inspect(func(st state) { sub = st.Subject })
	result := map[string]any{"sub": sub}
	if slices.Contains(strings.Fields(scope), "profile") {
		result["name"] = s.config.Username
		result["preferred_username"] = s.config.Username
	}
	return result
}
func (s *Server) oidcUserInfo(w http.ResponseWriter, r *http.Request) {
	if !s.allow("oidc-userinfo:"+s.loginClientIP(r), 240, time.Minute) {
		oidcError(w, 429, "temporarily_unavailable")
		return
	}
	if r.URL.RawQuery != "" {
		oidcError(w, 400, "invalid_request")
		return
	}
	h := r.Header.Get("Authorization")
	token := strings.TrimPrefix(h, "Bearer ")
	s.adminMu.Lock()
	defer s.unlockAdminAndNotifyLoginPrompts()
	g, ok := s.oidc.access[digest(token)]
	if len(r.Header.Values("Authorization")) != 1 || !strings.HasPrefix(h, "Bearer ") || !validLoginID(token) || !ok || !s.validOIDCGrant(g) {
		w.Header().Set("WWW-Authenticate", `Bearer error="invalid_token"`)
		oidcError(w, 401, "invalid_token")
		return
	}
	respond(w, 200, s.oidcIdentity(g.Auth.Scope))
}
