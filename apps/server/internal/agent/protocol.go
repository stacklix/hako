package agent

import (
	"encoding/json"
	"errors"
)

type Capability struct {
	Name    string `json:"name"`
	Version int    `json:"version"`
}

const ProtocolVersion = 4

type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type Reply struct {
	Result json.RawMessage `json:"result,omitempty"`
	Error  *Error          `json:"error,omitempty"`
}

type Request struct {
	Method  string          `json:"method"`
	Version int             `json:"version"`
	Params  json.RawMessage `json:"params"`
	Payload json.RawMessage `json:"-"`
}

// Decode only the transport envelope. Business fields (including unknown fields
// and types) remain opaque and are validated by the receiving device.
func (request *Request) UnmarshalJSON(data []byte) error {
	var object map[string]json.RawMessage
	if err := json.Unmarshal(data, &object); err != nil {
		return err
	}
	if object == nil {
		return errors.New("request envelope must be a JSON object")
	}
	request.Payload = append(request.Payload[:0], data...)
	return nil
}

func (request Request) MarshalJSON() ([]byte, error) {
	if request.Payload != nil {
		return request.Payload, nil
	}
	type fields Request
	return json.Marshal(fields(request))
}

func (request Request) envelope(id string) map[string]json.RawMessage {
	data, _ := json.Marshal(request)
	var object map[string]json.RawMessage
	_ = json.Unmarshal(data, &object)
	object["type"] = json.RawMessage(`"request"`)
	object["id"], _ = json.Marshal(id)
	return object
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
	Payload      json.RawMessage `json:"-"`
}
