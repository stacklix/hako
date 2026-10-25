package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"hako/server/internal/server"
)

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}
func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}
func createSecret(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return fmt.Errorf("refusing to overwrite secret %s: %w", path, err)
	}
	_, err = f.WriteString(base64.RawURLEncoding.EncodeToString(b) + "\n")
	closeErr := f.Close()
	if err != nil {
		return err
	}
	return closeErr
}
func run() error {
	dataDir := env("HAKO_DATA_DIR", "./data")
	keyPath := env("HAKO_MASTER_KEY_FILE", "./secrets/master.key")
	if len(os.Args) > 1 && os.Args[1] != "init" && os.Args[1] != "revoke-consoles" {
		return fmt.Errorf("unknown command; supported commands: init, revoke-consoles")
	}
	if len(os.Args) > 1 && os.Args[1] == "init" {
		if err := createSecret(keyPath); err != nil {
			return err
		}
		fmt.Println("Created master key file. Keep it private and back it up with the database.")
		return nil
	}
	keyText, err := os.ReadFile(keyPath)
	if err != nil {
		return err
	}
	key, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(string(keyText)))
	if err != nil {
		return err
	}
	if err = os.MkdirAll(dataDir, 0700); err != nil {
		return err
	}
	database := filepath.Join(dataDir, "hako.db")
	if len(os.Args) > 1 && os.Args[1] == "revoke-consoles" {
		return server.RevokeConsoles(database, key)
	}
	var configuration struct {
		Username string                 `json:"username"`
		Agents   []server.AgentConfig   `json:"agents"`
		Consoles []server.ConsoleConfig `json:"consoles"`
	}
	configData, err := os.ReadFile(env("HAKO_CONFIG_FILE", "./config/server.json"))
	if err != nil {
		return err
	}
	if err = json.Unmarshal(configData, &configuration); err != nil {
		return err
	}
	app, err := server.New(server.Config{Database: database, MasterKey: key, Username: configuration.Username, Consoles: configuration.Consoles, PublicURL: env("HAKO_PUBLIC_URL", "http://localhost:8080"), Agents: configuration.Agents})
	if err != nil {
		return err
	}
	defer app.Close()
	httpServer := &http.Server{Addr: env("HAKO_LISTEN", ":8080"), Handler: app, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, IdleTimeout: 90 * time.Second, MaxHeaderBytes: 16 * 1024}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(shutdown)
	}()
	log.Printf("Hako listening on %s", httpServer.Addr)
	err = httpServer.ListenAndServe()
	if err == http.ErrServerClosed {
		return nil
	}
	return err
}
