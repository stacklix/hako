package server

import (
	"context"
	"net"
	"sync"
)

const sshChunk = 4096

type sshFrame struct {
	Type string `json:"type"`
	ID   string `json:"id"`
	Data []byte `json:"data,omitempty"`
}

type agentSSH struct {
	id    string
	pipe  net.Conn
	input chan []byte
}

func (c *agentConnection) publishSSH(message agentMessage) {
	c.mu.Lock()
	tunnel := c.ssh
	c.mu.Unlock()
	if tunnel == nil || tunnel.id != message.ID {
		return
	}
	var data []byte
	if message.Type == "ssh_data" {
		data = message.Data
		if len(data) == 0 || len(data) > sshChunk {
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

func (c *agentConnection) openSSH(ctx context.Context) (net.Conn, func(), error) {
	client, pipe := net.Pipe()
	tunnel := &agentSSH{id: randomToken(), pipe: pipe, input: make(chan []byte, 32)}
	c.mu.Lock()
	if c.ssh != nil {
		c.mu.Unlock()
		_ = client.Close()
		_ = pipe.Close()
		return nil, nil, errAgentBusy
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
				if c.send(sshFrame{Type: "ssh_close", ID: tunnel.id}) != nil {
					c.close()
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
	if err := c.send(sshFrame{Type: "ssh_open", ID: tunnel.id}); err != nil {
		c.close()
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
		buf := make([]byte, sshChunk)
		for {
			n, err := pipe.Read(buf)
			if n != 0 && c.send(sshFrame{Type: "ssh_data", ID: tunnel.id, Data: buf[:n]}) != nil {
				c.close()
				return
			}
			if err != nil {
				return
			}
		}
	}()
	return client, closeTunnel, nil
}
