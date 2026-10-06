# Syncbox

Self-hosted file store with sync: an HTTP server keeping blobs on disk and a
CLI client that reconciles a local directory against it. Contract:
[SYNCBOX-SPEC.md](SYNCBOX-SPEC.md) and [syncbox-openapi.yaml](syncbox-openapi.yaml).

Implementation language: Ruby 4.0.7 (image `ruby:4.0.7`). Everything runs in
Docker through `docker compose`; nothing is executed directly on the host.

## Running

```sh
./run-server --data-dir ./data --port 8080   # or SYNCBOX_DATA_DIR / SYNCBOX_PORT
curl -i http://127.0.0.1:8080/healthz
```

`run-server` stays in the foreground; Ctrl-C / SIGTERM stops the container.

## Tests

```sh
./run-tests
```

## Layout

| Path                      | Purpose                                              |
| ------------------------- | ---------------------------------------------------- |
| `bin/syncbox-server`      | In-container entry point (parses flags, boots Puma)  |
| `lib/syncbox/server/`     | `Config` (CLI/env), `App` (Rack), `Runner` (Puma)    |
| `test/`                   | Minitest: unit tests plus a real-process HTTP test    |
| `compose.yaml`            | Single source of truth for build, ports and volumes  |
| `run-server`, `run-tests` | Spec-mandated wrappers around `docker compose`       |

## Status

- [x] Ticket 1: server skeleton, `GET /healthz`, `--data-dir` / `--port` config
- [x] Blob `PUT` / `GET` / `DELETE` / list (atomic writes, key validation)
- [ ] CLI client (`push` / `pull` / `sync` / `status`)
