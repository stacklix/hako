package server

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// Opt-in uses the hash-checked upstream module prepared by tests/prepare-headplane-oidc.mjs.
// This exercises Headplane's actual provider code, not its UI, database, Headscale or SSH.
func TestOIDCHeadplane082OfficialProvider(t *testing.T) {
	runner := os.Getenv("HAKO_HEADPLANE_RUNNER")
	if runner == "" {
		t.Skip("set HAKO_HEADPLANE_RUNNER to the prepared official runner.mjs")
	}
	for _, method := range []string{"client_secret_basic", "client_secret_post"} {
		t.Run(method, func(t *testing.T) {
			f := newFixture(t, true)
			c, secret := oidcTestClient(f, "headplane-test")
			c.OIDC.AuthMethod = method
			c.OIDC.RedirectURIs = []string{"https://client.example/admin/oidc/callback"}
			f.s.store.update(func(st *state) error { st.AuthClients[c.ID] = c; return nil })
			ca := filepath.Join(t.TempDir(), "issuer-ca.pem")
			if e := os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: f.http.Certificate().Raw}), 0600); e != nil {
				t.Fatal(e)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, "node", runner)
			cmd.Env = append(os.Environ(), "NODE_EXTRA_CA_CERTS="+ca)
			stdin, e := cmd.StdinPipe()
			if e != nil {
				t.Fatal(e)
			}
			stdout, e := cmd.StdoutPipe()
			if e != nil {
				t.Fatal(e)
			}
			var stderr bytes.Buffer
			cmd.Stderr = &stderr
			if e = cmd.Start(); e != nil {
				t.Fatal(e)
			}
			defer cmd.Process.Kill()
			config := map[string]any{"issuer": f.s.config.PublicURL, "clientId": c.ID, "clientSecret": secret, "baseUrl": "https://client.example", "scope": "openid profile", "usePkce": true, "tokenEndpointAuthMethod": method}
			if e = json.NewEncoder(stdin).Encode(config); e != nil {
				t.Fatal(e)
			}
			scanner := bufio.NewScanner(stdout)
			if !scanner.Scan() {
				t.Fatalf("Headplane did not start flow: %s", stderr.String())
			}
			var start struct {
				URL string `json:"url"`
			}
			if e = json.Unmarshal(scanner.Bytes(), &start); e != nil {
				t.Fatal(e)
			}
			u, e := url.Parse(start.URL)
			if e != nil {
				t.Fatal(e)
			}
			b := startOIDC(f, u.Query())
			approveLogin(f, qrStart{ID: b.id})
			callback := finishOIDC(f, b, "continue")
			if callback.Code != 303 {
				t.Fatal("completion failed")
			}
			fmt.Fprintln(stdin, callback.Header().Get("Location"))
			stdin.Close()
			if !scanner.Scan() {
				cmd.Wait()
				t.Fatalf("Headplane callback failed: %s", stderr.String())
			}
			var identity struct{ Subject, Name, Username, Email string }
			if e = json.Unmarshal(scanner.Bytes(), &identity); e != nil {
				t.Fatal(e)
			}
			if e = cmd.Wait(); e != nil {
				t.Fatalf("official provider failed: %s", stderr.String())
			}
			var subject string
			f.s.store.inspect(func(st state) { subject = st.Subject })
			if identity.Subject != subject || identity.Name != "owner" || identity.Username != "owner" || identity.Email != "" {
				t.Fatalf("unexpected Headplane identity: %+v", identity)
			}
		})
	}
}
