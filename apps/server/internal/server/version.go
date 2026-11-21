package server

import "net/http"

const (
	releaseVersion      = "0.8.12"
	minimumIOSVersion   = "0.8.0"
	minimumAgentVersion = "1.4.7"
)

func serverVersion(w http.ResponseWriter, _ *http.Request) {
	respond(w, http.StatusOK, map[string]string{
		"serverVersion":       releaseVersion,
		"minimumIosVersion":   minimumIOSVersion,
		"minimumAgentVersion": minimumAgentVersion,
	})
}
