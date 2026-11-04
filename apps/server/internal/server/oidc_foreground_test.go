package server

import (
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestOIDCForegroundConfirmation(t *testing.T) {
	f := newFixture(t, true)
	ensureConsoleLogin(f)
	c, secret := oidcTestClient(f, "foreground")
	b := startOIDC(f, oidcQuery(c))
	_, admin := startLogin(f)
	f.s.adminMu.Lock()
	req := f.s.adminLogins[digest(b.id)]
	code, nonce := req.Code, req.Nonce
	f.s.adminMu.Unlock()
	status, data := f.call("GET", "/api/v1/auth/oidc/requests", nil, f.tokens.AccessToken)
	if status != 200 || strings.Contains(string(data), "confirmationCode") || strings.Contains(string(data), code) || strings.Contains(string(data), admin.ID) {
		t.Fatalf("unsafe discovery: %d", status)
	}
	var list struct {
		Issuer   string `json:"issuer"`
		Requests []struct {
			ID    string `json:"id"`
			Nonce string `json:"nonce"`
		} `json:"requests"`
	}
	if json.Unmarshal(data, &list) != nil || list.Issuer != f.s.config.PublicURL || len(list.Requests) != 1 || list.Requests[0].ID != b.id || list.Requests[0].Nonce != nonce {
		t.Fatal("invalid foreground discovery")
	}
	f.s.adminMu.Lock()
	stillPending := req.Status == "pending" && len(f.s.oidc.codes) == 0
	f.s.adminMu.Unlock()
	if !stillPending {
		t.Fatal("discovery approved a request")
	}
	path := "/api/v1/auth/oidc/requests/" + b.id + "/approve"
	if status, _ = f.call("POST", path, map[string]string{"confirmationCode": code}, f.tokens.AccessToken, randomToken()); status != 400 {
		t.Fatal("accepted wrong nonce")
	}
	wrong := "000000"
	if code == wrong {
		wrong = "111111"
	}
	if status, _ = f.call("POST", path, map[string]string{"confirmationCode": wrong}, f.tokens.AccessToken, nonce); status != 400 {
		t.Fatal("accepted wrong browser code")
	}
	if status, data = f.call("POST", path, map[string]string{"confirmationCode": code}, f.tokens.AccessToken, nonce); status != 200 {
		t.Fatalf("approval failed: %d %s", status, data)
	}
	if status, _ = f.call("POST", path, map[string]string{"confirmationCode": code}, f.tokens.AccessToken, nonce); status != 409 {
		t.Fatal("approval replay accepted")
	}
	other := b
	other.cookie = &http.Cookie{Name: b.cookie.Name, Value: randomToken()}
	if finishOIDC(f, other, "continue").Code != 404 {
		t.Fatal("another browser claimed foreground approval")
	}
	done := finishOIDC(f, b, "continue")
	u, _ := url.Parse(done.Header().Get("Location"))
	if done.Code != 303 || u.Query().Get("code") == "" {
		t.Fatal("original browser did not receive code")
	}
	form := tokenForm(c, u.Query().Get("code"))
	token := oidcAccess(f, oidcRequest(f, "POST", "/oidc/token", form.Encode(), nil, c.ID, secret, ""))
	if oidcRequest(f, "GET", "/oidc/userinfo", "", nil, "", "", token).Code != 200 {
		t.Fatal("foreground login cannot access UserInfo")
	}
}

func TestOIDCForegroundAuthorizationAndConcurrentApproval(t *testing.T) {
	f := newFixture(t, true)
	ensureConsoleLogin(f)
	if out := oidcRequest(f, "GET", "/api/v1/auth/oidc/requests", "", nil, "", "", ""); out.Code != 401 {
		t.Fatal("unauthenticated discovery allowed")
	}
	_, ordinary := startLogin(f)
	info := inspectLogin(f, ordinary.ID)
	if status, _ := f.call("POST", "/api/v1/auth/oidc/requests/"+ordinary.ID+"/approve", map[string]string{"confirmationCode": info.ConfirmationCode}, f.tokens.AccessToken, info.Nonce); status != 404 {
		t.Fatal("foreground route accepted a non-OIDC request")
	}
	c, _ := oidcTestClient(f, "foreground-concurrent")
	b := startOIDC(f, oidcQuery(c))
	f.s.adminMu.Lock()
	req := f.s.adminLogins[digest(b.id)]
	code, nonce := req.Code, req.Nonce
	f.s.adminMu.Unlock()
	statuses := make(chan int, 2)
	for n := 0; n < 2; n++ {
		go func() {
			status, _ := f.call("POST", "/api/v1/auth/oidc/requests/"+b.id+"/approve", map[string]string{"confirmationCode": code}, f.tokens.AccessToken, nonce)
			statuses <- status
		}()
	}
	a, z := <-statuses, <-statuses
	if !((a == 200 && z == 409) || (a == 409 && z == 200)) {
		t.Fatalf("concurrent approval statuses: %d %d", a, z)
	}
	if done := finishOIDC(f, b, "continue"); done.Code != 303 {
		t.Fatal("concurrent approval lost browser flow")
	}
}

func TestOIDCForegroundLifecycle(t *testing.T) {
	for _, mode := range []string{"deny", "attempts", "expiry", "disabled", "rotated", "callback", "revoked", "scanned"} {
		t.Run(mode, func(t *testing.T) {
			f := newFixture(t, true)
			ensureConsoleLogin(f)
			c, _ := oidcTestClient(f, "foreground")
			b := startOIDC(f, oidcQuery(c))
			f.s.adminMu.Lock()
			req := f.s.adminLogins[digest(b.id)]
			nonce, code := req.Nonce, req.Code
			f.s.adminMu.Unlock()
			path := "/api/v1/auth/oidc/requests/" + b.id
			switch mode {
			case "deny":
				status, _ := f.call("POST", path+"/deny", map[string]string{}, f.tokens.AccessToken, nonce)
				if status != 200 {
					t.Fatalf("deny: %d", status)
				}
			case "attempts":
				wrong := "000000"
				if wrong == code {
					wrong = "111111"
				}
				for n := 1; n <= 5; n++ {
					status, _ := f.call("POST", path+"/approve", map[string]string{"confirmationCode": wrong}, f.tokens.AccessToken, nonce)
					want := 400
					if n == 5 {
						want = 429
					}
					if status != want {
						t.Fatalf("attempt %d: %d", n, status)
					}
				}
				if status, _ := f.call("POST", path+"/approve", map[string]string{"confirmationCode": code}, f.tokens.AccessToken, nonce); status != 409 {
					t.Fatal("locked request approved")
				}
			case "expiry":
				f.s.adminMu.Lock()
				req.Expires = time.Now().Add(-time.Second)
				f.s.adminMu.Unlock()
			case "disabled":
				f.s.store.update(func(st *state) error {
					x := st.AuthClients[c.ID]
					x.Enabled = false
					st.AuthClients[c.ID] = x
					return nil
				})
			case "rotated":
				f.s.store.update(func(st *state) error {
					x := st.AuthClients[c.ID]
					x.SecretHash = digest(randomToken())
					st.AuthClients[c.ID] = x
					return nil
				})
			case "callback":
				f.s.store.update(func(st *state) error {
					x := st.AuthClients[c.ID]
					x.Revision = randomToken()
					st.AuthClients[c.ID] = x
					return nil
				})
			case "revoked":
				f.s.store.update(func(st *state) error { delete(st.Sessions, f.tokens.SessionID); return nil })
			case "scanned":
				inspectLogin(f, b.id)
			}
			status, data := f.call("GET", "/api/v1/auth/oidc/requests", nil, f.tokens.AccessToken)
			if mode == "revoked" {
				if status == 200 {
					t.Fatal("revoked device discovered requests")
				}
				return
			}
			if status != 200 || strings.Contains(string(data), b.id) {
				t.Fatalf("finished/unavailable prompt returned: %d", status)
			}
			if mode == "deny" || mode == "attempts" {
				done := finishOIDC(f, b, "continue")
				u, _ := url.Parse(done.Header().Get("Location"))
				if u.Query().Get("error") != "access_denied" {
					t.Fatal("denial not returned to browser")
				}
			}
			if mode == "disabled" || mode == "rotated" || mode == "callback" || mode == "expiry" {
				if status, _ := f.call("POST", path+"/approve", map[string]string{"confirmationCode": code}, f.tokens.AccessToken, nonce); status == 200 {
					t.Fatal("invalidated request approved")
				}
			}
		})
	}
}
