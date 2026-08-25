// Command syncbox-server runs the Syncbox HTTP server.
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"

	"syncbox/internal/config"
	"syncbox/internal/server"
)

func main() {
	cfg, err := config.Load(os.Args[1:], os.Getenv)
	if err != nil {
		fmt.Fprintf(os.Stderr, "syncbox-server: %v\n", err)
		os.Exit(1)
	}

	if info, statErr := os.Stat(cfg.DataDir); statErr != nil || !info.IsDir() {
		fmt.Fprintf(os.Stderr, "syncbox-server: data-dir %q is not an accessible directory\n", cfg.DataDir)
		os.Exit(1)
	}

	addr := fmt.Sprintf(":%d", cfg.Port)
	handler := server.New(cfg.DataDir)

	log.Printf("syncbox-server: listening on %s, data-dir=%s", addr, cfg.DataDir)
	if err := http.ListenAndServe(addr, handler); err != nil {
		fmt.Fprintf(os.Stderr, "syncbox-server: %v\n", err)
		os.Exit(1)
	}
}
