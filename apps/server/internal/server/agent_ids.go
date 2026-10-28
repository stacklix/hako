package server

import (
	"crypto/rand"
	"fmt"
	"io"
	"math/big"
)

const agentIDLength = 5

func validAgentID(id string) bool {
	if len(id) < 1 || len(id) > agentIDLength || id[0] < 'A' || id[0] > 'Z' {
		return false
	}
	for i := 1; i < len(id); i++ {
		if (id[i] < 'A' || id[i] > 'Z') && (id[i] < '0' || id[i] > '9') {
			return false
		}
	}
	return true
}

// Callers hold the registry lock while allocating and saving a new enrollment.
func allocateAgentID(used map[string]bool, entropy io.Reader) (string, error) {
	const letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	const alphanumeric = letters + "0123456789"
	for attempt := 0; attempt < 128; attempt++ {
		var id [agentIDLength]byte
		for i := range id {
			alphabet := alphanumeric
			if i == 0 {
				alphabet = letters
			}
			index, err := rand.Int(entropy, big.NewInt(int64(len(alphabet))))
			if err != nil {
				return "", fmt.Errorf("generate Agent ID: %w", err)
			}
			id[i] = alphabet[index.Int64()]
		}
		if candidate := string(id[:]); !used[candidate] {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("could not allocate a unique Agent ID")
}
