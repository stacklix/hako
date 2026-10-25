package main

import (
	"bytes"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInitMasterKeyNeverOverwrites(t *testing.T) {
	path := filepath.Join(t.TempDir(), "secrets", "master.key")
	t.Setenv("HAKO_MASTER_KEY_FILE", path)
	t.Setenv("HAKO_CONFIG_FILE", filepath.Join(t.TempDir(), "missing-config"))
	previous := os.Args
	os.Args = []string{"hako-server", "init"}
	defer func() { os.Args = previous }()
	if err := run(); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	key, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(string(before)))
	if err != nil || len(key) != 32 {
		t.Fatal("master key must contain 256 random bits")
	}
	if err = run(); err == nil {
		t.Fatal("init overwrote existing secret")
	}
	after, _ := os.ReadFile(path)
	if !bytes.Equal(before, after) {
		t.Fatal("existing master key changed")
	}
}

func TestRemovedAdminKeyCommandIsRejected(t *testing.T) {
	previous := os.Args
	os.Args = []string{"hako-server", "init-admin"}
	defer func() { os.Args = previous }()
	if err := run(); err == nil || !strings.Contains(err.Error(), "unknown command") {
		t.Fatal("removed management-key command is still active")
	}
}
