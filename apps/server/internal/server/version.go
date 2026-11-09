package server

import "net/http"

const (
	releaseVersion      = "0.1.3"
	minimumIOSVersion   = "0.1.0"
	minimumAgentVersion = "1.0.0"
)

func serverVersion(w http.ResponseWriter, _ *http.Request) {
	respond(w, http.StatusOK, map[string]string{
		"serverVersion":       releaseVersion,
		"minimumIosVersion":   minimumIOSVersion,
		"minimumAgentVersion": minimumAgentVersion,
	})
}
