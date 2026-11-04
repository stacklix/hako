package server

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestLoginNotificationsIncludeAllActionableKinds(t *testing.T) {
	f := newFixture(t, true)
	ensureConsoleLogin(f)
	_, admin := startLogin(f)
	c, secret := appTestClient(f, "scan-client")
	app := startApp(f, c, secret, "login")
	bind := startApp(f, c, secret, "bind")
	oidc, _ := oidcTestClient(f, "oidc-client")
	browser := startOIDC(f, oidcQuery(oidc))
	inspectLogin(f, app.ID) // An opened but unapproved request remains in the inbox.
	status, data := f.call("GET", "/api/v1/auth/login-prompts", nil, f.tokens.AccessToken)
	if status != 200 {
		t.Fatalf("inbox: %d %s", status, data)
	}
	var list struct {
		Requests []map[string]string `json:"requests"`
	}
	if json.Unmarshal(data, &list) != nil || len(list.Requests) != 4 {
		t.Fatalf("missing request types: %s", data)
	}
	want := map[string]string{admin.ID: "", app.ID: "login", bind.ID: "bind", browser.id: "oidc"}
	for _, row := range list.Requests {
		purpose, ok := want[row["id"]]
		if !ok || row["purpose"] != purpose {
			t.Fatal("request kind mismatch")
		}
		if _, ok := row["confirmationCode"]; ok {
			t.Fatal("inbox disclosed confirmation code")
		}
		if _, ok := row["redeemToken"]; ok {
			t.Fatal("inbox disclosed redemption credential")
		}
	}
	for _, kind := range []string{"admin", "app", "bind"} {
		id := admin.ID
		if kind == "app" {
			id = app.ID
		}
		if kind == "bind" {
			id = bind.ID
		}
		f.s.adminMu.Lock()
		req := f.s.adminLogins[digest(id)]
		code, nonce := req.Code, req.Nonce
		f.s.adminMu.Unlock()
		status, data = f.call("POST", "/api/v1/auth/login-prompts/"+id+"/approve", map[string]string{"confirmationCode": code}, f.tokens.AccessToken, nonce)
		if status != 200 {
			t.Fatalf("%s notification approval: %d %s", kind, status, data)
		}
	}
	stranger := &adminClient{f: f}
	stranger.call("POST", "login/requests/"+admin.ID+"/complete", map[string]bool{}, 404)
	if appCall(f, c, secret, "POST", "/requests/"+app.ID+"/complete", "", "", struct{}{}).Code != 404 {
		t.Fatal("public request ID claimed application login")
	}
	if appCall(f, c, secret, "POST", "/requests/"+app.ID+"/complete", app.Redeem, "", struct{}{}).Code != 200 {
		t.Fatal("original client could not redeem notification-approved login")
	}
	status, data = f.call("GET", "/api/v1/auth/login-prompts", nil, f.tokens.AccessToken)
	if status != 200 || strings.Contains(string(data), admin.ID) || strings.Contains(string(data), bind.ID) {
		t.Fatal("approved requests stayed in inbox")
	}
}

func TestLoginNotificationsDoNotTruncateToLegacyOIDCLimit(t *testing.T) {
	f := newFixture(t, true)
	ensureConsoleLogin(f)
	f.s.adminMu.Lock()
	for n := 0; n < 40; n++ {
		id := randomToken()
		f.s.adminLogins[digest(id)] = &adminLoginRequest{RequestID: id, Code: fmt.Sprintf("%06d", n), Nonce: randomToken(), BrowserHash: digest(randomToken()), Status: "pending", Created: time.Now(), Expires: time.Now().Add(time.Minute)}
	}
	f.s.adminMu.Unlock()
	status, data := f.call("GET", "/api/v1/auth/login-prompts", nil, f.tokens.AccessToken)
	var list struct {
		Requests []json.RawMessage `json:"requests"`
	}
	if status != 200 || json.Unmarshal(data, &list) != nil || len(list.Requests) != 40 {
		t.Fatalf("truncated notification inbox: %d", status)
	}
}
