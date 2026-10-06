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

# List every stored blob with its metadata (sorted by key; [] when empty).
curl -i http://127.0.0.1:8080/blobs
#   200  [{"key":"docs/readme.txt","size":<bytes>,"sha256":"<hex>",
#         "modified_at":"2026-10-06T03:36:49.366Z"}]

# Delete a blob: 204 with no body; afterwards GET answers 404 and the key is
# gone from the listing. Deleting a key that does not exist answers 404.
curl -i -X DELETE http://127.0.0.1:8080/blobs/docs/readme.txt
#   204
curl -i -X DELETE http://127.0.0.1:8080/blobs/docs/readme.txt
#   404  {"error":"not found"}

# Keys are validated on every /blobs/{key} method: ".." segments, absolute
# paths and names that cannot be a file on the server answer 400 with a JSON
# body — the request never reaches the filesystem. (--path-as-is stops curl
# from normalising the path client-side.)
curl -i --path-as-is http://127.0.0.1:8080/blobs/../secret
#   400  {"error":"invalid key","detail":"key must not contain . or .. segments"}
curl -i -X PUT --data-binary x http://127.0.0.1:8080/blobs/%2Fetc%2Fplanted
#   400  {"error":"invalid key","detail":"key must be relative"}
curl -i http://127.0.0.1:8080/blobs/%ED%A0%80
#   400  {"error":"invalid key","detail":"key is not valid UTF-8"}
```

`run-server` stays in the foreground; Ctrl-C / SIGTERM stops the container.

Blobs are stored as plain files under `<data-dir>/blobs/<key>`; `<data-dir>/tmp/`
is the staging area for writes in progress. The listing is derived from the
files themselves on every request (no metadata index): `key` is the path
relative to `<data-dir>/blobs/`, `size`/`modified_at` come from `stat`, and
`sha256` is computed from the file contents. Blobs placed into that directory
by other means are therefore listed too; directories, in-progress temp files
and names that are not valid UTF-8 are skipped.

Directories under `<data-dir>/blobs/` exist only while they hold a blob: `PUT`
creates them on demand and `DELETE` removes the ones it leaves empty (the root
itself stays). A key freed by `DELETE` therefore behaves exactly like one that
never existed — e.g. after deleting `docs/readme.txt` a `PUT` to `docs` is
accepted. Only regular files are blobs: `DELETE` of a key that names a
directory answers `404` and leaves its contents alone.

## Key validation

A `key` is a POSIX path relative to `<data-dir>/blobs/`. Every method on
`/blobs/{key}` (`GET`, `HEAD`, `PUT`, `DELETE`) runs the decoded key through
two independent checks before touching a file, and answers `400` (JSON
`{"error":"invalid key","detail":...}`) if either fails:

1. **Lexical** (`BlobStore#validate_key`): the key must be non-empty, valid
   UTF-8, free of NUL bytes, relative (no leading `/`), with no empty, `.` or
   `..` segments and no segment over 255 bytes. Overlong UTF-8 encodings and
   surrogate halves are invalid UTF-8 and therefore rejected too.
2. **On disk** (`BlobStore#path_for`): the longest existing prefix of the
   resulting path is resolved with `realpath(3)` (every symlink followed) and
   the location must lie *strictly inside* the resolved storage root. This is
   what keeps a well-formed key from escaping through a symlink that someone
   placed under `blobs/` — a link leading outside the root (or to the root
   itself) answers `400` for all methods, is left untouched, and is skipped
   by the listing. Symlinks that stay inside the root work like any other
   entry; the listing does not descend into symlinked directories.

The path is percent-decoded exactly once, so `%252e%252e` is the ordinary
directory name `%2e%2e`, not `..`; `..` inside a segment (`a..b`, `...`) is an
ordinary name as well. Nothing is created on disk for a rejected key, and a
rejected or malformed key never produces a 5xx.

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
- [x] Ticket 3: `GET /blobs` listing with `key` / `size` / `sha256` / `modified_at`
- [x] Ticket 4: `DELETE /blobs/{key}` (`204` / `404`, emptied directories pruned)
- [x] Ticket 5: key validation on every `/blobs/{key}` method (`..`, absolute paths,
      unrepresentable names, symlink escapes) — see “Key validation”
- [ ] Atomic writes under concurrent `PUT` — the code is already present in
      `BlobStore` (written during ticket 1), but not yet signed off as its own ticket
- [ ] CLI client (`push` / `pull` / `sync` / `status`)
