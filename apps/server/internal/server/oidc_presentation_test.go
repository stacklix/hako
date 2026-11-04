package server

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	qrcode "github.com/skip2/go-qrcode"
)

func TestOIDCConsentPresentation(t *testing.T) {
	data := map[string]any{"Name": "<script>alert(1)</script>", "Origin": "https://client.example", "Scope": "openid", "Profile": false, "Code": "123456", "Status": "等待手机确认", "Expires": time.Now().Add(90 * time.Second).UnixMilli(), "QR": "/preview-qr.png", "DeepLink": "hako://web-login?v=3", "Complete": "/preview-complete", "CSRF": "preview-only"}
	var page bytes.Buffer
	if err := oidcPageTemplate.Execute(&page, data); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(page.String(), "<script>alert(1)</script>") || strings.Contains(page.String(), "用于显示你的个人资料") || !strings.Contains(page.String(), "用于识别你的 Hako 账号") {
		t.Fatal("consent must escape application names and describe only requested identity")
	}
	// Optional preview artifacts use synthetic data, never a live login or Cookie.
	if dir := os.Getenv("HAKO_OIDC_PREVIEW"); dir != "" {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
		data["Name"], data["Scope"], data["Profile"] = "headplane", "openid profile", true
		page.Reset()
		if err := oidcPageTemplate.Execute(&page, data); err != nil {
			t.Fatal(err)
		}
		write := func(name string, content []byte) {
			if err := os.WriteFile(filepath.Join(dir, name), content, 0600); err != nil {
				t.Fatal(err)
			}
		}
		write("page.html", page.Bytes())
		png, err := qrcode.Encode("HAKO DESIGN PREVIEW - NOT A LOGIN REQUEST", qrcode.Medium, -5)
		if err != nil {
			t.Fatal(err)
		}
		write("qr.png", png)
	}
}
