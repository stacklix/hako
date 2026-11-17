package server

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestAdminHostEquivalentAuthorities(t *testing.T) {
	for _, test := range []struct {
		public, host string
		allowed      bool
	}{
		{"https://hako.example", "hako.example", true},
		{"https://hako.example", "hako.example:443", true},
		{"https://hako.example", "HAKO.EXAMPLE:443", true},
		{"https://HAKO.EXAMPLE:443", "hako.example", true},
		{"http://localhost", "LOCALHOST:80", true},
		{"http://localhost:80", "localhost", true},
		{"https://[::1]", "[::1]:443", true},
		{"https://hako.example:8443", "HAKO.EXAMPLE:8443", true},
		{"https://hako.example:8443", "hako.example", false},
		{"https://hako.example", "hako.example:444", false},
		{"https://hako.example", "hako.example.attacker.invalid", false},
		{"https://hako.example", "attacker.invalid", false},
		{"https://hako.example", "hako.example.", false},
		{"https://hako.example", "attacker@hako.example", false},
		{"https://hako.example", "hako.example/", false},
		{"https://hako.example", "hako.example?", false},
		{"https://hako.example", "hako.example#", false},
		{"https://hako.example", "hako.example:", false},
		{"https://hako.example", "hako.example:8443:443", false},
		{"https://hako.example", "hako.example\\attacker.invalid", false},
		{"https://hako.example", "", false},
	} {
		t.Run(test.public+"_"+test.host, func(t *testing.T) {
			public, err := url.Parse(test.public)
			if err != nil {
				t.Fatal(err)
			}
			if got := sameAdminHost(test.host, public); got != test.allowed {
				t.Fatalf("sameAdminHost(%q, %q) = %v, want %v", test.host, test.public, got, test.allowed)
			}
		})
	}
}

func TestAdminOriginChecksRemainStrict(t *testing.T) {
	f := newFixture(t, false)
	for _, test := range []struct {
		name, origin, site, host string
		allowed                  bool
	}{
		{"same-origin", f.s.config.PublicURL, "same-origin", "", true},
		{"missing-origin", "", "same-origin", "", false},
		{"null-origin", "null", "same-origin", "", false},
		{"foreign-origin", "https://attacker.invalid", "same-origin", "", false},
		{"cross-site", f.s.config.PublicURL, "cross-site", "", false},
		{"foreign-host", f.s.config.PublicURL, "same-origin", "attacker.invalid", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodPost, f.s.config.PublicURL+"/admin/api/login/requests", strings.NewReader("{}"))
			r.Header.Set("Content-Type", "application/json")
			r.Header.Set("Origin", test.origin)
			r.Header.Set("Sec-Fetch-Site", test.site)
			if test.host != "" {
				r.Host = test.host
			}
			// A forwarded host must never turn an untrusted authority into a valid one.
			r.Header.Set("X-Forwarded-Host", r.URL.Host)
			w := httptest.NewRecorder()
			if got := f.s.adminOrigin(w, r, true); got != test.allowed {
				t.Fatalf("adminOrigin = %v, want %v; response: %s", got, test.allowed, w.Body.String())
			}
		})
	}
}
