package server

import "net/http"

const (
	releaseVersion      = "0.4.0"
	minimumIOSVersion   = "0.4.0"
	minimumAgentVersion = "1.2.4"
)

func serverVersion(w http.ResponseWriter, _ *http.Request) {
	respond(w, http.StatusOK, map[string]string{
		"serverVersion":       releaseVersion,
		"minimumIosVersion":   minimumIOSVersion,
		"minimumAgentVersion": minimumAgentVersion,
	})
}
