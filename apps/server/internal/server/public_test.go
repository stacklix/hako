package server

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPublicPagesWithoutLogin(t *testing.T) {
	f := newFixture(t, false)
	for _, page := range []struct{ path, title, contentType string }{
		{"/", "设备、代码与日常数据", "text/html"},
		{"/privacy", "隐私政策", "text/html"},
		{"/terms", "服务条款", "text/html"},
		{"/public/site.css", "prefers-color-scheme", "text/css"},
		{"/public/mark.svg", "<svg", "image/svg+xml"},
		{"/public/sora-logo.svg", "<svg", "image/svg+xml"},
	} {
		t.Run(page.path, func(t *testing.T) {
			response, err := f.http.Client().Get(f.http.URL + page.path)
			if err != nil {
				t.Fatal(err)
			}
			defer response.Body.Close()
			data, _ := io.ReadAll(response.Body)
			for _, privatePath := range []string{"/admin", "/consilium"} {
				if strings.Contains(string(data), privatePath) {
					t.Errorf("public content exposes management path %s", privatePath)
				}
			}
			if response.StatusCode != http.StatusOK || !strings.Contains(response.Header.Get("Content-Type"), page.contentType) || !strings.Contains(string(data), page.title) {
				t.Fatalf("public response: %d %q %s", response.StatusCode, response.Header.Get("Content-Type"), data)
			}
			if response.Header.Get("Set-Cookie") != "" || !strings.Contains(response.Header.Get("Content-Security-Policy"), "default-src 'none'") {
				t.Fatal("public pages must not create login sessions or load active third-party content")
			}
			if page.contentType == "text/html" {
				for _, required := range []string{`href="/"`, `href="/privacy"`, `href="/terms"`, "xcamel@yeah.net", `rel="canonical" href="` + f.s.config.PublicURL + page.path + `"`} {
					if !strings.Contains(string(data), required) {
						t.Errorf("missing %s", required)
					}
				}
				if strings.Contains(string(data), "<script") {
					t.Fatal("policy pages must render without JavaScript")
				}
			}
			head, err := f.http.Client().Head(f.http.URL + page.path)
			if err != nil {
				t.Fatal(err)
			}
			defer head.Body.Close()
			headBody, _ := io.ReadAll(head.Body)
			if head.StatusCode != http.StatusOK || len(headBody) != 0 {
				t.Fatal("HEAD did not preserve public access without a body")
			}
		})
	}
	privacy := httptest.NewRecorder()
	f.s.ServeHTTP(privacy, httptest.NewRequest(http.MethodGet, "/privacy", nil))
	for _, disclosure := range []string{"drive.file", "系统钥匙串", "不经 Hako 后端转发", "Limited Use", "撤销 Google 授权", "不会自动删除远端文件", "备份 ZIP 本身不额外加密"} {
		if !strings.Contains(privacy.Body.String(), disclosure) {
			t.Errorf("missing data-use disclosure %q", disclosure)
		}
	}
}

func TestOldAdminNamespaceDoesNotRevealControlRoom(t *testing.T) {
	f := newFixture(t, false)
	for _, method := range []string{http.MethodGet, http.MethodHead, http.MethodPost} {
		for _, path := range []string{"/admin", "/admin/", "/admin/agents", "/admin/app.js", "/admin/style.css", "/admin/sora-logo.svg", "/admin/api/session", "/admin/api/login/requests", "/admin/notifications-ui/"} {
			response := httptest.NewRecorder()
			f.s.ServeHTTP(response, httptest.NewRequest(method, f.s.config.PublicURL+path, nil))
			if response.Code != http.StatusNotFound || response.Header().Get("Location") != "" || strings.Contains(response.Body.String(), "/consilium") {
				t.Errorf("old namespace remains discoverable: %s %s: %d %q", method, path, response.Code, response.Header().Get("Location"))
			}
		}
	}
}

func TestPublicRoutesAreExactAndDoNotExposePrivateAPIs(t *testing.T) {
	f := newFixture(t, false)
	for _, request := range []struct {
		method, path string
		status       int
	}{
		{http.MethodGet, "/missing", http.StatusNotFound},
		{http.MethodGet, "/privacy/missing", http.StatusNotFound},
		{http.MethodGet, "/public/pages.html", http.StatusNotFound},
		{http.MethodGet, "/public/", http.StatusNotFound},
		{http.MethodPost, "/privacy", http.StatusMethodNotAllowed},
		{http.MethodGet, "/api/v1/agents", http.StatusUnauthorized},
		{http.MethodGet, "/consilium/api/session", http.StatusUnauthorized},
	} {
		response := httptest.NewRecorder()
		f.s.ServeHTTP(response, httptest.NewRequest(request.method, f.s.config.PublicURL+request.path, nil))
		if response.Code != request.status {
			t.Errorf("%s %s = %d, want %d", request.method, request.path, response.Code, request.status)
		}
	}
	request := httptest.NewRequest(http.MethodGet, "https://untrusted.example/privacy", nil)
	response := httptest.NewRecorder()
	f.s.ServeHTTP(response, request)
	if strings.Contains(response.Body.String(), "untrusted.example") || !strings.Contains(response.Body.String(), f.s.config.PublicURL+"/privacy") {
		t.Fatal("canonical URL trusted the request Host instead of configured public origin")
	}
}
