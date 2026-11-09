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
)

func TestConsoleSSHRelaysPowerShell(t *testing.T) {
	t.Run("pinned host", func(t *testing.T) { testConsoleSSH(t, true) })
	t.Run("wrong host key", func(t *testing.T) { testConsoleSSH(t, false) })
}

func testConsoleSSH(t *testing.T, correctPin bool) {
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
	agent := f.connectAgentFeatures("PC", false, true)
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
	if !correctPin {
		fingerprint = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	}
	writeAgentFrame(t, console, sshTerminalLogin{
		sshTerminalSize: sshTerminalSize{Columns: 80, Rows: 24},
		Username:        "windows-user", Password: "fixture-password", Fingerprint: fingerprint,
	})
	open := readAgentFrame[sshFrame](t, agent)
	if open.Type != "ssh_open" || open.ID == "" {
		t.Fatalf("unexpected agent tunnel request: %+v", open)
	}
	closed := make(chan error, 1)
	go func() {
		defer local.Close()
		for {
			var frame sshFrame
			if err := agent.ReadJSON(&frame); err != nil {
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
		buf := make([]byte, sshChunk)
		for {
			n, err := local.Read(buf)
			if n > 0 && agent.WriteJSON(sshFrame{Type: "ssh_data", ID: open.ID, Data: buf[:n]}) != nil {
				return
			}
			if err != nil {
				return
			}
		}
	}()
	if correctPin {
		readConsole(websocket.TextMessage, "ssh_ready")
		readConsole(websocket.BinaryMessage, "PS> ")
		if err := console.WriteMessage(websocket.BinaryMessage, []byte("pwd\r")); err != nil {
			t.Fatal(err)
		}
		readConsole(websocket.BinaryMessage, "pwd\r")
	} else {
		readConsole(websocket.TextMessage, "ssh_host_key_mismatch")
		if passwordReceived.Load() {
			t.Fatal("SSH password sent to an unverified host")
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
