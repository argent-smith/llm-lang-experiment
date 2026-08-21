// Package server implements the Syncbox HTTP API.
package server

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"sort"
)

// New builds the HTTP handler for a server rooted at dataDir.
func New(dataDir string) http.Handler {
	s := &server{dataDir: dataDir}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", handleHealthz)
	mux.HandleFunc("GET /blobs", s.handleListBlobs)
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

func (s *server) handleListBlobs(w http.ResponseWriter, r *http.Request) {
	blobs := []blobMeta{}

	err := filepath.WalkDir(s.dataDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}

		rel, err := filepath.Rel(s.dataDir, path)
		if err != nil {
			return err
		}

		f, err := os.Open(path)
		if err != nil {
			return err
		}
		defer f.Close()

		info, err := f.Stat()
		if err != nil {
			return err
		}

		h := sha256.New()
		size, err := io.Copy(h, f)
		if err != nil {
			return err
		}

		blobs = append(blobs, blobMeta{
			Key:        filepath.ToSlash(rel),
			Size:       size,
			SHA256:     hex.EncodeToString(h.Sum(nil)),
			ModifiedAt: info.ModTime().UTC().Format("2006-01-02T15:04:05.000Z"),
		})
		return nil
	})
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			json.NewEncoder(w).Encode(blobs)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	sort.Slice(blobs, func(i, j int) bool { return blobs[i].Key < blobs[j].Key })

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(blobs)
}

func (s *server) handlePutBlob(w http.ResponseWriter, r *http.Request) {
	key := r.PathValue("key")
	path := filepath.Join(s.dataDir, filepath.FromSlash(key))

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	f, err := os.Create(path)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer f.Close()

	h := sha256.New()
	size, err := io.Copy(f, io.TeeReader(r.Body, h))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(putResponse{
		Key:    key,
		SHA256: hex.EncodeToString(h.Sum(nil)),
		Size:   size,
	})
}

func (s *server) handleGetBlob(w http.ResponseWriter, r *http.Request) {
	key := r.PathValue("key")
	path := filepath.Join(s.dataDir, filepath.FromSlash(key))

	f, err := os.Open(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			http.NotFound(w, r)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if info.IsDir() {
		http.NotFound(w, r)
		return
	}

	w.Header().Set("Content-Type", "application/octet-stream")
	http.ServeContent(w, r, "", info.ModTime(), f)
}
