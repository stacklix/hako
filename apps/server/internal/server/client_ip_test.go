package server

import (
	"net/http/httptest"
	"testing"
)

func TestLoginClientIP(t *testing.T) {
	for _, tc := range []struct {
		name, trusted, remote, forwarded, want string
	}{
		{"direct IPv4", "", "198.51.100.12:54321", "", "198.51.100.12"},
		{"direct IPv6", "", "[2001:db8::12]:54321", "", "2001:db8::12"},
		{"mapped IPv4", "", "[::ffff:198.51.100.12]:54321", "", "198.51.100.12"},
		{"no port", "", "198.51.100.12", "", "198.51.100.12"},
		{"untrusted header", "", "198.51.100.12:54321", "203.0.113.99", "198.51.100.12"},
		{"different proxy", "127.0.0.1", "198.51.100.12:54321", "203.0.113.99", "198.51.100.12"},
		{"host proxy", "127.0.0.1, ::1", "127.0.0.1:1234", "198.51.100.12", "198.51.100.12"},
		{"Docker proxy", "172.18.0.1/32", "172.18.0.1:1234", "2001:db8::12", "2001:db8::12"},
		{"proxy chain", "127.0.0.1,10.0.0.0/24", "127.0.0.1:1234", "198.51.100.12, 10.0.0.2", "198.51.100.12"},
		{"spoofed prefix", "127.0.0.1", "127.0.0.1:1234", "203.0.113.99, 198.51.100.12", "198.51.100.12"},
		{"missing header", "127.0.0.1", "127.0.0.1:1234", "", "127.0.0.1"},
		{"malformed header", "127.0.0.1", "127.0.0.1:1234", "not-an-ip", "127.0.0.1"},
		{"malformed chain", "127.0.0.1,10.0.0.0/24", "127.0.0.1:1234", "invalid, 10.0.0.2", "127.0.0.1"},
		{"unknown peer", "127.0.0.1", "invalid", "198.51.100.12", "未知"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			proxies, err := parseTrustedProxies(tc.trusted)
			if err != nil {
				t.Fatal(err)
			}
			s := &Server{trustedProxies: proxies}
			r := httptest.NewRequest("POST", "/admin/api/login/requests", nil)
			r.RemoteAddr = tc.remote
			r.Header.Set("X-Forwarded-For", tc.forwarded)
			if got := s.loginClientIP(r); got != tc.want {
				t.Fatalf("source IP = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestTrustedProxiesRejectInvalidConfiguration(t *testing.T) {
	for _, value := range []string{"*", "localhost", "127.0.0.1,", "192.0.2.0/33", "fe80::1%eth0"} {
		if _, err := New(Config{PublicURL: "https://monitor.example.com", Username: "owner", MasterKey: make([]byte, 32), TrustedProxies: value}); err == nil {
			t.Fatalf("invalid proxy configuration accepted: %q", value)
		}
	}
}

func TestBrowserLabelIncludesIOSBrowsers(t *testing.T) {
	for _, tc := range []struct{ ua, want string }{
		{"Mozilla/5.0 Chrome/130.0 Safari/537.36", "Chrome"},
		{"Mozilla/5.0 (iPhone) CriOS/130.0 Mobile/15E148 Safari/604.1", "Chrome"},
		{"Mozilla/5.0 (iPhone) FxiOS/130.0 Mobile/15E148 Safari/605.1.15", "Firefox"},
		{"Mozilla/5.0 (iPhone) EdgiOS/130.0 Mobile/15E148 Safari/605.1.15", "Edge"},
		{"Mozilla/5.0 Chrome/130.0 Safari/537.36 Edg/130.0", "Edge"},
		{"Mozilla/5.0 Chrome/130.0 Safari/537.36 EdgA/130.0", "Edge"},
		{"Mozilla/5.0 Firefox/130.0", "Firefox"},
		{"Mozilla/5.0 Version/18.0 Mobile/15E148 Safari/604.1", "Safari"},
		{"", "网页浏览器"},
	} {
		if got := browserLabel(tc.ua); got != tc.want {
			t.Fatalf("browserLabel(%q) = %q, want %q", tc.ua, got, tc.want)
		}
	}
}
