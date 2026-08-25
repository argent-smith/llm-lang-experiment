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
	"testing"
)

func TestHealthz(t *testing.T) {
	handler := NewHandler(Config{DataDir: "/tmp", Port: 8080})

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusOK)
	}
}

func TestPutBlob(t *testing.T) {
	dataDir := t.TempDir()
	handler := NewHandler(Config{DataDir: dataDir, Port: 8080})

	content := []byte("hello syncbox")
	req := httptest.NewRequest(http.MethodPut, "/blobs/greeting.txt", bytes.NewReader(content))
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want %d, body=%s", rec.Code, http.StatusCreated, rec.Body.String())
	}

	var resp struct {
		Key    string `json:"key"`
		SHA256 string `json:"sha256"`
		Size   int64  `json:"size"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	wantSum := sha256.Sum256(content)
	wantHex := hex.EncodeToString(wantSum[:])

	if resp.Key != "greeting.txt" {
		t.Errorf("Key = %q, want %q", resp.Key, "greeting.txt")
	}
	if resp.SHA256 != wantHex {
		t.Errorf("SHA256 = %q, want %q", resp.SHA256, wantHex)
	}
	if resp.Size != int64(len(content)) {
		t.Errorf("Size = %d, want %d", resp.Size, len(content))
	}

	onDisk, err := os.ReadFile(filepath.Join(dataDir, "greeting.txt"))
	if err != nil {
		t.Fatalf("failed to read written file: %v", err)
	}
	if !bytes.Equal(onDisk, content) {
		t.Errorf("on-disk content = %q, want %q", onDisk, content)
	}
}

func TestPutBlobNestedKey(t *testing.T) {
	dataDir := t.TempDir()
	handler := NewHandler(Config{DataDir: dataDir, Port: 8080})

	content := []byte("nested content")
	req := httptest.NewRequest(http.MethodPut, "/blobs/docs/readme.txt", bytes.NewReader(content))
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want %d, body=%s", rec.Code, http.StatusCreated, rec.Body.String())
	}

	onDisk, err := os.ReadFile(filepath.Join(dataDir, "docs", "readme.txt"))
	if err != nil {
		t.Fatalf("failed to read written file: %v", err)
	}
	if !bytes.Equal(onDisk, content) {
		t.Errorf("on-disk content = %q, want %q", onDisk, content)
	}
}

func TestGetBlob(t *testing.T) {
	dataDir := t.TempDir()
	handler := NewHandler(Config{DataDir: dataDir, Port: 8080})

	content := []byte("round trip me")
	putReq := httptest.NewRequest(http.MethodPut, "/blobs/roundtrip.bin", bytes.NewReader(content))
	putRec := httptest.NewRecorder()
	handler.ServeHTTP(putRec, putReq)
	if putRec.Code != http.StatusCreated {
		t.Fatalf("put status = %d, want %d", putRec.Code, http.StatusCreated)
	}

	getReq := httptest.NewRequest(http.MethodGet, "/blobs/roundtrip.bin", nil)
	getRec := httptest.NewRecorder()
	handler.ServeHTTP(getRec, getReq)

	if getRec.Code != http.StatusOK {
		t.Fatalf("get status = %d, want %d", getRec.Code, http.StatusOK)
	}
	if !bytes.Equal(getRec.Body.Bytes(), content) {
		t.Errorf("body = %q, want %q", getRec.Body.Bytes(), content)
	}
}

func TestGetBlobNotFound(t *testing.T) {
	dataDir := t.TempDir()
	handler := NewHandler(Config{DataDir: dataDir, Port: 8080})

	req := httptest.NewRequest(http.MethodGet, "/blobs/missing.txt", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusNotFound)
	}
}
