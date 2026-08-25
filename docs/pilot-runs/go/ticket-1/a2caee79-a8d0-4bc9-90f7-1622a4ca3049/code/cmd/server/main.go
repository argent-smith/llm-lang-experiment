package main

import (
	"fmt"
	"log"
	"net/http"
	"os"

	"syncbox/internal/server"
)

func main() {
	cfg, err := server.ParseConfig(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, "syncbox-server:", err)
		os.Exit(1)
	}

	if info, err := os.Stat(cfg.DataDir); err != nil || !info.IsDir() {
		fmt.Fprintf(os.Stderr, "syncbox-server: data dir %q is not accessible: %v\n", cfg.DataDir, err)
		os.Exit(1)
	}

	addr := fmt.Sprintf(":%d", cfg.Port)
	handler := server.NewHandler(cfg)

	log.Printf("syncbox-server: listening on %s, data-dir=%s", addr, cfg.DataDir)
	if err := http.ListenAndServe(addr, handler); err != nil {
		fmt.Fprintln(os.Stderr, "syncbox-server:", err)
		os.Exit(1)
	}
}
