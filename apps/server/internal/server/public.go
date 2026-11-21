package server

import (
	"bytes"
	"embed"
	"html/template"
	"net/http"
	"time"
)

//go:embed public/*
var publicFiles embed.FS

var publicTemplates = template.Must(template.ParseFS(publicFiles, "public/pages.html"))

func (s *Server) publicRoutes() {
	for _, page := range []struct{ path, name, title, description string }{
		{"/", "home", "让工具彼此连接", "Hako 将设备管理、代码工坊、投资记账与可选的数据备份整合在一个入口。"},
		{"/privacy", "privacy", "隐私政策", "了解 Hako 如何处理应用数据、Google Drive 授权及备份，以及如何撤回授权和删除数据。"},
		{"/terms", "terms", "服务条款", "使用 Hako 应用、Sora 后端及可选备份功能时适用的服务条款与联系方式。"},
	} {
		pattern := "GET " + page.path
		if page.path == "/" {
			pattern = "GET /{$}"
		}
		s.mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
			var body bytes.Buffer
			err := publicTemplates.ExecuteTemplate(&body, page.name, struct {
				Page, Title, Description, Canonical, Email string
			}{page.name, page.title, page.description, s.config.PublicURL + page.path, "xcamel@yeah.net"})
			if err != nil {
				http.Error(w, "Page unavailable", http.StatusInternalServerError)
				return
			}
			publicHeaders(w)
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			http.ServeContent(w, r, page.name+".html", time.Time{}, bytes.NewReader(body.Bytes()))
		})
	}
	for route, file := range map[string]string{"/public/site.css": "site.css", "/public/mark.svg": "mark.svg"} {
		s.mux.HandleFunc("GET "+route, func(w http.ResponseWriter, r *http.Request) {
			data, err := publicFiles.ReadFile("public/" + file)
			if err != nil {
				http.NotFound(w, r)
				return
			}
			publicHeaders(w)
			http.ServeContent(w, r, file, time.Time{}, bytes.NewReader(data))
		})
	}
}

func publicHeaders(w http.ResponseWriter) {
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Frame-Options", "DENY")
}
