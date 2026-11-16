package server

import "net/http"

const (
	releaseVersion      = "0.6.2"
	minimumIOSVersion   = "0.6.0"
	minimumAgentVersion = "1.3.0"
)

func serverVersion(w http.ResponseWriter, _ *http.Request) {
	respond(w, http.StatusOK, map[string]string{
		"serverVersion":       releaseVersion,
		"minimumIosVersion":   minimumIOSVersion,
		"minimumAgentVersion": minimumAgentVersion,
	})
}
