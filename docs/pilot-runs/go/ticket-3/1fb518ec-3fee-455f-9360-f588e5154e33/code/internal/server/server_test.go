package server

import (
	"bytes"
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

func TestHealthz_OK(t *testing.T) {
	h := New(t.TempDir())

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}
}

func TestHealthz_WrongMethod(t *testing.T) {
	h := New(t.TempDir())

	req := httptest.NewRequest(http.MethodPost, "/healthz", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code == http.StatusOK {
		t.Fatalf("expected non-200 status for POST /healthz, got %d", rec.Code)
	}
}

func TestPutBlob_CreatesFileAndReturnsMetadata(t *testing.T) {
	dataDir := t.TempDir()
	h := New(dataDir)

	body := []byte("hello, syncbox")
	sum := sha256.Sum256(body)
	wantSHA := hex.EncodeToString(sum[:])

	req := httptest.NewRequest(http.MethodPut, "/blobs/greeting.txt", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected status 201, got %d: %s", rec.Code, rec.Body.String())
	}

	var resp struct {
		Key    string `json:"key"`
		SHA256 string `json:"sha256"`
		Size   int64  `json:"size"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}
	if resp.Key != "greeting.txt" {
		t.Fatalf("expected key %q, got %q", "greeting.txt", resp.Key)
	}
	if resp.SHA256 != wantSHA {
		t.Fatalf("expected sha256 %q, got %q", wantSHA, resp.SHA256)
	}
	if resp.Size != int64(len(body)) {
		t.Fatalf("expected size %d, got %d", len(body), resp.Size)
	}

	onDisk, err := os.ReadFile(filepath.Join(dataDir, "greeting.txt"))
	if err != nil {
		t.Fatalf("failed to read blob from disk: %v", err)
	}
	if !bytes.Equal(onDisk, body) {
		t.Fatalf("blob on disk does not match uploaded content")
	}
}

func TestPutBlob_CreatesNestedDirectories(t *testing.T) {
	dataDir := t.TempDir()
	h := New(dataDir)

	body := []byte("nested content")
	req := httptest.NewRequest(http.MethodPut, "/blobs/docs/readme.txt", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected status 201, got %d: %s", rec.Code, rec.Body.String())
	}

	onDisk, err := os.ReadFile(filepath.Join(dataDir, "docs", "readme.txt"))
	if err != nil {
		t.Fatalf("failed to read nested blob from disk: %v", err)
	}
	if !bytes.Equal(onDisk, body) {
		t.Fatalf("nested blob on disk does not match uploaded content")
	}
}

func TestGetBlob_ReturnsStoredContent(t *testing.T) {
	dataDir := t.TempDir()
	h := New(dataDir)

	body := []byte("round trip me")
	putReq := httptest.NewRequest(http.MethodPut, "/blobs/docs/readme.txt", bytes.NewReader(body))
	putRec := httptest.NewRecorder()
	h.ServeHTTP(putRec, putReq)
	if putRec.Code != http.StatusCreated {
		t.Fatalf("setup PUT failed: status %d: %s", putRec.Code, putRec.Body.String())
	}

	getReq := httptest.NewRequest(http.MethodGet, "/blobs/docs/readme.txt", nil)
	getRec := httptest.NewRecorder()
	h.ServeHTTP(getRec, getReq)

	if getRec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", getRec.Code)
	}
	if !bytes.Equal(getRec.Body.Bytes(), body) {
		t.Fatalf("expected body %q, got %q", body, getRec.Body.Bytes())
	}
	if ct := getRec.Header().Get("Content-Type"); ct != "application/octet-stream" {
		t.Fatalf("expected Content-Type application/octet-stream, got %q", ct)
	}
}

func TestGetBlob_NotFound(t *testing.T) {
	h := New(t.TempDir())

	req := httptest.NewRequest(http.MethodGet, "/blobs/does-not-exist.txt", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected status 404, got %d", rec.Code)
	}
}

func TestListBlobs_EmptyStoreReturnsEmptyArray(t *testing.T) {
	h := New(t.TempDir())

	req := httptest.NewRequest(http.MethodGet, "/blobs", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}
	if got := strings.TrimSpace(rec.Body.String()); got != "[]" {
		t.Fatalf("expected empty JSON array, got %q", got)
	}
}

func TestListBlobs_ReturnsMetadataForAllBlobs(t *testing.T) {
	dataDir := t.TempDir()
	h := New(dataDir)

	files := map[string][]byte{
		"greeting.txt":    []byte("hello, syncbox"),
		"docs/readme.txt": []byte("nested content"),
	}
	for key, body := range files {
		req := httptest.NewRequest(http.MethodPut, "/blobs/"+key, bytes.NewReader(body))
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusCreated {
			t.Fatalf("setup PUT %s failed: status %d: %s", key, rec.Code, rec.Body.String())
		}
	}

	req := httptest.NewRequest(http.MethodGet, "/blobs", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("expected Content-Type application/json, got %q", ct)
	}

	var got []struct {
		Key        string `json:"key"`
		Size       int64  `json:"size"`
		SHA256     string `json:"sha256"`
		ModifiedAt string `json:"modified_at"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}
	if len(got) != len(files) {
		t.Fatalf("expected %d blobs, got %d: %+v", len(files), len(got), got)
	}

	byKey := make(map[string]struct {
		Key        string `json:"key"`
		Size       int64  `json:"size"`
		SHA256     string `json:"sha256"`
		ModifiedAt string `json:"modified_at"`
	})
	for _, b := range got {
		byKey[b.Key] = b
	}

	for key, body := range files {
		entry, ok := byKey[key]
		if !ok {
			t.Fatalf("expected key %q in listing, got %+v", key, got)
		}
		sum := sha256.Sum256(body)
		wantSHA := hex.EncodeToString(sum[:])
		if entry.SHA256 != wantSHA {
			t.Errorf("key %q: expected sha256 %q, got %q", key, wantSHA, entry.SHA256)
		}
		if entry.Size != int64(len(body)) {
			t.Errorf("key %q: expected size %d, got %d", key, len(body), entry.Size)
		}
		if _, err := time.Parse(time.RFC3339, entry.ModifiedAt); err != nil {
			t.Errorf("key %q: modified_at %q is not RFC3339: %v", key, entry.ModifiedAt, err)
		}
	}
}

func TestPutBlob_OverwritesExisting(t *testing.T) {
	dataDir := t.TempDir()
	h := New(dataDir)

	first := httptest.NewRequest(http.MethodPut, "/blobs/file.txt", strings.NewReader("first"))
	firstRec := httptest.NewRecorder()
	h.ServeHTTP(firstRec, first)
	if firstRec.Code != http.StatusCreated {
		t.Fatalf("first PUT failed: status %d", firstRec.Code)
	}

	second := httptest.NewRequest(http.MethodPut, "/blobs/file.txt", strings.NewReader("second, longer"))
	secondRec := httptest.NewRecorder()
	h.ServeHTTP(secondRec, second)
	if secondRec.Code != http.StatusCreated {
		t.Fatalf("second PUT failed: status %d", secondRec.Code)
	}

	onDisk, err := os.ReadFile(filepath.Join(dataDir, "file.txt"))
	if err != nil {
		t.Fatalf("failed to read blob from disk: %v", err)
	}
	if string(onDisk) != "second, longer" {
		t.Fatalf("expected overwritten content, got %q", onDisk)
	}
}
