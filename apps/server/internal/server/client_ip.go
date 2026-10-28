package server

import (
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"strings"
)

type proxyTrust []netip.Prefix

func parseTrustedProxies(value string) (proxyTrust, error) {
	var proxies proxyTrust
	if strings.TrimSpace(value) == "" {
		return proxies, nil
	}
	for _, item := range strings.Split(value, ",") {
		item = strings.TrimSpace(item)
		prefix, err := netip.ParsePrefix(item)
		if err != nil {
			ip, ipErr := netip.ParseAddr(item)
			if ipErr != nil || ip.Zone() != "" {
				return nil, fmt.Errorf("HAKO_TRUSTED_PROXIES must contain IP addresses or CIDR ranges")
			}
			ip = ip.Unmap()
			prefix = netip.PrefixFrom(ip, ip.BitLen())
		}
		proxies = append(proxies, prefix.Masked())
	}
	return proxies, nil
}

func (proxies proxyTrust) contains(ip netip.Addr) bool {
	for _, prefix := range proxies {
		if prefix.Contains(ip) {
			return true
		}
	}
	return false
}

// Capture the browser's source when the QR is created, never the scanning phone's IP.
func (s *Server) loginClientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	peer, err := netip.ParseAddr(host)
	if err != nil {
		return "未知"
	}
	peer = peer.Unmap().WithZone("")
	if !s.trustedProxies.contains(peer) {
		return peer.String()
	}
	// Walk from the trusted peer towards the client; ignore any spoofed prefix.
	chain := strings.Split(strings.Join(r.Header.Values("X-Forwarded-For"), ","), ",")
	current := peer
	for i := len(chain) - 1; i >= 0 && s.trustedProxies.contains(current); i-- {
		next, err := netip.ParseAddr(strings.TrimSpace(chain[i]))
		if err != nil || next.Zone() != "" {
			return peer.String()
		}
		current = next.Unmap()
	}
	return current.String()
}
