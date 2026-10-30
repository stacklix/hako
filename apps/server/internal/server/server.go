package server

import (
	"crypto/rsa"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type AgentConfig struct {
	ID            string            `json:"id"`
	Name          string            `json:"name"`
	PublicKeyFile string            `json:"publicKeyFile"`
	PublicKeyPEM  string            `json:"publicKeyPem,omitempty"`
	Capabilities  []agentCapability `json:"capabilities"`
	key           *rsa.PublicKey
	keyID         string
}

type Config struct {
	Database       string
	MasterKey      []byte
	Username       string
	Consoles       []ConsoleConfig
	PublicURL      string
	TrustedProxies string
	Agents         []AgentConfig
	RequestTimeout time.Duration
	AccessLogs     AccessLogConfig
}

type bucket struct {
	count int
	until time.Time
}

type Server struct {
	config         Config
	trustedProxies proxyTrust
	store          *store
	mux            *http.ServeMux
	mu             sync.Mutex
	online         map[string]*agentConnection
	lastSeen       map[string]string
	limits         map[string]bucket
	requests       chan struct{}
	registry       atomic.Pointer[Registry]
	registryMu     sync.Mutex
	adminMu        sync.Mutex
	adminSessions  map[string]adminSession
	adminLogins    map[string]*adminLoginRequest
	accessLogs     *accessLogService
}

var identifier = regexp.MustCompile(`^[A-Za-z0-9_-]{1,80}$`)
var errInvalidSession = errors.New("invalid_session")

func New(config Config) (*Server, error) {
	u, err := url.Parse(config.PublicURL)
	if err != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return nil, fmt.Errorf("public URL must be an origin without a path")
	}
	if u.Scheme != "https" && !(u.Scheme == "http" && (u.Hostname() == "localhost" || net.ParseIP(u.Hostname()).IsLoopback())) {
		return nil, fmt.Errorf("HTTPS required except on loopback")
	}
	config.PublicURL = strings.TrimRight(config.PublicURL, "/")
	if len(config.MasterKey) != 32 || !identifier.MatchString(config.Username) {
		return nil, fmt.Errorf("master key must be 32 bytes; configure a valid single username")
	}
	if config.RequestTimeout == 0 {
		config.RequestTimeout = 10 * time.Second
	}
	proxies, err := parseTrustedProxies(config.TrustedProxies)
	if err != nil {
		return nil, err
	}
	st, err := openStore(config.Database, config.MasterKey)
	if err != nil {
		return nil, err
	}
	s := &Server{config: config, store: st, mux: http.NewServeMux(), online: map[string]*agentConnection{}, lastSeen: map[string]string{}, limits: map[string]bucket{}, requests: make(chan struct{}, 32), adminSessions: map[string]adminSession{}, adminLogins: map[string]*adminLoginRequest{}}
	s.trustedProxies = proxies
	var registry *Registry
	if err := st.update(func(value *state) error {
		var err error
		agents := config.Agents
		if value.Registry != nil {
			agents = value.Registry.Agents
		}
		// Agent keys are managed in the database. Console trust always comes from operator configuration.
		registry, err = loadRegistry(agents, config.Consoles, true)
		if err != nil {
			return err
		}
		value.Registry = registry
		for id, ss := range value.Sessions {
			if !trustedConsoleState(value, ss.Thumb) {
				delete(value.Sessions, id)
			}
		}
		for id, ch := range value.Challenges {
			if !trustedConsoleState(value, ch.Thumb) {
				delete(value.Challenges, id)
			}
		}
		return nil
	}); err != nil {
		st.db.Close()
		return nil, err
	}
	s.registry.Store(registry)
	s.config.Agents, s.config.Consoles = registry.Agents, registry.Consoles
	if s.accessLogs, err = newAccessLogService(config.Database, config.AccessLogs); err != nil {
		st.db.Close()
		return nil, err
	}
	s.adminRoutes()
	s.mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { respond(w, 200, map[string]bool{"ok": true}) })
	s.mux.HandleFunc("POST /api/v1/auth/challenge", s.challenge)
	s.mux.HandleFunc("POST /api/v1/auth/login", s.login)
	s.mux.HandleFunc("POST /api/v1/auth/refresh", s.refresh)
	s.mux.HandleFunc("POST /api/v1/auth/logout", s.logout)
	s.mux.HandleFunc("GET /api/v1/auth/session", s.currentSession)
	s.mux.HandleFunc("GET /api/v1/sessions", s.sessions)
	s.mux.HandleFunc("DELETE /api/v1/web-sessions/{id}", s.revokeWebSession)
	s.mux.HandleFunc("GET /api/v1/agents", s.agents)
	s.mux.HandleFunc("GET /api/v1/access-logs", s.consoleAccessLogs(s.adminAccessLogs))
	s.mux.HandleFunc("GET /api/v1/access-logs/rankings", s.consoleAccessLogs(s.adminAccessLogRankings))
	s.mux.HandleFunc("GET /api/v1/access-logs/hour", s.consoleAccessLogs(s.adminAccessLogHour))
	s.mux.HandleFunc("POST /api/v1/agents", s.addAgent)
	s.mux.HandleFunc("POST /api/v1/agents/{id}/requests", s.requestAgent)
	s.mux.HandleFunc("GET /ws/agent", s.agentSocket)
	return s, nil
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	r.Body = http.MaxBytesReader(w, r.Body, 16*1024)
	s.mux.ServeHTTP(w, r)
}

func (s *Server) Close() error {
	if s.accessLogs != nil {
		s.accessLogs.close()
	}
	s.mu.Lock()
	for _, c := range s.online {
		c.close()
	}
	s.mu.Unlock()
	return s.store.db.Close()
}

func respond(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
func reject(w http.ResponseWriter, status int, code string) {
	respond(w, status, map[string]string{"error": code})
}
func decode(w http.ResponseWriter, r *http.Request, value any) bool {
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if d.Decode(value) != nil {
		reject(w, 400, "invalid_request")
		return false
	}
	if d.Decode(new(any)) != io.EOF {
		reject(w, 400, "invalid_request")
		return false
	}
	return true
}

func (s *Server) allow(key string, max int, interval time.Duration) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	for k, b := range s.limits {
		if now.After(b.until) {
			delete(s.limits, k)
		}
	}
	b := s.limits[key]
	if now.After(b.until) {
		b = bucket{until: now.Add(interval)}
	}
	if b.count >= max || len(s.limits) >= 4096 {
		return false
	}
	b.count++
	s.limits[key] = b
	return true
}

func (s *Server) preauth(w http.ResponseWriter, r *http.Request) (proof, bool) {
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
	if !s.allow("auth:"+ip, 12, time.Minute) || !s.allow("auth:global", 30, time.Minute) {
		reject(w, 429, "rate_limited")
		return proof{}, false
	}
	p, err := verifyProof(r, s.config.PublicURL, "", time.Now())
	if err == nil {
		err = s.store.update(func(st *state) error { return consumeProof(st, p, time.Now()) })
	}
	if err != nil {
		reject(w, 401, "invalid_device_proof")
		return proof{}, false
	}
	return p, true
}

type tokens struct {
	SessionID    string `json:"sessionId"`
	DeviceID     string `json:"deviceId"`
	AccessToken  string `json:"accessToken"`
	RefreshToken string `json:"refreshToken"`
	ExpiresAt    string `json:"expiresAt"`
}

func (s *Server) issue(st *state, ss *session) tokens {
	now := time.Now()
	for hash, exp := range ss.Access {
		if exp <= now.Unix() {
			delete(ss.Access, hash)
		}
	}
	access := ss.ID + "." + randomToken()
	exp := now.Add(15 * time.Minute)
	ss.Access[digest(access)] = exp.Unix()
	return tokens{ss.ID, ss.DeviceID, access, refreshToken(s.config.MasterKey, ss.ID, ss.Generation), exp.UTC().Format(time.RFC3339)}
}

func (s *Server) newSession(st *state, d device) tokens {
	for id, ss := range st.Sessions {
		if ss.DeviceID == d.ID {
			delete(st.Sessions, id)
		}
	}
	ss := &session{ID: randomToken(), DeviceID: d.ID, Thumb: d.Thumb, CreatedAt: time.Now().Unix(), Access: map[string]int64{}}
	ss.RefreshHash = digest(refreshToken(s.config.MasterKey, ss.ID, 0))
	st.Sessions[ss.ID] = ss
	return s.issue(st, ss)
}

func (s *Server) refresh(w http.ResponseWriter, r *http.Request) {
	if !s.allow("refresh", 120, time.Minute) {
		reject(w, 429, "rate_limited")
		return
	}
	p, err := verifyProof(r, s.config.PublicURL, "", time.Now())
	if err != nil {
		reject(w, 401, "invalid_device_proof")
		return
	}
	var c struct {
		SessionID    string `json:"sessionId"`
		DeviceID     string `json:"deviceId"`
		RefreshToken string `json:"refreshToken"`
		RotationID   string `json:"rotationId"`
	}
	if !decode(w, r, &c) {
		return
	}
	if len(c.RotationID) < 16 || len(c.RotationID) > 128 {
		reject(w, 400, "invalid_rotation_id")
		return
	}
	var result tokens
	revoked := false
	err = s.store.update(func(st *state) error {
		ss, exists := st.Sessions[c.SessionID]
		if !exists || ss.DeviceID != c.DeviceID || ss.Thumb != p.Thumb || !trustedConsoleState(st, p.Thumb) {
			return errInvalidSession
		}
		if err := consumeProof(st, p, time.Now()); err != nil {
			return err
		}
		hash := digest(c.RefreshToken)
		if equal(hash, ss.RefreshHash) {
			ss.PreviousHash = ss.RefreshHash
			ss.RotationID = c.RotationID
			ss.Generation++
			ss.RefreshHash = digest(refreshToken(s.config.MasterKey, ss.ID, ss.Generation))
		} else if !(equal(hash, ss.PreviousHash) && equal(c.RotationID, ss.RotationID)) {
			delete(st.Sessions, ss.ID)
			revoked = true
			return nil
		}
		// Same rotation ID can recover a response lost in transit, with a fresh DPoP JTI.
		if len(ss.Access) >= 32 {
			ss.Access = map[string]int64{}
		}
		result = s.issue(st, ss)
		return nil
	})
	if errors.Is(err, errProofReplay) {
		reject(w, 401, "invalid_device_proof")
		return
	}
	if err != nil && !errors.Is(err, errInvalidSession) {
		reject(w, 503, "storage_unavailable")
		return
	}
	if err != nil || revoked {
		reject(w, 401, "session_revoked")
		return
	}
	respond(w, 200, result)
}

func (s *Server) authorized(w http.ResponseWriter, r *http.Request) (string, bool) {
	if !s.allow("api", 600, time.Minute) {
		reject(w, 429, "rate_limited")
		return "", false
	}
	auth := strings.SplitN(r.Header.Get("Authorization"), " ", 2)
	if len(auth) != 2 || auth[0] != "DPoP" || len(auth[1]) > 256 {
		reject(w, 401, "invalid_session")
		return "", false
	}
	token := auth[1]
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		reject(w, 401, "invalid_session")
		return "", false
	}
	p, err := verifyProof(r, s.config.PublicURL, token, time.Now())
	if err == nil {
		err = s.store.update(func(st *state) error {
			ss, exists := st.Sessions[parts[0]]
			if !exists || ss.DeviceID != r.Header.Get("X-Hako-Device") || ss.Thumb != p.Thumb || !trustedConsoleState(st, p.Thumb) || ss.Access[digest(token)] <= time.Now().Unix() {
				return errors.New("invalid_session")
			}
			return consumeProof(st, p, time.Now())
		})
	}
	if err != nil {
		reject(w, 401, "invalid_session_or_proof")
		return "", false
	}
	return parts[0], true
}

func (s *Server) currentSession(w http.ResponseWriter, r *http.Request) {
	id, ok := s.authorized(w, r)
	if !ok {
		return
	}
	respond(w, 200, map[string]string{"sessionId": id})
}
func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	id, ok := s.authorized(w, r)
	if !ok {
		return
	}
	if err := s.store.update(func(st *state) error { delete(st.Sessions, id); return nil }); err != nil {
		reject(w, 500, "storage_error")
		return
	}
	respond(w, 200, map[string]bool{"ok": true})
}

type sessionSummary struct {
	ID         string `json:"id"`
	Type       string `json:"type"`
	DeviceID   string `json:"deviceId,omitempty"`
	Browser    string `json:"browser,omitempty"`
	CreatedAt  string `json:"createdAt"`
	LastUsedAt string `json:"lastUsedAt,omitempty"`
	Current    bool   `json:"current"`
}

func (s *Server) sessions(w http.ResponseWriter, r *http.Request) {
	id, ok := s.authorized(w, r)
	if !ok {
		return
	}
	items := []sessionSummary{}
	s.store.inspect(func(st state) {
		for _, ss := range st.Sessions {
			items = append(items, sessionSummary{ID: ss.ID, Type: "console", DeviceID: ss.DeviceID, CreatedAt: time.Unix(ss.CreatedAt, 0).UTC().Format(time.RFC3339), Current: ss.ID == id})
		}
	})
	s.adminMu.Lock()
	for key, ss := range s.adminSessions {
		if adminExpired(ss, time.Now()) || !s.validAdminApprover(ss.ApproverSessionID, ss.ApproverThumb) {
			delete(s.adminSessions, key)
			continue
		}
		items = append(items, sessionSummary{ID: ss.ID, Type: "web", Browser: ss.Browser, CreatedAt: ss.Created.UTC().Format(time.RFC3339), LastUsedAt: ss.LastUsed.UTC().Format(time.RFC3339)})
	}
	s.adminMu.Unlock()
	sort.Slice(items, func(i, j int) bool {
		if items[i].Current != items[j].Current {
			return items[i].Current
		}
		if items[i].CreatedAt != items[j].CreatedAt {
			return items[i].CreatedAt > items[j].CreatedAt
		}
		return items[i].ID < items[j].ID
	})
	respond(w, 200, map[string]any{"sessions": items})
}

func (s *Server) revokeWebSession(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.authorized(w, r); !ok {
		return
	}
	s.adminMu.Lock()
	for key, ss := range s.adminSessions {
		if ss.ID == r.PathValue("id") {
			delete(s.adminSessions, key)
			break
		}
	}
	s.adminMu.Unlock()
	respond(w, 200, map[string]bool{"ok": true})
}

// RevokeConsoles is an operator recovery action; agent keys and owner identity remain intact.
func RevokeConsoles(database string, key []byte) error {
	st, err := openStore(database, key)
	if err != nil {
		return err
	}
	defer st.db.Close()
	return st.update(func(v *state) error { v.Sessions = map[string]*session{}; return nil })
}
