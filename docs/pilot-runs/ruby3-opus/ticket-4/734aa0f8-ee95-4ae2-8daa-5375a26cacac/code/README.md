# Syncbox (Ruby)

Self-hosted file storage with sync: HTTP server + CLI client.
Contract: [SYNCBOX-SPEC.md](SYNCBOX-SPEC.md), [syncbox-openapi.yaml](syncbox-openapi.yaml).

Everything runs in Docker via `docker compose` (Ruby 3.3.12, `ruby:3.3.12` image);
nothing needs to be installed on the host besides Docker.

## Server

```sh
./run-server --data-dir <path> [--port <n>]   # port defaults to 8080
SYNCBOX_DATA_DIR=<path> SYNCBOX_PORT=<n> ./run-server
```

Flags take precedence over environment variables. The data dir is created if
missing and bind-mounted into the container; the port is published on
`127.0.0.1` (override with `SYNCBOX_PUBLISH_ADDR=0.0.0.0`). The server runs in
the foreground; SIGTERM/SIGINT stop it gracefully and remove the container.

Implemented endpoints: `GET /healthz`, `GET /blobs`, `PUT /blobs/{key}`, `GET /blobs/{key}`,
`DELETE /blobs/{key}`. Blobs are stored under `<data-dir>/blobs/<key>`; uploads
are staged in `<data-dir>/tmp`.

`GET /blobs` returns `[{"key", "size", "sha256", "modified_at"}]` for every
regular file under `<data-dir>/blobs`, sorted by key (`modified_at` is the file
mtime, ISO 8601 UTC). Files placed there directly are listed too; symlinks,
special files and names that aren't valid UTF-8 are skipped. Hashes are
computed on each request.

`DELETE /blobs/{key}` answers `204` (no body) when the blob was removed and `404`
when there is none — directories and symlinks are not blobs, so they are never
followed or removed. Directories left empty by a delete are pruned, so their
paths can become keys again.

## Tests

```sh
./run-tests
```

Runs the Minitest suite (`test/`) inside the `tests` compose service.

## Layout

- `bin/syncbox-server` — server entry point (inside the container)
- `lib/syncbox/server/config.rb` — flag/env configuration
- `lib/syncbox/server/app.rb` — Rack app (HTTP API)
- `lib/syncbox/server/store.rb` — blob storage on disk, key validation
- `lib/syncbox/server/runner.rb` — Puma boot
- `compose.yaml`, `Dockerfile` — container setup; `run-server`, `run-tests` — wrappers
