package agent

import (
	"sync"
	"time"
)

type peer struct {
	connection *Connection
	lastSeen   string
}

// Hub tracks live connections separately from the persisted Agent trust registry.
type Hub struct {
	mu    sync.Mutex
	peers map[string]peer
}

func (h *Hub) Lookup(id string) (*Connection, string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	entry := h.peers[id]
	return entry.connection, entry.lastSeen
}

func (h *Hub) Register(id string, connection *Connection) *Connection {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.peers == nil {
		h.peers = make(map[string]peer)
	}
	previous := h.peers[id].connection
	h.peers[id] = peer{connection, now()}
	return previous
}

func (h *Hub) Run(id string, connection *Connection) {
	defer connection.Close()
	defer h.markSeen(id, connection, nil)
	connection.run(func() { h.markSeen(id, connection, connection) })
}

func (h *Hub) markSeen(id string, previous, current *Connection) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.peers[id].connection == previous {
		h.peers[id] = peer{current, now()}
	}
}

func (h *Hub) Remove(id string) {
	h.mu.Lock()
	connection := h.peers[id].connection
	delete(h.peers, id)
	h.mu.Unlock()
	if connection != nil {
		connection.Close()
	}
}

func (h *Hub) Close() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, entry := range h.peers {
		if entry.connection != nil {
			entry.connection.Close()
		}
	}
}

func now() string { return time.Now().UTC().Format(time.RFC3339) }
