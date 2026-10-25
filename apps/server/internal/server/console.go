package server

import (
	"errors"
	"net/http"
	"time"
)

type ConsoleConfig struct {
	Name          string `json:"name"`
	PublicKeyFile string `json:"publicKeyFile"`
	PublicKeyPEM  string `json:"publicKeyPem,omitempty"`
	thumb         string
}

func (s *Server) trustedConsole(thumb string) bool {
	for _, c := range s.registry.Load().Consoles {
		if equal(c.thumb, thumb) {
			return true
		}
	}
	return false
}

func (s *Server) challenge(w http.ResponseWriter, r *http.Request) {
	p, ok := s.preauth(w, r)
	if !ok {
		return
	}
	var c struct {
		Username string `json:"username"`
		DeviceID string `json:"deviceId"`
	}
	if !decode(w, r, &c) {
		return
	}
	if !equal(c.Username, s.config.Username) || c.DeviceID != p.Thumb || !s.trustedConsole(p.Thumb) {
		reject(w, 401, "device_not_registered")
		return
	}
	id, nonce := randomToken(), randomToken()
	err := s.store.update(func(st *state) error {
		if !trustedConsoleState(st, p.Thumb) {
			return errors.New("device_not_registered")
		}
		for id, ch := range st.Challenges {
			if ch.Expires < time.Now().Unix() {
				delete(st.Challenges, id)
			}
		}
		if len(st.Challenges) >= 100 {
			return errors.New("too_many_challenges")
		}
		st.Challenges[id] = loginChallenge{DeviceID: c.DeviceID, Thumb: p.Thumb, Nonce: nonce, Expires: time.Now().Add(10 * time.Second).Unix()}
		return nil
	})
	if err != nil {
		reject(w, 503, "challenge_unavailable")
		return
	}
	respond(w, 200, map[string]string{"challengeId": id, "nonce": nonce})
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	p, ok := s.preauth(w, r)
	if !ok {
		return
	}
	var c struct {
		Username    string `json:"username"`
		DeviceID    string `json:"deviceId"`
		ChallengeID string `json:"challengeId"`
	}
	if !decode(w, r, &c) {
		return
	}
	var result tokens
	err := s.store.update(func(st *state) error {
		ch, exists := st.Challenges[c.ChallengeID]
		if !exists || ch.Expires < time.Now().Unix() || ch.DeviceID != c.DeviceID || c.DeviceID != p.Thumb || ch.Thumb != p.Thumb || !equal(ch.Nonce, p.Nonce) || !equal(c.Username, s.config.Username) || !trustedConsoleState(st, p.Thumb) {
			return errors.New("invalid_login")
		}
		delete(st.Challenges, c.ChallengeID)
		result = s.newSession(st, device{c.DeviceID, p.Thumb})
		return nil
	})
	if err != nil {
		reject(w, 401, "invalid_login_challenge")
		return
	}
	respond(w, 200, result)
}
