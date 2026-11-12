package server

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/gorilla/websocket"
	"golang.org/x/crypto/ssh"

	"hako/server/internal/agent"
)

var errSSHHostKey = errors.New("SSH host key does not match")
var errSSHHostKeyRequired = errors.New("SSH host key requires confirmation")

type sshOutput func([]byte) error

func (write sshOutput) Write(data []byte) (int, error) {
	for offset := 0; offset < len(data); offset += agent.SSHChunk {
		if err := write(data[offset:min(offset+agent.SSHChunk, len(data))]); err != nil {
			return offset, err
		}
	}
	return len(data), nil
}

type sshTerminalSize struct {
	Columns int `json:"columns"`
	Rows    int `json:"rows"`
}

func (s sshTerminalSize) valid() bool {
	return s.Columns >= 2 && s.Columns <= 1000 && s.Rows >= 2 && s.Rows <= 1000
}

type sshTerminalLogin struct {
	sshTerminalSize
	Username    string `json:"username"`
	Password    string `json:"password"`
	Fingerprint string `json:"fingerprint"`
}

func (l sshTerminalLogin) valid() bool {
	hash, ok := strings.CutPrefix(l.Fingerprint, "SHA256:")
	decoded, err := base64.RawStdEncoding.Strict().DecodeString(hash)
	return l.sshTerminalSize.valid() && len(l.Username) > 0 && len(l.Username) <= 256 &&
		!strings.ContainsFunc(l.Username, unicode.IsControl) && len(l.Password) > 0 && len(l.Password) <= 4096 &&
		(l.Fingerprint == "" || (ok && err == nil && len(decoded) == 32))
}

func (s *Server) streamSSH(ctx context.Context, agentID string, ws *websocket.Conn, valid func() bool) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var writing sync.Mutex
	write := func(kind int, data []byte) error {
		writing.Lock()
		defer writing.Unlock()
		_ = ws.SetWriteDeadline(time.Now().Add(5 * time.Second))
		return ws.WriteMessage(kind, data)
	}
	control := func(state string) error { return write(websocket.TextMessage, []byte(state)) }
	if !valid() {
		return
	}
	peer, _ := s.agentHub.Lookup(agentID)
	if peer == nil {
		_ = control("agent_offline")
		return
	}
	if !peer.HasSSHTunnel() {
		_ = control("ssh_unsupported")
		return
	}
	if control("ssh_login") != nil {
		return
	}
	ws.SetReadLimit(16 * 1024)
	_ = ws.SetReadDeadline(time.Now().Add(10 * time.Second))
	kind, first, err := ws.ReadMessage()
	var login sshTerminalLogin
	if err != nil || kind != websocket.TextMessage || !decodeJSON(bytes.NewReader(first), &login) || !login.valid() {
		_ = control("ssh_invalid_login")
		return
	}
	if !valid() {
		return
	}
	_ = ws.SetReadDeadline(time.Now().Add(45 * time.Second))
	ws.SetPongHandler(func(string) error { return ws.SetReadDeadline(time.Now().Add(45 * time.Second)) })
	type command struct {
		input []byte
		size  sshTerminalSize
	}
	commands := make(chan command, 64)
	go func() {
		defer cancel()
		for {
			kind, data, err := ws.ReadMessage()
			if err != nil || !valid() {
				return
			}
			var next command
			switch kind {
			case websocket.BinaryMessage:
				if len(data) == 0 || len(data) > agent.SSHChunk {
					return
				}
				next.input = data
			case websocket.TextMessage:
				if !decodeJSON(bytes.NewReader(data), &next.size) || !next.size.valid() {
					return
				}
			default:
				return
			}
			select {
			case commands <- next:
			default:
				return
			}
		}
	}()

	raw, closeTunnel, err := peer.OpenSSH(ctx)
	if err != nil {
		if errors.Is(err, agent.ErrBusy) {
			_ = control("ssh_busy")
		} else {
			_ = control("ssh_unavailable")
		}
		return
	}
	defer closeTunnel()
	_ = raw.SetDeadline(time.Now().Add(12 * time.Second))
	clientConn, channels, requests, err := ssh.NewClientConn(raw, agentID, &ssh.ClientConfig{
		User:              login.Username,
		Auth:              []ssh.AuthMethod{ssh.Password(login.Password)},
		HostKeyAlgorithms: []string{ssh.KeyAlgoED25519, ssh.KeyAlgoECDSA256, ssh.KeyAlgoRSASHA256, ssh.KeyAlgoRSASHA512},
		HostKeyCallback: func(_ string, _ net.Addr, key ssh.PublicKey) error {
			if login.Fingerprint == "" {
				if !valid() {
					return net.ErrClosed
				}
				data, _ := json.Marshal(map[string]string{
					"type": "ssh_host_key", "fingerprint": ssh.FingerprintSHA256(key),
				})
				if err := write(websocket.TextMessage, data); err != nil {
					return err
				}
				// Stop before password authentication. Confirmation opens a new
				// connection pinned to this key, so no tunnel waits on the user.
				return errSSHHostKeyRequired
			}
			if ssh.FingerprintSHA256(key) != login.Fingerprint {
				return errSSHHostKey
			}
			return nil
		},
	})
	if err != nil {
		switch {
		case errors.Is(err, errSSHHostKeyRequired):
			return
		case errors.Is(err, errSSHHostKey):
			_ = control("ssh_host_key_mismatch")
		case errors.Is(err, io.EOF), errors.Is(err, io.ErrClosedPipe), errors.Is(err, net.ErrClosed):
			_ = control("ssh_unavailable")
		default:
			_ = control("ssh_failed")
		}
		return
	}
	client := ssh.NewClient(clientConn, channels, requests)
	defer client.Close()
	session, err := client.NewSession()
	if err != nil {
		_ = control("ssh_failed")
		return
	}
	stdin, err := session.StdinPipe()
	if err != nil || session.RequestPty("xterm-256color", login.Rows, login.Columns, ssh.TerminalModes{}) != nil {
		_ = control("ssh_failed")
		return
	}
	ready := make(chan struct{})
	output := sshOutput(func(data []byte) error {
		select {
		case <-ready:
		case <-ctx.Done():
			return ctx.Err()
		}
		if !valid() {
			cancel()
			return net.ErrClosed
		}
		if err := write(websocket.BinaryMessage, data); err != nil {
			cancel()
			return err
		}
		return nil
	})
	session.Stdout, session.Stderr = output, output
	if err := session.Start("powershell.exe -NoLogo"); err != nil {
		_ = control("ssh_failed")
		return
	}
	if !valid() || control("ssh_ready") != nil {
		return
	}
	close(ready)
	_ = raw.SetDeadline(time.Time{})

	go func() {
		defer cancel()
		for {
			select {
			case <-ctx.Done():
				return
			case next := <-commands:
				if !valid() {
					return
				}
				var err error
				if next.input != nil {
					_, err = stdin.Write(next.input)
				} else {
					err = session.WindowChange(next.size.Rows, next.size.Columns)
				}
				if err != nil {
					return
				}
			}
		}
	}()
	ended := make(chan struct{})
	go func() {
		_ = session.Wait()
		close(ended)
	}()
	heartbeat := time.NewTicker(15 * time.Second)
	defer heartbeat.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ended:
			if valid() {
				_ = control("ssh_ended")
			}
			return
		case <-heartbeat.C:
			if !valid() || ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second)) != nil {
				return
			}
		}
	}
}
