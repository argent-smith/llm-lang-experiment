package server

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
)

// NewHandler builds the top-level HTTP handler for the syncbox server.
func NewHandler(cfg Config) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", handleHealthz)

	h := &blobHandler{dataDir: cfg.DataDir}
	mux.HandleFunc("PUT /blobs/{key...}", h.put)
	mux.HandleFunc("GET /blobs/{key...}", h.get)

	return mux
}

func handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}

type blobHandler struct {
	dataDir string
}

type putResponse struct {
	Key    string `json:"key"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

func (h *blobHandler) path(key string) string {
	return filepath.Join(h.dataDir, filepath.FromSlash(key))
}

func (h *blobHandler) put(w http.ResponseWriter, r *http.Request) {
	key := r.PathValue("key")
	path := h.path(key)

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		http.Error(w, "failed to create directory", http.StatusInternalServerError)
		return
	}

	data, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "failed to read request body", http.StatusInternalServerError)
		return
	}

	if err := os.WriteFile(path, data, 0o644); err != nil {
		http.Error(w, "failed to write blob", http.StatusInternalServerError)
		return
	}

	sum := sha256.Sum256(data)
	resp := putResponse{
		Key:    key,
		SHA256: hex.EncodeToString(sum[:]),
		Size:   int64(len(data)),
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(resp)
}

func (h *blobHandler) get(w http.ResponseWriter, r *http.Request) {
	key := r.PathValue("key")
	path := h.path(key)

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			http.Error(w, "blob not found", http.StatusNotFound)
			return
		}
		http.Error(w, "failed to read blob", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/octet-stream")
	w.WriteHeader(http.StatusOK)
	w.Write(data)
}
