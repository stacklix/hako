package server

import "net/http"

const (
	releaseVersion      = "0.8.21"
	minimumIOSVersion   = "0.8.161"
	minimumAgentVersion = "1.5.0"
)

func serverVersion(w http.ResponseWriter, _ *http.Request) {
	respond(w, http.StatusOK, map[string]string{
		"serverVersion":       releaseVersion,
		"minimumIosVersion":   minimumIOSVersion,
		"minimumAgentVersion": minimumAgentVersion,
	})
}
