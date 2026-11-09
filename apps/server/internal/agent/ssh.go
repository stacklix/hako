package agent

import (
	"context"
	"net"
	"sync"
)

const SSHChunk = 4096

type SSHFrame struct {
	Type string `json:"type"`
	ID   string `json:"id"`
	Data []byte `json:"data,omitempty"`
}

type agentSSH struct {
	id    string
	pipe  net.Conn
	input chan []byte
}

func (c *Connection) publishSSH(message Message) {
	c.mu.Lock()
	tunnel := c.ssh
	c.mu.Unlock()
	if tunnel == nil || tunnel.id != message.ID {
		return
	}
	var data []byte
	if message.Type == "ssh_data" {
		data = message.Data
		if len(data) == 0 || len(data) > SSHChunk {
			_ = tunnel.pipe.Close()
			return
		}
	}
	select {
	case tunnel.input <- data:
	default:
		_ = tunnel.pipe.Close()
	}
}

func (c *Connection) OpenSSH(ctx context.Context) (net.Conn, func(), error) {
	client, pipe := net.Pipe()
	tunnel := &agentSSH{id: c.newID(), pipe: pipe, input: make(chan []byte, 32)}
	c.mu.Lock()
	if c.ssh != nil {
		c.mu.Unlock()
		_ = client.Close()
		_ = pipe.Close()
		return nil, nil, ErrBusy
	}
	c.ssh = tunnel
	c.mu.Unlock()

	ctx, cancel := context.WithCancel(ctx)
	var stop sync.Once
	closeTunnel := func() {
		stop.Do(func() {
			cancel()
			_ = client.Close()
			_ = pipe.Close()
			// Retain the slot until close is ordered before the next open.
			select {
			case <-c.done:
			default:
				if c.Send(SSHFrame{Type: "ssh_close", ID: tunnel.id}) != nil {
					c.Close()
				}
			}
			c.mu.Lock()
			c.ssh = nil
			c.mu.Unlock()
		})
	}
	select {
	case <-c.done:
		closeTunnel()
		return nil, nil, net.ErrClosed
	default:
	}
	if err := c.Send(SSHFrame{Type: "ssh_open", ID: tunnel.id}); err != nil {
		c.Close()
		closeTunnel()
		return nil, nil, err
	}
	go func() {
		select {
		case <-ctx.Done():
		case <-c.done:
		}
		_ = pipe.Close()
	}()
	go func() {
		defer pipe.Close()
		for {
			select {
			case <-ctx.Done():
				return
			case data := <-tunnel.input:
				if data == nil {
					return
				}
				if _, err := pipe.Write(data); err != nil {
					return
				}
			}
		}
	}()
	go func() {
		defer pipe.Close()
		buf := make([]byte, SSHChunk)
		for {
			n, err := pipe.Read(buf)
			if n != 0 && c.Send(SSHFrame{Type: "ssh_data", ID: tunnel.id, Data: buf[:n]}) != nil {
				c.Close()
				return
			}
			if err != nil {
				return
			}
		}
	}()
	return client, closeTunnel, nil
}
