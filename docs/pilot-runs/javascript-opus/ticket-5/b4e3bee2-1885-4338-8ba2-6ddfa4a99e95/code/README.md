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
curl -X DELETE http://127.0.0.1:8080/blobs/docs/file.txt                      # 204 no body, 404 if missing
curl http://127.0.0.1:8080/blobs             # 200 [{"key","size","sha256","modified_at"}], sorted by key; [] if empty
./run-tests                                  # full test suite, non-zero exit on failure
```

`run-server` also reads `SYNCBOX_DATA_DIR` / `SYNCBOX_PORT`; flags take
precedence. The data directory is created if missing and bind-mounted into
the container; files are written with the invoking user's UID/GID.

## Keys

A key is a relative POSIX path, percent-decoded from the URL (`%2F` counts as
`/`). `PUT`, `GET` and `DELETE` answer `400` for a key that is empty, absolute,
contains an empty, `.` or `..` segment, a NUL, invalid UTF-8 or a lone
surrogate, or a segment over 255 bytes. Independently of that, the store
resolves every key to a path on disk and refuses it unless the result lies
strictly inside the blob root, both lexically and after following any
symlinks found in the data directory (the server never creates symlinks; a
symlink as the key itself is not treated as a blob).

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
