package server

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"strconv"
)

const defaultPort = 8080

// Config holds the server's runtime configuration.
type Config struct {
	DataDir string
	Port    int
}

// ParseConfig parses server configuration from CLI flags, falling back to
// SYNCBOX_DATA_DIR/SYNCBOX_PORT environment variables when the corresponding
// flag is not given.
func ParseConfig(args []string) (Config, error) {
	fs := flag.NewFlagSet("syncbox-server", flag.ContinueOnError)

	envPort := defaultPort
	if v := os.Getenv("SYNCBOX_PORT"); v != "" {
		p, err := strconv.Atoi(v)
		if err != nil {
			return Config{}, fmt.Errorf("invalid SYNCBOX_PORT %q: %w", v, err)
		}
		envPort = p
	}

	dataDir := fs.String("data-dir", os.Getenv("SYNCBOX_DATA_DIR"), "path to the data directory (required; env SYNCBOX_DATA_DIR)")
	port := fs.Int("port", envPort, "port to listen on (default 8080; env SYNCBOX_PORT)")

	if err := fs.Parse(args); err != nil {
		return Config{}, err
	}

	if *dataDir == "" {
		return Config{}, errors.New("--data-dir is required (or set SYNCBOX_DATA_DIR)")
	}

	return Config{DataDir: *dataDir, Port: *port}, nil
}
