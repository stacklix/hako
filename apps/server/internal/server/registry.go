package server

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"os"
	"strings"
)

// Agent keys persist across restarts; Console keys are replaced from operator configuration at startup.
type Registry struct {
	Agents   []AgentConfig   `json:"agents"`
	Consoles []ConsoleConfig `json:"consoles"`
}

func publicBlock(text string) (*pem.Block, error) {
	if len(text) > 16*1024 {
		return nil, fmt.Errorf("公钥文件过大")
	}
	b, rest := pem.Decode([]byte(text))
	if b == nil || len(strings.TrimSpace(string(rest))) != 0 || len(b.Headers) != 0 || (b.Type != "PUBLIC KEY" && b.Type != "RSA PUBLIC KEY") {
		return nil, fmt.Errorf("请提供单个 PEM 公钥，不接受私钥")
	}
	return b, nil
}

func parseAgent(a AgentConfig, fromFile bool) (AgentConfig, error) {
	if a.Capabilities != nil && !validCapabilities(a.Capabilities) {
		return a, fmt.Errorf("Agent 能力清单无效")
	}
	if !validAgentID(a.ID) {
		return a, fmt.Errorf("Agent ID 应为 1–5 位大写字母或数字，并以字母开头")
	}
	if strings.TrimSpace(a.Name) == "" || len(a.Name) > 100 {
		return a, fmt.Errorf("Agent 名称无效")
	}
	if fromFile && a.PublicKeyPEM == "" {
		b, err := os.ReadFile(a.PublicKeyFile)
		if err != nil {
			return a, err
		}
		a.PublicKeyPEM = string(b)
	}
	b, err := publicBlock(a.PublicKeyPEM)
	if err != nil {
		return a, err
	}
	var key *rsa.PublicKey
	if parsed, err := x509.ParsePKIXPublicKey(b.Bytes); err == nil {
		key, _ = parsed.(*rsa.PublicKey)
	} else {
		key, _ = x509.ParsePKCS1PublicKey(b.Bytes)
	}
	if key == nil || key.N.BitLen() < 2048 || key.N.BitLen() > 8192 {
		return a, fmt.Errorf("Agent 公钥必须为 RSA 2048–8192 位")
	}
	der, _ := x509.MarshalPKIXPublicKey(key)
	a.PublicKeyPEM = string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}))
	a.PublicKeyFile = ""
	a.key = key
	a.keyID = digest(string(der))
	a.Name = strings.TrimSpace(a.Name)
	return a, nil
}

func parseConsole(c ConsoleConfig, fromFile bool) (ConsoleConfig, error) {
	if strings.TrimSpace(c.Name) == "" || len(c.Name) > 100 {
		return c, fmt.Errorf("Console 名称无效")
	}
	if fromFile && c.PublicKeyPEM == "" {
		b, err := os.ReadFile(c.PublicKeyFile)
		if err != nil {
			return c, err
		}
		c.PublicKeyPEM = string(b)
	}
	b, err := publicBlock(c.PublicKeyPEM)
	if err != nil {
		return c, err
	}
	parsed, err := x509.ParsePKIXPublicKey(b.Bytes)
	if err != nil {
		return c, fmt.Errorf("Console 公钥格式无效")
	}
	key, ok := parsed.(*ecdsa.PublicKey)
	if !ok || key.Curve != elliptic.P256() {
		return c, fmt.Errorf("Console 公钥必须为 P-256")
	}
	public := jwk{Crv: "P-256", Kty: "EC", X: raw64.EncodeToString(key.X.FillBytes(make([]byte, 32))), Y: raw64.EncodeToString(key.Y.FillBytes(make([]byte, 32)))}
	canonical, _ := json.Marshal(public)
	c.thumb = digest(string(canonical))
	c.PublicKeyFile = ""
	c.Name = strings.TrimSpace(c.Name)
	c.PublicKeyPEM = string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: b.Bytes}))
	return c, nil
}

func loadRegistry(agents []AgentConfig, consoles []ConsoleConfig, fromFile bool) (*Registry, error) {
	if len(agents) > 256 || len(consoles) > 32 {
		return nil, fmt.Errorf("最多支持 256 个 Agent 和 32 个 Console")
	}
	r := &Registry{Agents: make([]AgentConfig, 0, len(agents)), Consoles: make([]ConsoleConfig, 0, len(consoles))}
	ids, keys := map[string]bool{}, map[string]bool{}
	for _, value := range agents {
		a, err := parseAgent(value, fromFile)
		if err != nil {
			return nil, err
		}
		if ids[a.ID] || keys[a.keyID] {
			return nil, fmt.Errorf("Agent ID 或公钥重复")
		}
		ids[a.ID], keys[a.keyID] = true, true
		r.Agents = append(r.Agents, a)
	}
	for _, value := range consoles {
		c, err := parseConsole(value, fromFile)
		if err != nil {
			return nil, err
		}
		if keys[c.thumb] {
			return nil, fmt.Errorf("Console 公钥重复")
		}
		keys[c.thumb] = true
		r.Consoles = append(r.Consoles, c)
	}
	return r, nil
}

func trustedConsoleState(st *state, thumb string) bool {
	if st.Registry == nil {
		return false
	}
	for _, c := range st.Registry.Consoles {
		if c.thumb != "" && equal(c.thumb, thumb) {
			return true
		}
		parsed, err := parseConsole(c, false)
		if err == nil && equal(parsed.thumb, thumb) {
			return true
		}
	}
	return false
}

func (s *Server) saveRegistry(next *Registry) error {
	err := s.store.update(func(st *state) error {
		st.Registry = next
		for id, ss := range st.Sessions {
			if !trustedConsoleState(st, ss.Thumb) {
				delete(st.Sessions, id)
			}
		}
		for id, ch := range st.Challenges {
			if !trustedConsoleState(st, ch.Thumb) {
				delete(st.Challenges, id)
			}
		}
		return nil
	})
	if err == nil {
		s.registry.Store(next)
	}
	return err
}
