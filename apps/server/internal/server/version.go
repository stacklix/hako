package server

import "net/http"

const (
	releaseVersion      = "0.3.1"
	minimumIOSVersion   = "0.3.1"
	minimumAgentVersion = "1.2.1"
)

func serverVersion(w http.ResponseWriter, _ *http.Request) {
	respond(w, http.StatusOK, map[string]string{
		"serverVersion":       releaseVersion,
		"minimumIosVersion":   minimumIOSVersion,
		"minimumAgentVersion": minimumAgentVersion,
	})
}
