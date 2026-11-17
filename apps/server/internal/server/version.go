package server

import "net/http"

const (
	releaseVersion      = "0.7.3"
	minimumIOSVersion   = "0.7.0"
	minimumAgentVersion = "1.4.2"
)

func serverVersion(w http.ResponseWriter, _ *http.Request) {
	respond(w, http.StatusOK, map[string]string{
		"serverVersion":       releaseVersion,
		"minimumIosVersion":   minimumIOSVersion,
		"minimumAgentVersion": minimumAgentVersion,
	})
}
