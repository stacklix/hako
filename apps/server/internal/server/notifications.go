package server

import (
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"hako/server/internal/notify"
)

const notificationBodyLimit = 12 * 1024 * 1024

func (s *Server) startNotifications() error {
	if s.config.NotificationDataDir == "" {
		return nil
	}
	trusted := make([]string, 0, len(s.config.Consoles))
	for _, console := range s.config.Consoles {
		trusted = append(trusted, console.thumb)
	}
	service, err := notify.New(notify.Config{
		DataDir:         s.config.NotificationDataDir,
		EncryptionKey:   os.Getenv("HAKO_NOTIFICATION_ENCRYPTION_KEY"),
		TrustedConsoles: trusted,
	})
	if err == nil {
		s.notifications = service
	}
	return err
}

func (s *Server) notificationRoutes() {
	for _, method := range []string{http.MethodGet, http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete} {
		s.mux.HandleFunc(method+" /admin/api/notifications/{resource...}", s.admin(s.adminNotifications))
	}
	s.mux.HandleFunc("GET /admin/notifications-ui/{asset...}", s.admin(s.notificationUI))
	s.mux.HandleFunc("POST /webhook/notifications/{token}", s.notificationWebhook)
	s.mux.HandleFunc("GET /webhook/notifications/{token}/{notificationID}", s.notificationWebhook)
	s.mux.HandleFunc("PUT /api/v1/notifications/device", s.registerNotificationDevice)
}

func (s *Server) adminNotifications(w http.ResponseWriter, r *http.Request) {
	if s.notifications == nil {
		reject(w, http.StatusServiceUnavailable, "notifications_unavailable")
		return
	}
	request := notify.WithClientIP(r.Clone(r.Context()), s.loginClientIP(r))
	request.URL.Path, request.URL.RawPath = "/"+r.PathValue("resource"), ""
	s.notifications.ServeAdmin(w, request)
}

func (s *Server) notificationUI(w http.ResponseWriter, r *http.Request) {
	asset := r.PathValue("asset")
	if asset == "" {
		asset = "index.html"
	} else if !fs.ValidPath(asset) || (asset != "favicon.svg" && !strings.HasPrefix(asset, "assets/")) {
		http.NotFound(w, r)
		return
	}
	if s.config.NotificationWebDir == "" {
		reject(w, http.StatusServiceUnavailable, "notification_ui_unavailable")
		return
	}
	file := filepath.Join(s.config.NotificationWebDir, filepath.FromSlash(asset))
	// On Windows a backslash or volume prefix in a URL segment must not be
	// interpreted as a filesystem separator or absolute path.
	if strings.ContainsAny(asset, "\\:") {
		http.NotFound(w, r)
		return
	}
	info, err := os.Stat(file)
	if err != nil || !info.Mode().IsRegular() {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("X-Frame-Options", "SAMEORIGIN")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'self'")
	http.ServeFile(w, r, file)
}

func (s *Server) notificationWebhook(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Referrer-Policy", "no-referrer")
	if s.notifications == nil {
		reject(w, http.StatusServiceUnavailable, "notifications_unavailable")
		return
	}
	ip := s.loginClientIP(r)
	limit := 120
	if r.Method == http.MethodPost {
		limit = 300
	}
	if !s.allow("notification-"+r.Method+":"+ip, limit, time.Minute) {
		w.Header().Set("Retry-After", "60")
		respond(w, http.StatusTooManyRequests, map[string]string{"code": "RATE_LIMITED", "message": "请求过于频繁，请稍后重试"})
		return
	}
	if r.Method == http.MethodPost {
		s.notifications.Submit(w, r, ip)
	} else {
		s.notifications.Status(w, r)
	}
}

func (s *Server) registerNotificationDevice(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.authorized(w, r); !ok {
		return
	}
	if s.notifications == nil {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	s.notifications.RegisterDevice(w, r, r.Header.Get("X-Hako-Device"))
}
