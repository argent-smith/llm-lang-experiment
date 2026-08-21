// Command syncbox-server runs the Syncbox HTTP server.
package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"

	"syncbox/internal/server"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "syncbox-server: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	fs := flag.NewFlagSet("syncbox-server", flag.ContinueOnError)
	dataDir := fs.String("data-dir", os.Getenv("SYNCBOX_DATA_DIR"), "path to the blob storage directory (required; env SYNCBOX_DATA_DIR)")
	port := fs.Int("port", defaultPort(), "port to listen on (env SYNCBOX_PORT)")
	if err := fs.Parse(args); err != nil {
		return err
	}

	if *dataDir == "" {
		return fmt.Errorf("--data-dir (or SYNCBOX_DATA_DIR) is required")
	}
	info, err := os.Stat(*dataDir)
	if err != nil {
		return fmt.Errorf("data-dir %q: %w", *dataDir, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("data-dir %q is not a directory", *dataDir)
	}

	addr := fmt.Sprintf(":%d", *port)
	handler := server.New(*dataDir)

	log.Printf("syncbox-server: listening on %s, data-dir=%s", addr, *dataDir)
	return http.ListenAndServe(addr, handler)
}

func defaultPort() int {
	if v := os.Getenv("SYNCBOX_PORT"); v != "" {
		if p, err := strconv.Atoi(v); err == nil && p > 0 {
			return p
		}
	}
	return 8080
}
