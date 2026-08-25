// Package server wires up the Syncbox HTTP API.
package server

import "net/http"

// New builds the HTTP handler for the Syncbox server. dataDir is the root
// directory where blobs will be stored (used by handlers added in later
// tickets; unused for now beyond /healthz).
func New(dataDir string) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", handleHealthz)
	return mux
}

func handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
}
