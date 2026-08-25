// Package config resolves server configuration from CLI flags and
// environment variables, per the Syncbox CLI contract:
// --data-dir/SYNCBOX_DATA_DIR (required) and --port/SYNCBOX_PORT
// (default 8080), with an explicit flag taking precedence over the
// corresponding environment variable.
package config

import (
	"flag"
	"fmt"
	"strconv"
)

const DefaultPort = 8080

type Config struct {
	DataDir string
	Port    int
}

// Load parses args (as in os.Args[1:]) and falls back to getenv for
// SYNCBOX_DATA_DIR / SYNCBOX_PORT when the corresponding flag is absent.
func Load(args []string, getenv func(string) string) (Config, error) {
	fs := flag.NewFlagSet("syncbox-server", flag.ContinueOnError)
	dataDir := fs.String("data-dir", "", "path to the data directory (required)")
	port := fs.Int("port", -1, "port to listen on (default 8080)")
	if err := fs.Parse(args); err != nil {
		return Config{}, err
	}

	cfg := Config{DataDir: *dataDir, Port: *port}

	if cfg.DataDir == "" {
		cfg.DataDir = getenv("SYNCBOX_DATA_DIR")
	}
	if cfg.DataDir == "" {
		return Config{}, fmt.Errorf("--data-dir is required (or set SYNCBOX_DATA_DIR)")
	}

	if cfg.Port == -1 {
		if envPort := getenv("SYNCBOX_PORT"); envPort != "" {
			p, err := strconv.Atoi(envPort)
			if err != nil {
				return Config{}, fmt.Errorf("invalid SYNCBOX_PORT %q: %w", envPort, err)
			}
			cfg.Port = p
		} else {
			cfg.Port = DefaultPort
		}
	}

	return cfg, nil
}
