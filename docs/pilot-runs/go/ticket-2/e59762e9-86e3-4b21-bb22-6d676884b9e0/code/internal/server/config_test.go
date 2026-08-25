package server

import "testing"

func TestParseConfig_FlagsOnly(t *testing.T) {
	t.Setenv("SYNCBOX_DATA_DIR", "")
	t.Setenv("SYNCBOX_PORT", "")

	cfg, err := ParseConfig([]string{"--data-dir", "/tmp/data", "--port", "9090"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.DataDir != "/tmp/data" {
		t.Errorf("DataDir = %q, want /tmp/data", cfg.DataDir)
	}
	if cfg.Port != 9090 {
		t.Errorf("Port = %d, want 9090", cfg.Port)
	}
}

func TestParseConfig_DefaultPort(t *testing.T) {
	t.Setenv("SYNCBOX_PORT", "")

	cfg, err := ParseConfig([]string{"--data-dir", "/tmp/data"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Port != 8080 {
		t.Errorf("Port = %d, want 8080", cfg.Port)
	}
}

func TestParseConfig_MissingDataDir(t *testing.T) {
	t.Setenv("SYNCBOX_DATA_DIR", "")

	_, err := ParseConfig([]string{})
	if err == nil {
		t.Fatal("expected error for missing --data-dir, got nil")
	}
}

func TestParseConfig_EnvFallback(t *testing.T) {
	t.Setenv("SYNCBOX_DATA_DIR", "/env/data")
	t.Setenv("SYNCBOX_PORT", "7070")

	cfg, err := ParseConfig([]string{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.DataDir != "/env/data" {
		t.Errorf("DataDir = %q, want /env/data", cfg.DataDir)
	}
	if cfg.Port != 7070 {
		t.Errorf("Port = %d, want 7070", cfg.Port)
	}
}

func TestParseConfig_FlagOverridesEnv(t *testing.T) {
	t.Setenv("SYNCBOX_DATA_DIR", "/env/data")
	t.Setenv("SYNCBOX_PORT", "7070")

	cfg, err := ParseConfig([]string{"--data-dir", "/flag/data", "--port", "6060"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.DataDir != "/flag/data" {
		t.Errorf("DataDir = %q, want /flag/data", cfg.DataDir)
	}
	if cfg.Port != 6060 {
		t.Errorf("Port = %d, want 6060", cfg.Port)
	}
}
