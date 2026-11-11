package server

import "net/http"

const (
	releaseVersion      = "0.2.0"
	minimumIOSVersion   = "0.2.0"
	minimumAgentVersion = "1.1.0"
)

func serverVersion(w http.ResponseWriter, _ *http.Request) {
	respond(w, http.StatusOK, map[string]string{
		"serverVersion":       releaseVersion,
		"minimumIosVersion":   minimumIOSVersion,
		"minimumAgentVersion": minimumAgentVersion,
	})
}
