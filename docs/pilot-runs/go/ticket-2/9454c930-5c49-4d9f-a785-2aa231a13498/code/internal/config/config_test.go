package config

import "testing"

func noEnv(string) string { return "" }

func envMap(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestLoad_FlagsOnly(t *testing.T) {
	cfg, err := Load([]string{"--data-dir", "/data", "--port", "9090"}, noEnv)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.DataDir != "/data" || cfg.Port != 9090 {
		t.Fatalf("got %+v", cfg)
	}
}

func TestLoad_DefaultPort(t *testing.T) {
	cfg, err := Load([]string{"--data-dir", "/data"}, noEnv)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Port != DefaultPort {
		t.Fatalf("expected default port %d, got %d", DefaultPort, cfg.Port)
	}
}

func TestLoad_EnvFallback(t *testing.T) {
	getenv := envMap(map[string]string{
		"SYNCBOX_DATA_DIR": "/env-data",
		"SYNCBOX_PORT":     "7000",
	})
	cfg, err := Load(nil, getenv)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.DataDir != "/env-data" || cfg.Port != 7000 {
		t.Fatalf("got %+v", cfg)
	}
}

func TestLoad_FlagTakesPrecedenceOverEnv(t *testing.T) {
	getenv := envMap(map[string]string{
		"SYNCBOX_DATA_DIR": "/env-data",
		"SYNCBOX_PORT":     "7000",
	})
	cfg, err := Load([]string{"--data-dir", "/flag-data", "--port", "9999"}, getenv)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.DataDir != "/flag-data" || cfg.Port != 9999 {
		t.Fatalf("got %+v", cfg)
	}
}

func TestLoad_MissingDataDir(t *testing.T) {
	if _, err := Load(nil, noEnv); err == nil {
		t.Fatal("expected error when --data-dir/SYNCBOX_DATA_DIR is missing")
	}
}

func TestLoad_InvalidEnvPort(t *testing.T) {
	getenv := envMap(map[string]string{
		"SYNCBOX_DATA_DIR": "/env-data",
		"SYNCBOX_PORT":     "not-a-number",
	})
	if _, err := Load(nil, getenv); err == nil {
		t.Fatal("expected error for invalid SYNCBOX_PORT")
	}
}
