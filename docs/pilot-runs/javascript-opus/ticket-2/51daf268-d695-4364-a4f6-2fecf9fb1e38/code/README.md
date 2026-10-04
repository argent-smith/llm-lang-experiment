# Syncbox

Self-hosted file storage with sync: an HTTP server plus a CLI client.
The contract lives in [SYNCBOX-SPEC.md](SYNCBOX-SPEC.md) and
[syncbox-openapi.yaml](syncbox-openapi.yaml).

Implementation: JavaScript on Node.js 20 with no npm dependencies. Everything
runs in Docker (`node:20-alpine`) through docker compose, so the host
only needs Docker with the compose plugin.

## Running

```sh
./run-server --data-dir ./data --port 8080   # foreground; Ctrl+C / SIGTERM stops it
curl http://127.0.0.1:8080/healthz           # {"status":"ok"}
curl -X PUT --data-binary @file.txt http://127.0.0.1:8080/blobs/docs/file.txt  # 201 {"key","sha256","size"}
curl http://127.0.0.1:8080/blobs/docs/file.txt                                # 200 + bytes, 404 if missing
./run-tests                                  # full test suite, non-zero exit on failure
```

`run-server` also reads `SYNCBOX_DATA_DIR` / `SYNCBOX_PORT`; flags take
precedence. The data directory is created if missing and bind-mounted into
the container; files are written with the invoking user's UID/GID.

## Layout

| Path                   | Purpose                                                   |
| ---------------------- | --------------------------------------------------------- |
| `src/server-main.js`   | server entry point (args, data dir checks, signals)       |
| `src/config.js`        | flag/env parsing                                          |
| `src/server.js`        | HTTP routing and handlers                                 |
| `src/blobs.js`         | blob key validation and on-disk storage                   |
| `test/`                | `node:test` suites (unit + spawned-process integration)   |
| `Dockerfile`           | `server` and `test` build targets                         |
| `compose.yaml`         | the only place where Docker build/run options are defined |
| `run-server`, `run-tests` | wrappers required by the spec                          |
