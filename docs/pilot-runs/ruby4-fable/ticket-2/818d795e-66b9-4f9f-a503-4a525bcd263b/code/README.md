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

# Upload raw bytes under a key (nested directories are created on demand),
# then download them back. Missing keys answer 404.
curl -i -X PUT --data-binary @README.md http://127.0.0.1:8080/blobs/docs/readme.txt
#   201  {"key":"docs/readme.txt","sha256":"<hex>","size":<bytes>}
curl -i http://127.0.0.1:8080/blobs/docs/readme.txt
#   200  application/octet-stream, the stored bytes
```

`run-server` stays in the foreground; Ctrl-C / SIGTERM stops the container.

Blobs are stored as plain files under `<data-dir>/blobs/<key>`; `<data-dir>/tmp/`
is the staging area for writes in progress.

## Tests

```sh
./run-tests
```

## Layout

| Path                      | Purpose                                              |
| ------------------------- | ---------------------------------------------------- |
| `bin/syncbox-server`      | In-container entry point (parses flags, boots Puma)  |
| `lib/syncbox/server/`     | `Config` (CLI/env), `App` (Rack routes), `BlobStore` (files on disk), `Runner` (Puma) |
| `test/`                   | Minitest: unit tests plus a real-process HTTP test   |
| `compose.yaml`            | Single source of truth for build, ports and volumes  |
| `run-server`, `run-tests` | Spec-mandated wrappers around `docker compose`       |

## Status

- [x] Ticket 1: server skeleton, `GET /healthz`, `--data-dir` / `--port` config
- [x] Ticket 2: `PUT /blobs/{key}` / `GET /blobs/{key}` happy path (nested keys)
- [ ] `GET /blobs` listing, `DELETE /blobs/{key}`, key validation (`..`, absolute
      paths), atomic writes under concurrent `PUT` — the code for these is already
      present in `BlobStore`/`App` (it was written during ticket 1), but they are
      not yet signed off as their own tickets
- [ ] CLI client (`push` / `pull` / `sync` / `status`)
