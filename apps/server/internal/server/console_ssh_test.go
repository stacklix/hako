package server

import (
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"errors"
	"io"
	"net"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"golang.org/x/crypto/ssh"

	"hako/server/internal/agent"
)

func TestConsoleSSHRelaysPowerShell(t *testing.T) {
	t.Run("pinned host", func(t *testing.T) { testConsoleSSH(t, "pinned") })
	t.Run("wrong host key", func(t *testing.T) { testConsoleSSH(t, "mismatch") })
	t.Run("first connection", func(t *testing.T) { testConsoleSSH(t, "discovery") })
}

func testConsoleSSH(t *testing.T, mode string) {
	f := newFixture(t, true)
	const path = "/ws/console/agents/terminal/PC"
	if ws, response, err := dialConsoleAgentSocket(f, path, false, ""); err == nil || response == nil || response.StatusCode != http.StatusUnauthorized {
		if ws != nil {
			ws.Close()
		}
		t.Fatalf("terminal accepted an unauthenticated request: %v, %v", response, err)
	} else {
		response.Body.Close()
	}
	peer := f.connectAgentFeatures("PC", false, true)
	console, _, err := dialConsoleAgentSocket(f, path, true, "")
	if err != nil {
		t.Fatal(err)
	}
	defer console.Close()
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(key)
	if err != nil {
		t.Fatal(err)
	}
	var passwordReceived atomic.Bool
	config := &ssh.ServerConfig{
		PasswordCallback: func(meta ssh.ConnMetadata, password []byte) (*ssh.Permissions, error) {
			passwordReceived.Store(true)
			if meta.User() != "windows-user" || string(password) != "fixture-password" {
				return nil, errors.New("invalid SSH credentials")
			}
			return nil, nil
		},
	}
	// OpenSSH can advertise several host keys. Prefer the Ed25519 key shown by
	// the device setup instructions even when an ECDSA key is also available.
	alternateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	alternate, err := ssh.NewSignerFromKey(alternateKey)
	if err != nil {
		t.Fatal(err)
	}
	config.AddHostKey(alternate)
	config.AddHostKey(signer)
	local, host := net.Pipe()
	defer local.Close()
	defer host.Close()
	_ = host.SetDeadline(time.Now().Add(10 * time.Second))
	go serveTestSSH(host, config)
	readConsole := func(expectedKind int, expected string) {
		t.Helper()
		_ = console.SetReadDeadline(time.Now().Add(5 * time.Second))
		kind, data, err := console.ReadMessage()
		if err != nil || kind != expectedKind || string(data) != expected {
			t.Fatalf("expected SSH frame %q, got kind %d %q (%v)", expected, kind, data, err)
		}
	}
	readConsole(websocket.TextMessage, "ssh_login")
	fingerprint := ssh.FingerprintSHA256(signer.PublicKey())
	if mode == "mismatch" {
		fingerprint = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	} else if mode == "discovery" {
		fingerprint = ""
	}
	writeAgentFrame(t, console, sshTerminalLogin{
		sshTerminalSize: sshTerminalSize{Columns: 80, Rows: 24},
		Username:        "windows-user", Password: "fixture-password", Fingerprint: fingerprint,
	})
	open := readAgentFrame[agent.SSHFrame](t, peer)
	if open.Type != "ssh_open" || open.ID == "" {
		t.Fatalf("unexpected agent tunnel request: %+v", open)
	}
	closed := make(chan error, 1)
	go func() {
		defer local.Close()
		for {
			var frame agent.SSHFrame
			if err := peer.ReadJSON(&frame); err != nil {
				closed <- err
				return
			}
			if frame.ID != open.ID || (frame.Type != "ssh_close" && frame.Type != "ssh_data") {
				closed <- errors.New("unexpected tunnel frame")
				return
			}
			if frame.Type == "ssh_close" {
				closed <- nil
				return
			}
			if _, err := local.Write(frame.Data); err != nil {
				closed <- err
				return
			}
		}
	}()
	go func() {
		buf := make([]byte, agent.SSHChunk)
		for {
			n, err := local.Read(buf)
			if n > 0 && peer.WriteJSON(agent.SSHFrame{Type: "ssh_data", ID: open.ID, Data: buf[:n]}) != nil {
				return
			}
			if err != nil {
				return
			}
		}
	}()
	if mode == "pinned" {
		readConsole(websocket.TextMessage, "ssh_ready")
		readConsole(websocket.BinaryMessage, "PS> ")
		if err := console.WriteMessage(websocket.BinaryMessage, []byte("pwd\r")); err != nil {
			t.Fatal(err)
		}
		readConsole(websocket.BinaryMessage, "pwd\r")
	} else if mode == "mismatch" {
		readConsole(websocket.TextMessage, "ssh_host_key_mismatch")
	} else {
		var offer struct {
			Type        string `json:"type"`
			Fingerprint string `json:"fingerprint"`
		}
		if err := console.ReadJSON(&offer); err != nil {
			t.Fatal(err)
		}
		if offer.Type != "ssh_host_key" || offer.Fingerprint != ssh.FingerprintSHA256(signer.PublicKey()) {
			t.Fatalf("incorrect host key offer: %+v", offer)
		}
		if _, _, err := console.ReadMessage(); err == nil {
			t.Fatal("discovery kept the terminal open before confirmation")
		}
	}
	console.Close()
	select {
	case err := <-closed:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("agent tunnel remained open after console disconnected")
	}
	if mode != "pinned" && passwordReceived.Load() {
		t.Fatal("SSH password sent to an unverified host")
	}
	if mode == "discovery" {
		// The user may spend any amount of time reviewing the fingerprint.
		// Probe completion must release the device's single terminal slot.
		next, _, err := dialConsoleAgentSocket(f, path, true, "")
		if err != nil {
			t.Fatal(err)
		}
		defer next.Close()
		_ = next.SetReadDeadline(time.Now().Add(5 * time.Second))
		if _, _, err := next.ReadMessage(); err != nil {
			t.Fatal(err)
		}
		writeAgentFrame(t, next, sshTerminalLogin{
			sshTerminalSize: sshTerminalSize{Columns: 80, Rows: 24},
			Username:        "windows-user", Password: "fixture-password", Fingerprint: ssh.FingerprintSHA256(signer.PublicKey()),
		})
		_ = peer.SetReadDeadline(time.Now().Add(5 * time.Second))
		if frame := readAgentFrame[agent.SSHFrame](t, peer); frame.Type != "ssh_open" || frame.ID == open.ID {
			t.Fatalf("probe did not release terminal slot: %+v", frame)
		}
	}
}

func TestSSHLoginFingerprintValidation(t *testing.T) {
	login := sshTerminalLogin{
		sshTerminalSize: sshTerminalSize{Columns: 80, Rows: 24},
		Username:        "windows-user", Password: "fixture-password",
	}
	for _, fingerprint := range []string{"", "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"} {
		login.Fingerprint = fingerprint
		if !login.valid() {
			t.Fatalf("valid fingerprint rejected: %q", fingerprint)
		}
	}
	for _, fingerprint := range []string{" ", "SHA256:bad", "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "MD5:abcd"} {
		login.Fingerprint = fingerprint
		if login.valid() {
			t.Fatalf("malformed fingerprint accepted: %q", fingerprint)
		}
	}
}

func serveTestSSH(host net.Conn, config *ssh.ServerConfig) {
	conn, channels, requests, err := ssh.NewServerConn(host, config)
	if err != nil {
		return
	}
	defer conn.Close()
	go ssh.DiscardRequests(requests)
	request, ok := <-channels
	if !ok || request.ChannelType() != "session" {
		return
	}
	session, messages, err := request.Accept()
	if err != nil {
		return
	}
	defer session.Close()
	pty := false
	for message := range messages {
		switch message.Type {
		case "pty-req":
			pty = true
			_ = message.Reply(true, nil)
		case "exec":
			var command struct{ Command string }
			if !pty || ssh.Unmarshal(message.Payload, &command) != nil || command.Command != "powershell.exe -NoLogo" {
				_ = message.Reply(false, nil)
				return
			}
			_ = message.Reply(true, nil)
			_, _ = session.Write([]byte("PS> "))
			_, _ = io.Copy(session, session)
			return
		default:
			_ = message.Reply(false, nil)
		}
	}
}
