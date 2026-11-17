package server

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func signedDataQuery(t *testing.T, f *fixture, values map[string]any) map[string]string {
	t.Helper()
	if values["nonce"] == nil {
		values["nonce"] = randomToken()
	}
	if values["issuedAt"] == nil {
		values["issuedAt"] = time.Now().Unix()
	}
	data, err := json.Marshal(values)
	if err != nil {
		t.Fatal(err)
	}
	payload := base64.StdEncoding.EncodeToString(data)
	keyID := f.s.registry.Load().Agents[0].keyID
	hash := sha256.Sum256([]byte("hako-agent-data/v1\n" + f.s.config.PublicURL + "\nowner\n" + keyID + "\n" + payload))
	signature, err := rsa.SignPSS(rand.Reader, f.agentKey, crypto.SHA256, hash[:], &rsa.PSSOptions{SaltLength: rsa.PSSSaltLengthEqualsHash})
	if err != nil {
		t.Fatal(err)
	}
	return map[string]string{"username": "owner", "keyId": keyID, "payload": payload, "signature": base64.StdEncoding.EncodeToString(signature)}
}

func TestAgentDataPermissionAndReadOnlyQueries(t *testing.T) {
	f := newFixture(t, true)
	const endpoint = "/api/v1/agents/data-query"
	request := func(sql string) map[string]string {
		return signedDataQuery(t, f, map[string]any{"operation": "query", "sql": sql, "limit": 1})
	}
	if status, _ := f.call("POST", endpoint, request("SELECT 1"), ""); status != 403 {
		t.Fatal("permission default must be closed", status)
	}
	if status, _ := f.call("PATCH", "/admin/api/agents/PC/data-query", map[string]bool{"enabled": true}, f.tokens.AccessToken); status != 403 {
		t.Fatal("Console/Agent credentials must not substitute for administrator session", status)
	}
	admin := loginAdmin(f)
	if status, _, _ := admin.request("PATCH", "/admin/api/agents/PC/data-query", map[string]bool{"enabled": true}, f.s.config.PublicURL, "wrong"); status != 403 {
		t.Fatal("missing CSRF protection", status)
	}
	admin.call("PATCH", "agents/PC/data-query", map[string]bool{"enabled": true}, 200)
	admin.call("PATCH", "agents/PC/data-query", map[string]any{}, 400)
	admin.call("PATCH", "agents/MISS/data-query", map[string]bool{"enabled": true}, 404)
	listing := admin.call("GET", "agents", nil, 200)
	if !strings.Contains(string(listing), `"dataQueryEnabled":true`) {
		t.Fatal(string(listing))
	}
	f.s.store.inspect(func(st state) {
		if !st.Registry.Agents[0].DataQueryEnabled {
			t.Error("permission not persisted")
		}
	})
	f.connectAgent(false)
	connection, _ := f.s.agentHub.Lookup("PC")
	valid := request("SELECT 1 AS value UNION ALL SELECT 2")
	status, body := f.call("POST", endpoint, valid, "")
	if status != 200 || !strings.Contains(string(body), `"hasMore":true`) || !strings.Contains(string(body), `"rows":[["1"]]`) {
		t.Fatal(status, string(body))
	}
	if status, _ = f.call("POST", endpoint, valid, ""); status != 401 {
		t.Fatal("replay accepted", status)
	}
	for _, sql := range []string{"DELETE FROM investment_accounts", "SELECT 1; SELECT 2", "PRAGMA user_version", "ATTACH DATABASE '/tmp/other' AS other", "SELECT * FROM main.state"} {
		if status, body := f.call("POST", endpoint, request(sql), ""); status != 400 {
			t.Fatal(sql, status, string(body))
		}
	}
	schema := signedDataQuery(t, f, map[string]any{"operation": "schema"})
	if status, body := f.call("POST", endpoint, schema, ""); status != 200 || !strings.Contains(string(body), "investment_accounts") {
		t.Fatal(status, string(body))
	}
	if current, _ := f.s.agentHub.Lookup("PC"); current != connection {
		t.Fatal("query replaced live Agent connection")
	}
	admin.call("PATCH", "agents/PC/data-query", map[string]bool{"enabled": false}, 200)
	if status, _ := f.call("POST", endpoint, request("SELECT 1"), ""); status != 403 {
		t.Fatal("revocation not immediate", status)
	}
}

func TestAgentDataProofCannotBeForgedOrReusedAfterRestart(t *testing.T) {
	f := newFixture(t, true)
	admin := loginAdmin(f)
	admin.call("PATCH", "agents/PC/data-query", map[string]bool{"enabled": true}, 200)
	const endpoint = "/api/v1/agents/data-query"
	for _, age := range []int64{-61, 30} {
		request := signedDataQuery(t, f, map[string]any{"operation": "query", "sql": "SELECT 1", "issuedAt": time.Now().Unix() + age})
		if status, _ := f.call("POST", endpoint, request, ""); status != 401 {
			t.Fatal("timestamp accepted", status)
		}
	}
	request := signedDataQuery(t, f, map[string]any{"operation": "query", "sql": "SELECT 1"})
	for _, field := range []string{"username", "keyId", "signature"} {
		copy := map[string]string{}
		for k, v := range request {
			copy[k] = v
		}
		copy[field] = "invalid"
		if status, _ := f.call("POST", endpoint, copy, ""); status != 401 {
			t.Fatal("forged identity", field, status)
		}
	}
	tampered := signedDataQuery(t, f, map[string]any{"operation": "query", "sql": "SELECT 2"})
	tampered["signature"] = request["signature"]
	if status, _ := f.call("POST", endpoint, tampered, ""); status != 401 {
		t.Fatal("tampered SQL accepted", status)
	}
	if status, _ := f.call("POST", endpoint, request, ""); status != 200 {
		t.Fatal(status)
	}
	restarted, err := New(f.s.config)
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	if !restarted.registry.Load().Agents[0].DataQueryEnabled {
		t.Fatal("permission lost after restart")
	}
	body, _ := json.Marshal(request)
	r, _ := http.NewRequest("POST", f.http.URL+endpoint, strings.NewReader(string(body)))
	r.Header.Set("Content-Type", "application/json")
	// The persisted proof is checked directly through the restarted handler.
	w := httptest.NewRecorder()
	restarted.mux.ServeHTTP(w, r)
	if w.Code != 401 {
		t.Fatal("proof reused after restart", w.Code)
	}
}

func TestConsoleAdministratorSharesAgentDataPermission(t *testing.T) {
	f := newFixture(t, true)
	ws := openConsoleAgentSocket(t, f, "/ws/console/agents")
	for _, enabled := range []bool{true, false} {
		body, _ := json.Marshal(map[string]bool{"enabled": enabled})
		writeAgentFrame(t, ws, consoleAgentCommand{ID: "permission", Type: "data_query_permission", AgentID: "PC", Body: body})
		reply := readAgentFrame[struct {
			Type   string
			Status int
			Body   struct{ DataQueryEnabled bool }
		}](t, ws)
		if reply.Status != 200 || reply.Body.DataQueryEnabled != enabled {
			t.Fatal(reply)
		}
		admin := loginAdmin(f)
		listing := admin.call("GET", "agents", nil, 200)
		var data struct {
			Agents []struct {
				ID               string
				DataQueryEnabled bool
			}
		}
		if json.Unmarshal(listing, &data) != nil || len(data.Agents) != 1 || data.Agents[0].DataQueryEnabled != enabled {
			t.Fatal(string(listing))
		}
	}
	writeAgentFrame(t, ws, consoleAgentCommand{ID: "bad", Type: "data_query_permission", AgentID: "PC", Body: json.RawMessage(`{}`)})
	if reply := readAgentFrame[struct{ Status int }](t, ws); reply.Status != 400 {
		t.Fatal(reply)
	}
}
