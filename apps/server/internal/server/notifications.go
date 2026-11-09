package server

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const notificationBodyLimit = 12 * 1024 * 1024

type notificationService struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser
	done  chan struct{}
	proxy *httputil.ReverseProxy
}

func (s *Server) startNotifications() error {
	if s.config.NotificationWorker == "" {
		return nil
	}
	token := randomToken()
	thumbs := make([]string, 0, len(s.config.Consoles))
	for _, device := range s.config.Consoles {
		thumbs = append(thumbs, device.thumb)
	}
	trusted, _ := json.Marshal(thumbs)
	dataDir := s.config.NotificationDataDir
	if dataDir == "" {
		dataDir = filepath.Join(filepath.Dir(s.config.Database), "notifications")
	}
	cmd := exec.Command("node", s.config.NotificationWorker)
	cmd.Env = append(os.Environ(), "HAKO_NOTIFICATION_WORKER_TOKEN="+token, "HAKO_NOTIFICATION_CONSOLES="+string(trusted),
		"HAKO_NOTIFICATION_DATA_DIR="+dataDir)
	cmd.Stderr = os.Stderr
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return err
	}
	if err := cmd.Start(); err != nil {
		_ = stdin.Close()
		_ = stdout.Close()
		return err
	}

	started := make(chan string, 1)
	go func() {
		port, _ := bufio.NewReader(io.LimitReader(stdout, 64)).ReadString('\n')
		started <- strings.TrimSpace(port)
	}()
	var address string
	select {
	case address = <-started:
	case <-time.After(15 * time.Second):
	}
	port, err := strconv.Atoi(address)
	if err != nil || port < 1 || port > 65535 {
		_ = stdin.Close()
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return fmt.Errorf("notification worker did not report a listening port")
	}

	target := &url.URL{Scheme: "http", Host: net.JoinHostPort("127.0.0.1", address)}
	transport := &http.Transport{ResponseHeaderTimeout: 25 * time.Second, IdleConnTimeout: 30 * time.Second, MaxIdleConnsPerHost: 16}
	service := &notificationService{cmd: cmd, stdin: stdin, done: make(chan struct{})}
	service.proxy = &httputil.ReverseProxy{
		Transport: transport,
		Rewrite: func(r *httputil.ProxyRequest) {
			r.SetURL(target)
			for _, name := range []string{"Cookie", "Authorization", "DPoP", "X-Hako-Device", "X-CSRF-Token"} {
				r.Out.Header.Del(name)
			}
			r.Out.Header.Set("X-Hako-Notification-Worker", token)
			if ip := s.loginClientIP(r.In); net.ParseIP(ip) != nil {
				r.Out.Header.Set("X-Forwarded-For", ip)
			}
		},
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, _ error) {
			reject(w, http.StatusServiceUnavailable, "notifications_unavailable")
		},
	}
	go func() {
		_ = cmd.Wait()
		transport.CloseIdleConnections()
		close(service.done)
	}()
	s.notifications = service
	return nil
}

func (s *Server) NotificationsDone() <-chan struct{} {
	if s.notifications == nil {
		return nil
	}
	return s.notifications.done
}

func (s *notificationService) close() {
	_ = s.stdin.Close()
	select {
	case <-s.done:
	case <-time.After(5 * time.Second):
		_ = s.cmd.Process.Kill()
		<-s.done
	}
}

func (s *Server) forwardNotification(w http.ResponseWriter, r *http.Request, route string) {
	if s.notifications == nil {
		reject(w, http.StatusServiceUnavailable, "notifications_unavailable")
		return
	}
	request := r.Clone(r.Context())
	request.URL.Path, request.URL.RawPath = route, ""
	s.notifications.proxy.ServeHTTP(w, request)
}

func (s *Server) notificationRoutes() {
	for _, method := range []string{http.MethodGet, http.MethodPost, http.MethodPatch, http.MethodDelete} {
		s.mux.HandleFunc(method+" /admin/api/notifications/{resource...}", s.admin(s.adminNotifications))
	}
	s.mux.HandleFunc("GET /admin/notifications-ui/{asset...}", s.admin(s.notificationUI))
	s.mux.HandleFunc("POST /webhook/notifications/{token}", s.notificationWebhook)
	s.mux.HandleFunc("GET /webhook/notifications/{token}/{notificationID}", s.notificationWebhook)
	s.mux.HandleFunc("PUT /api/v1/notifications/device", s.registerNotificationDevice)
}

func (s *Server) adminNotifications(w http.ResponseWriter, r *http.Request) {
	resource := r.PathValue("resource")
	group, _, _ := strings.Cut(resource, "/")
	switch group {
	case "overview", "bots", "messages", "webhooks":
	case "events":
		if r.Method != http.MethodGet || resource != "events" {
			http.NotFound(w, r)
			return
		}
		// Reconnect periodically through Hako's session check. Events carry only
		// a refresh signal, so subsequent resource requests still require auth.
		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()
		r = r.WithContext(ctx)
	case "push":
		if r.Method != http.MethodGet || resource != "push/device" {
			http.NotFound(w, r)
			return
		}
	default:
		http.NotFound(w, r)
		return
	}
	s.forwardNotification(w, r, "/api/v1/"+resource)
}

func (s *Server) notificationUI(w http.ResponseWriter, r *http.Request) {
	asset := r.PathValue("asset")
	if asset != "" && asset != "favicon.svg" && !strings.HasPrefix(asset, "assets/") {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("X-Frame-Options", "SAMEORIGIN")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'self'")
	s.forwardNotification(w, r, "/"+asset)
}

func (s *Server) notificationWebhook(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Referrer-Policy", "no-referrer")
	s.forwardNotification(w, r, r.URL.Path)
}

func (s *Server) registerNotificationDevice(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.authorized(w, r); !ok {
		return
	}
	if s.notifications == nil {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	var input struct {
		Token       string `json:"token"`
		Environment string `json:"environment"`
	}
	if !decode(w, r, &input) {
		return
	}
	// authorized already checked the device ID against the registered key and proof.
	body, _ := json.Marshal(map[string]string{
		"deviceId": r.Header.Get("X-Hako-Device"), "token": input.Token, "environment": input.Environment,
	})
	request := r.Clone(r.Context())
	request.Body = io.NopCloser(bytes.NewReader(body))
	request.ContentLength = int64(len(body))
	request.Header.Set("Content-Type", "application/json")
	s.forwardNotification(w, request, "/internal/push/registration")
}
