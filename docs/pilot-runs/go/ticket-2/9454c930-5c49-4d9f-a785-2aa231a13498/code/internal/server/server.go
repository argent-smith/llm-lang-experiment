// Package server wires up the Syncbox HTTP API.
package server

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
)

// New builds the HTTP handler for the Syncbox server. dataDir is the root
// directory where blobs are stored on disk.
func New(dataDir string) http.Handler {
	s := &server{dataDir: dataDir}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", handleHealthz)
	mux.HandleFunc("PUT /blobs/{key...}", s.handlePutBlob)
	mux.HandleFunc("GET /blobs/{key...}", s.handleGetBlob)
	return mux
}

type server struct {
	dataDir string
}

func handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
}

type putBlobResponse struct {
	Key    string `json:"key"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

func (s *server) handlePutBlob(w http.ResponseWriter, r *http.Request) {
	key := r.PathValue("key")
	path := filepath.Join(s.dataDir, filepath.FromSlash(key))

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		http.Error(w, "failed to create blob directory", http.StatusInternalServerError)
		return
	}

	f, err := os.Create(path)
	if err != nil {
		http.Error(w, "failed to create blob", http.StatusInternalServerError)
		return
	}
	defer f.Close()

	hasher := sha256.New()
	size, err := io.Copy(io.MultiWriter(f, hasher), r.Body)
	if err != nil {
		http.Error(w, "failed to write blob", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(putBlobResponse{
		Key:    key,
		SHA256: hex.EncodeToString(hasher.Sum(nil)),
		Size:   size,
	})
}

func (s *server) handleGetBlob(w http.ResponseWriter, r *http.Request) {
	key := r.PathValue("key")
	path := filepath.Join(s.dataDir, filepath.FromSlash(key))

	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			http.NotFound(w, r)
			return
		}
		http.Error(w, "failed to read blob", http.StatusInternalServerError)
		return
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil {
		http.Error(w, "failed to stat blob", http.StatusInternalServerError)
		return
	}
	if info.IsDir() {
		http.NotFound(w, r)
		return
	}

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.FormatInt(info.Size(), 10))
	w.WriteHeader(http.StatusOK)
	io.Copy(w, f)
}
