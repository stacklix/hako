package server

import (
	"bytes"
	"crypto/rand"
	"errors"
	"io"
	"regexp"
	"testing"
	"testing/iotest"
)

func TestAgentIDFormat(t *testing.T) {
	for _, id := range []string{"A", "Z9", "N100", "ABCDE", "A0123"} {
		if !validAgentID(id) {
			t.Fatalf("valid Agent ID rejected: %q", id)
		}
	}
	for _, id := range []string{"", "0ABCD", "abc", "Ab123", "A-12", "A_12", "ABCDEF", " A1", "A1\n", "设备A1", "agent-long"} {
		if validAgentID(id) {
			t.Fatalf("invalid Agent ID accepted: %q", id)
		}
	}
	used := map[string]bool{}
	format := regexp.MustCompile(`^[A-Z][A-Z0-9]{4}$`)
	for range 512 {
		id, err := allocateAgentID(used, rand.Reader)
		if err != nil || !format.MatchString(id) || used[id] {
			t.Fatalf("generated ID is invalid or duplicated: %q %v", id, err)
		}
		used[id] = true
	}
}

func TestAgentIDCollisionRetryAndFailures(t *testing.T) {
	// First candidate AAAAA is already taken; the second must be ABCDE.
	entropy := bytes.NewReader(append(make([]byte, 5), 0, 1, 2, 3, 4))
	id, err := allocateAgentID(map[string]bool{"AAAAA": true}, entropy)
	if err != nil || id != "ABCDE" {
		t.Fatalf("collision did not retry: %q %v", id, err)
	}
	if id, err := allocateAgentID(nil, iotest.ErrReader(io.ErrUnexpectedEOF)); id != "" || !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("random source failure was not returned: %q %v", id, err)
	}
	if id, err := allocateAgentID(map[string]bool{"AAAAA": true}, bytes.NewReader(make([]byte, 128*5))); id != "" || err == nil {
		t.Fatal("repeated collisions must stop without returning a duplicate")
	}
}
