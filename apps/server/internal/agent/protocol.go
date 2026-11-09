package agent

import (
	"encoding/json"
	"regexp"
	"strings"
)

type Capability struct {
	Name    string `json:"name"`
	Version int    `json:"version"`
}

const ProtocolVersion = 4

var errorCode = regexp.MustCompile(`^[A-Za-z0-9_-]{1,80}$`)
var methodName = regexp.MustCompile(`^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$`)

func ValidCapabilities(methods []Capability) bool {
	if methods == nil || len(methods) > 64 {
		return false
	}
	seen := map[string]bool{}
	for _, m := range methods {
		if len(m.Name) > 100 || !methodName.MatchString(m.Name) || (!strings.HasPrefix(m.Name, "query.") && !strings.HasPrefix(m.Name, "action.")) || m.Name == "query.all" || strings.Count(m.Name, ".") < 2 || m.Version < 1 || seen[m.Name] {
			return false
		}
		seen[m.Name] = true
	}
	return true
}

type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type Reply struct {
	Result json.RawMessage `json:"result,omitempty"`
	Error  *Error          `json:"error,omitempty"`
}

func (m Reply) valid() bool {
	if m.Error != nil {
		return len(m.Result) == 0 && errorCode.MatchString(m.Error.Code) && len(m.Error.Message) <= 1024
	}
	return len(m.Result) != 0 && json.Valid(m.Result)
}

type Request struct {
	Method  string          `json:"method"`
	Version int             `json:"version"`
	Params  json.RawMessage `json:"params"`
}

type Message struct {
	Reply
	Type         string          `json:"type"`
	ID           string          `json:"id,omitempty"`
	Method       string          `json:"method,omitempty"`
	Version      int             `json:"version,omitempty"`
	Username     string          `json:"username,omitempty"`
	KeyID        string          `json:"keyId,omitempty"`
	Signature    string          `json:"signature,omitempty"`
	Params       json.RawMessage `json:"params,omitempty"`
	Capabilities []Capability    `json:"capabilities,omitempty"`
	SSHTunnel    bool            `json:"sshTunnel,omitempty"`
	Data         []byte          `json:"data,omitempty"`
}

func (request Request) Valid() bool {
	return len(request.Method) <= 100 && methodName.MatchString(request.Method) && request.Version >= 1 && len(request.Params) != 0 && request.Params[0] == '{'
}
