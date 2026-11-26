package server

import "net/http"

const (
	releaseVersion      = "0.9.3"
	minimumIOSVersion   = "0.9.0"
	minimumAgentVersion = "1.5.10"
)

func serverVersion(w http.ResponseWriter, _ *http.Request) {
	respond(w, http.StatusOK, map[string]string{
		"serverVersion":       releaseVersion,
		"minimumIosVersion":   minimumIOSVersion,
		"minimumAgentVersion": minimumAgentVersion,
	})
}
