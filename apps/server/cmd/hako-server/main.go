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

type fileConfig struct {
	Username  string                 `json:"username"`
	MasterKey string                 `json:"masterKey"`
	Agents    []server.AgentConfig   `json:"agents"`
	Consoles  []server.ConsoleConfig `json:"consoles"`
}

func createConfig(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return err
	}
	configuration := fileConfig{Username: "owner", MasterKey: base64.RawURLEncoding.EncodeToString(b), Agents: []server.AgentConfig{}, Consoles: []server.ConsoleConfig{}}
	data, err := json.MarshalIndent(configuration, "", "  ")
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return fmt.Errorf("cannot create configuration %s (existing files are never overwritten): %w", path, err)
	}
	_, err = f.Write(append(data, '\n'))
	closeErr := f.Close()
	if err != nil {
		return err
	}
	return closeErr
}

func loadConfig(path string) (fileConfig, []byte, error) {
	var configuration fileConfig
	data, err := os.ReadFile(path)
	if err != nil {
		return configuration, nil, err
	}
	if err = json.Unmarshal(data, &configuration); err != nil {
		return configuration, nil, fmt.Errorf("invalid server configuration: %w", err)
	}
	key, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(configuration.MasterKey))
	if err != nil || len(key) != 32 {
		return configuration, nil, fmt.Errorf("masterKey must be an unpadded Base64URL encoding of 32 bytes")
	}
	return configuration, key, nil
}

func run() error {
	dataDir := env("HAKO_DATA_DIR", "./data")
	configPath := env("HAKO_CONFIG_FILE", "./config/server.json")
	if len(os.Args) > 1 && os.Args[1] != "init" && os.Args[1] != "revoke-consoles" {
		return fmt.Errorf("unknown command; supported commands: init, revoke-consoles")
	}
	if len(os.Args) > 1 && os.Args[1] == "init" {
		if err := createConfig(configPath); err != nil {
			return err
		}
		fmt.Println("Created server configuration with a master key. Add trusted Console public keys before starting the server. Keep the configuration private and back it up with the database.")
		return nil
	}
	configuration, key, err := loadConfig(configPath)
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
