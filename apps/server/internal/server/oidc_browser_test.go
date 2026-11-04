package server

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Optional real-browser check for Cookie/CSRF, consent polling and cross-origin form redirects.
// The approval uses a test Console; this is not a real iPhone or client UI acceptance test.
func TestOIDCHeadlessBrowserReturnsToRegisteredClient(t *testing.T) {
	chrome := os.Getenv("HAKO_CHROME")
	if chrome == "" || os.Getenv("HAKO_PLAYWRIGHT") == "" {
		t.Skip("set HAKO_CHROME to a headless Chrome executable")
	}
	f := newFixture(t, true)
	c, _ := oidcTestClient(f, "browser-client")
	returned := make(chan bool, 1)
	callback := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		good := r.URL.Path == "/callback" && validLoginID(r.URL.Query().Get("code")) && r.URL.Query().Get("state") == "opaque state & value"
		select {
		case returned <- good:
		default:
		}
		fmt.Fprint(w, "OIDC_BROWSER_CALLBACK_OK")
	}))
	defer callback.Close()
	c.OIDC.RedirectURIs = []string{callback.URL + "/callback"}
	f.s.store.update(func(st *state) error { st.AuthClients[c.ID] = c; return nil })
	requestIDs := make(chan string, 1)
	f.http.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/oidc/requests/") {
			id := strings.TrimPrefix(r.URL.Path, "/oidc/requests/")
			if validLoginID(id) {
				select {
				case requestIDs <- id:
				default:
				}
			}
		}
		f.s.ServeHTTP(w, r)
	})
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "node", filepath.Join("..", "..", "tests", "run-oidc-browser.mjs"))
	input, _ := json.Marshal(map[string]string{"chrome": chrome, "url": f.s.config.PublicURL + "/oidc/authorize?" + oidcQuery(c).Encode()})
	cmd.Stdin = strings.NewReader(string(input) + "\n")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if e := cmd.Start(); e != nil {
		t.Fatal(e)
	}
	defer cmd.Process.Kill()
	select {
	case id := <-requestIDs:
		approveLogin(f, qrStart{ID: id})
	case <-ctx.Done():
		t.Fatal("browser did not load authorization page")
	}
	if e := cmd.Wait(); e != nil {
		t.Fatalf("headless Chrome did not complete: %v; %s", e, stderr.String())
	}
	select {
	case good := <-returned:
		if !good {
			t.Fatal("browser returned an invalid callback")
		}
	default:
		f.s.adminMu.Lock()
		states := []string{}
		for _, req := range f.s.adminLogins {
			states = append(states, req.Status)
		}
		codes := len(f.s.oidc.codes)
		f.s.adminMu.Unlock()
		t.Logf("states=%v codes=%d", states, codes)
		t.Fatalf("browser did not return to registered client (CSP or navigation failure); callback marker present: %t", strings.Contains(stdout.String(), "OIDC_BROWSER_CALLBACK_OK"))
	}
}
