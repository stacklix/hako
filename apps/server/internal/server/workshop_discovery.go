package server

import (
	"hako/server/internal/workshop"
	"net/netip"
	"reflect"
)

// Discovery is an authenticated Workshop registration, independent of Agent capabilities.
type workshopComputer struct {
	KeyID string `json:"keyId"`
	workshop.Registration
}

func (s *Server) registerWorkshopComputer(agent AgentConfig, registration *workshop.Registration) bool {
	trusted := false
	for _, current := range s.registry.Load().Agents {
		if current.ID == agent.ID && current.keyID == agent.keyID {
			trusted = true
			break
		}
	}
	if !trusted {
		return false
	}
	if registration == nil || registration.ProtocolVersion < 1 || registration.ProtocolVersion > 65535 ||
		registration.Port < 0 || registration.Port > 65535 || len(registration.Addresses) > 16 ||
		registration.Port == 0 && len(registration.Addresses) != 0 {
		return false
	}
	addresses := []string{}
	seen := map[string]bool{}
	for _, value := range registration.Addresses {
		ip, err := netip.ParseAddr(value)
		if err != nil || !ip.Is4() || !ip.IsPrivate() {
			return false
		}
		normalized := ip.String()
		if !seen[normalized] {
			addresses = append(addresses, normalized)
			seen[normalized] = true
		}
	}
	next := workshopComputer{KeyID: agent.keyID, Registration: workshop.Registration{
		ProtocolVersion: registration.ProtocolVersion, Addresses: addresses, Port: registration.Port,
	}}
	changed := true
	s.store.inspect(func(st state) { changed = !reflect.DeepEqual(st.WorkshopComputers[agent.ID], next) })
	if !changed {
		return true
	}
	return s.store.update(func(st *state) error {
		if st.WorkshopComputers == nil {
			st.WorkshopComputers = map[string]workshopComputer{}
		}
		st.WorkshopComputers[agent.ID] = next
		return nil
	}) == nil
}
