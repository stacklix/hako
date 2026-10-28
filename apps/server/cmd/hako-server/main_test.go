package main

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInitConfigNeverOverwrites(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config", "server.json")
	t.Setenv("HAKO_CONFIG_FILE", path)
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
	configuration, key, err := loadConfig(path)
	if err != nil || len(key) != 32 || len(configuration.MasterKey) != 64 || configuration.MasterKey != strings.ToLower(configuration.MasterKey) {
		t.Fatalf("masterKey must contain 256 random bits: %v", err)
	}
	if configuration.Username != "owner" || configuration.Agents == nil || configuration.Consoles == nil {
		t.Fatal("init must create an editable server configuration")
	}
	if err = run(); err == nil {
		t.Fatal("init overwrote existing configuration")
	}
	after, _ := os.ReadFile(path)
	if !bytes.Equal(before, after) {
		t.Fatal("existing configuration changed")
	}
}

func TestLoadConfigMasterKey(t *testing.T) {
	validKey := hex.EncodeToString(bytes.Repeat([]byte{255}, 32))
	for _, tc := range []struct {
		name  string
		key   string
		valid bool
	}{
		{"valid", validKey, true},
		{"uppercase", strings.ToUpper(validKey), true},
		{"mixed case", strings.Repeat("fF", 32), true},
		{"surrounding whitespace", " \n" + validKey + "\t", true},
		{"missing", "", false},
		{"invalid encoding", "private-invalid-key!", false},
		{"non-hex characters", strings.Repeat("gg", 32), false},
		{"hex prefix", "0x" + validKey, false},
		{"odd length", validKey[:63], false},
		{"internal whitespace", validKey[:32] + " " + validKey[32:], false},
		{"legacy base64url", base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{255}, 32)), false},
		{"short key", hex.EncodeToString(make([]byte, 16)), false},
		{"long key", hex.EncodeToString(make([]byte, 33)), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "server.json")
			data, err := json.Marshal(fileConfig{Username: "custom-owner", MasterKey: tc.key})
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, data, 0600); err != nil {
				t.Fatal(err)
			}
			configuration, key, err := loadConfig(path)
			if tc.valid {
				if err != nil || configuration.Username != "custom-owner" || !bytes.Equal(key, bytes.Repeat([]byte{255}, 32)) {
					t.Fatalf("configuration did not load correctly: %v", err)
				}
			} else if err == nil || !strings.Contains(err.Error(), "masterKey") || (tc.key != "" && strings.Contains(err.Error(), tc.key)) {
				t.Fatalf("invalid key must fail without exposing its value: %v", err)
			}
		})
	}
}

func TestConfigErrors(t *testing.T) {
	path := filepath.Join(t.TempDir(), "server.json")
	if _, _, err := loadConfig(path); !os.IsNotExist(err) {
		t.Fatalf("missing configuration must fail: %v", err)
	}
	before := []byte(`{"username":`)
	if err := os.WriteFile(path, before, 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := loadConfig(path); err == nil {
		t.Fatal("malformed configuration was accepted")
	}
	if err := createConfig(path); err == nil {
		t.Fatal("init must not overwrite an existing malformed configuration")
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("existing configuration was modified")
	}
}

func TestRevokeConsolesUsesConfigKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config", "server.json")
	dataDir := filepath.Join(t.TempDir(), "data")
	t.Setenv("HAKO_CONFIG_FILE", path)
	t.Setenv("HAKO_DATA_DIR", dataDir)
	if err := createConfig(path); err != nil {
		t.Fatal(err)
	}
	previous := os.Args
	os.Args = []string{"hako-server", "revoke-consoles"}
	defer func() { os.Args = previous }()
	if err := run(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dataDir, "hako.db")); err != nil {
		t.Fatal(err)
	}
	configuration, _, err := loadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	configuration.MasterKey = hex.EncodeToString(make([]byte, 32))
	data, err := json.Marshal(configuration)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := run(); err == nil || !strings.Contains(err.Error(), "cannot decrypt database") {
		t.Fatalf("command must use the masterKey from the configured file: %v", err)
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
