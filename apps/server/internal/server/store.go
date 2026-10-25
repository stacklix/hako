package server

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"fmt"
	"sync"

	_ "modernc.org/sqlite"
)

type device struct {
	ID    string `json:"id"`
	Thumb string `json:"thumb"`
}

type session struct {
	ID           string           `json:"id"`
	DeviceID     string           `json:"deviceId"`
	Thumb        string           `json:"thumb"`
	CreatedAt    int64            `json:"createdAt"`
	Generation   int64            `json:"generation"`
	RefreshHash  string           `json:"refreshHash"`
	PreviousHash string           `json:"previousHash"`
	RotationID   string           `json:"rotationId"`
	Access       map[string]int64 `json:"access"`
}

type loginChallenge struct {
	DeviceID string `json:"deviceId"`
	Thumb    string `json:"thumb"`
	Nonce    string `json:"nonce"`
	Expires  int64  `json:"expires"`
}

type state struct {
	Registry   *Registry                 `json:"registry,omitempty"`
	Sessions   map[string]*session       `json:"sessions"`
	Challenges map[string]loginChallenge `json:"challenges"`
	Proofs     map[string]int64          `json:"proofs"`
}

func emptyState() state {
	return state{Sessions: map[string]*session{}, Challenges: map[string]loginChallenge{}, Proofs: map[string]int64{}}
}

// One encrypted, transactional state document is sufficient for a single-owner service.
// The key is mounted separately; copying only the SQLite database does not expose session state.
type store struct {
	mu    sync.Mutex
	db    *sql.DB
	aead  cipher.AEAD
	value state
}

func openStore(path string, key []byte) (*store, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if _, err = db.Exec(`PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id=1), value BLOB NOT NULL)`); err != nil {
		db.Close()
		return nil, err
	}
	s := &store{db: db, aead: aead, value: emptyState()}
	var encrypted []byte
	err = db.QueryRow("SELECT value FROM state WHERE id=1").Scan(&encrypted)
	if err == sql.ErrNoRows {
		return s, nil
	}
	if err != nil {
		db.Close()
		return nil, err
	}
	if len(encrypted) < aead.NonceSize() {
		db.Close()
		return nil, fmt.Errorf("invalid database document")
	}
	plain, err := aead.Open(nil, encrypted[:aead.NonceSize()], encrypted[aead.NonceSize():], []byte("hako-state-v1"))
	if err == nil {
		err = json.Unmarshal(plain, &s.value)
	}
	if err != nil {
		db.Close()
		return nil, fmt.Errorf("cannot decrypt database: %w", err)
	}
	return s, nil
}

func (s *store) update(fn func(*state) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	plain, err := json.Marshal(s.value)
	if err != nil {
		return err
	}
	var next state
	if err = json.Unmarshal(plain, &next); err != nil {
		return err
	}
	if err = fn(&next); err != nil {
		return err
	}
	plain, err = json.Marshal(next)
	if err != nil {
		return err
	}
	nonce := make([]byte, s.aead.NonceSize())
	if _, err = rand.Read(nonce); err != nil {
		return err
	}
	encrypted := s.aead.Seal(nonce, nonce, plain, []byte("hako-state-v1"))
	if _, err = s.db.Exec("INSERT INTO state(id,value) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value", encrypted); err != nil {
		return err
	}
	s.value = next
	return nil
}

func (s *store) inspect(fn func(state)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	fn(s.value)
}
