package server

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// NewHandler builds the top-level HTTP handler for the syncbox server.
func NewHandler(cfg Config) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", handleHealthz)

	h := &blobHandler{dataDir: cfg.DataDir}
	mux.HandleFunc("GET /blobs", h.list)
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

type blobMeta struct {
	Key        string `json:"key"`
	Size       int64  `json:"size"`
	SHA256     string `json:"sha256"`
	ModifiedAt string `json:"modified_at"`
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

func (h *blobHandler) list(w http.ResponseWriter, r *http.Request) {
	blobs := []blobMeta{}

	err := filepath.WalkDir(h.dataDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			if os.IsNotExist(err) {
				return nil
			}
			return err
		}
		if d.IsDir() {
			return nil
		}

		rel, err := filepath.Rel(h.dataDir, path)
		if err != nil {
			return err
		}

		info, err := d.Info()
		if err != nil {
			return err
		}

		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		sum := sha256.Sum256(data)

		blobs = append(blobs, blobMeta{
			Key:        filepath.ToSlash(rel),
			Size:       info.Size(),
			SHA256:     hex.EncodeToString(sum[:]),
			ModifiedAt: info.ModTime().UTC().Format(time.RFC3339),
		})
		return nil
	})
	if err != nil {
		http.Error(w, "failed to list blobs", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(blobs)
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
