package server

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestHealthz(t *testing.T) {
	h := New(t.TempDir())

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /healthz = %d, want %d", rec.Code, http.StatusOK)
	}
}

func TestPutBlob(t *testing.T) {
	dataDir := t.TempDir()
	h := New(dataDir)

	body := "hello, syncbox"
	req := httptest.NewRequest(http.MethodPut, "/blobs/docs/readme.txt", strings.NewReader(body))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("PUT /blobs/docs/readme.txt = %d, want %d; body=%s", rec.Code, http.StatusCreated, rec.Body.String())
	}

	sum := sha256.Sum256([]byte(body))
	wantSHA := hex.EncodeToString(sum[:])

	var resp struct {
		Key    string `json:"key"`
		SHA256 string `json:"sha256"`
		Size   int64  `json:"size"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.Key != "docs/readme.txt" {
		t.Errorf("key = %q, want %q", resp.Key, "docs/readme.txt")
	}
	if resp.SHA256 != wantSHA {
		t.Errorf("sha256 = %q, want %q", resp.SHA256, wantSHA)
	}
	if resp.Size != int64(len(body)) {
		t.Errorf("size = %d, want %d", resp.Size, len(body))
	}

	on, err := os.ReadFile(filepath.Join(dataDir, "docs", "readme.txt"))
	if err != nil {
		t.Fatalf("read stored blob: %v", err)
	}
	if string(on) != body {
		t.Errorf("stored content = %q, want %q", on, body)
	}
}

func TestGetBlob(t *testing.T) {
	dataDir := t.TempDir()
	h := New(dataDir)

	body := "some content"
	putReq := httptest.NewRequest(http.MethodPut, "/blobs/a/b/c.txt", strings.NewReader(body))
	putRec := httptest.NewRecorder()
	h.ServeHTTP(putRec, putReq)
	if putRec.Code != http.StatusCreated {
		t.Fatalf("setup PUT = %d, want %d", putRec.Code, http.StatusCreated)
	}

	getReq := httptest.NewRequest(http.MethodGet, "/blobs/a/b/c.txt", nil)
	getRec := httptest.NewRecorder()
	h.ServeHTTP(getRec, getReq)

	if getRec.Code != http.StatusOK {
		t.Fatalf("GET /blobs/a/b/c.txt = %d, want %d", getRec.Code, http.StatusOK)
	}
	if getRec.Body.String() != body {
		t.Errorf("body = %q, want %q", getRec.Body.String(), body)
	}
}

func TestGetBlobNotFound(t *testing.T) {
	h := New(t.TempDir())

	req := httptest.NewRequest(http.MethodGet, "/blobs/missing.txt", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("GET /blobs/missing.txt = %d, want %d", rec.Code, http.StatusNotFound)
	}
}

type blobMetaDTO struct {
	Key        string `json:"key"`
	Size       int64  `json:"size"`
	SHA256     string `json:"sha256"`
	ModifiedAt string `json:"modified_at"`
}

func TestListBlobsEmpty(t *testing.T) {
	h := New(t.TempDir())

	req := httptest.NewRequest(http.MethodGet, "/blobs", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /blobs = %d, want %d", rec.Code, http.StatusOK)
	}

	var got []blobMetaDTO
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("got %d blobs, want 0", len(got))
	}
	if strings.TrimSpace(rec.Body.String()) != "[]" {
		t.Errorf("body = %q, want %q", rec.Body.String(), "[]")
	}
}

func TestListBlobs(t *testing.T) {
	h := New(t.TempDir())

	files := map[string]string{
		"a.txt":             "aaa",
		"docs/readme.txt":   "readme contents",
		"docs/nested/b.txt": "nested contents",
	}
	for key, body := range files {
		req := httptest.NewRequest(http.MethodPut, "/blobs/"+key, strings.NewReader(body))
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusCreated {
			t.Fatalf("setup PUT %s = %d, want %d", key, rec.Code, http.StatusCreated)
		}
	}

	req := httptest.NewRequest(http.MethodGet, "/blobs", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /blobs = %d, want %d; body=%s", rec.Code, http.StatusOK, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q, want %q", ct, "application/json")
	}

	var got []blobMetaDTO
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(got) != len(files) {
		t.Fatalf("got %d blobs, want %d", len(got), len(files))
	}

	byKey := make(map[string]blobMetaDTO, len(got))
	for _, m := range got {
		byKey[m.Key] = m
	}

	for key, body := range files {
		m, ok := byKey[key]
		if !ok {
			t.Errorf("missing blob for key %q", key)
			continue
		}
		sum := sha256.Sum256([]byte(body))
		wantSHA := hex.EncodeToString(sum[:])
		if m.SHA256 != wantSHA {
			t.Errorf("key %q: sha256 = %q, want %q", key, m.SHA256, wantSHA)
		}
		if m.Size != int64(len(body)) {
			t.Errorf("key %q: size = %d, want %d", key, m.Size, len(body))
		}
		if _, err := time.Parse(time.RFC3339, m.ModifiedAt); err != nil {
			t.Errorf("key %q: modified_at = %q not RFC3339: %v", key, m.ModifiedAt, err)
		}
		if !strings.HasSuffix(m.ModifiedAt, "Z") {
			t.Errorf("key %q: modified_at = %q, want UTC (Z suffix)", key, m.ModifiedAt)
		}
	}
}
