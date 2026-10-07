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

## Client

```sh
# Upload every file under ./photos that the server does not have yet, or
# has with different content (compared by SHA-256). Identical files are not
# re-sent; blobs that exist only on the server are left alone.
./run-client push ./photos --server http://127.0.0.1:8080
#   uploaded 2024/trip/IMG_0001.jpg (new, 3182044 bytes)
#   uploaded notes.txt (changed, 412 bytes)
#   push done: 2 uploaded, 57 unchanged, 59 file(s) scanned

# The mirror image: download every blob that is missing under ./photos or
# differs from the local file (by SHA-256) to ./photos/<key>, creating
# directories as needed. Identical files are not re-downloaded; local files
# the server does not have are left alone.
./run-client pull ./photos --server http://127.0.0.1:8080
#   downloaded 2024/trip/IMG_0002.jpg (new, 2960113 bytes)
#   downloaded notes.txt (changed, 440 bytes)
#   pull done: 2 downloaded, 58 unchanged, 60 blob(s) listed

# Dry run: compare ./photos with the server and print what push and pull
# would do — one line per differing key, grouped by direction, then a
# summary. Nothing is changed on either side; exit code 0 means the
# comparison succeeded, whether or not there are differences.
./run-client status ./photos --server http://127.0.0.1:8080
#   upload    2024/trip/IMG_0003.jpg  (missing on server, 2871200 bytes)
#   download  2024/trip/IMG_0002.jpg  (missing locally, 2960113 bytes)
#   differs   notes.txt  (local 440 bytes, server 412 bytes; push would upload, pull would download)
#   status: 1 to upload, 1 to download, 1 differs on both sides, 58 unchanged (dry run: nothing was changed)
./run-client status ./photos --server http://127.0.0.1:8080       # when everything matches:
#   status: in sync, 61 file(s) identical on both sides (dry run: nothing was changed)

SYNCBOX_SERVER=http://127.0.0.1:8080 ./run-client pull ./photos   # env instead of --server
```

`run-client <push|pull|sync|status> <dir> --server <url>` forwards the
subcommand and arguments to the `syncbox` executable (`bin/syncbox`) running
in a container; `--server` falls back to `SYNCBOX_SERVER`. `sync` is
accepted by the interface but currently exits 1 with a message saying it is
not implemented yet (ticket 10).

`push` walks `<dir>` recursively; a file's key is its POSIX path relative to
`<dir>` (`docs/readme.txt`), exactly the server's key convention, and is sent
percent-encoded so names with spaces or non-ASCII characters round-trip
byte for byte. Hidden files are included. Symbolic links (to files or
directories) and special files (sockets, FIFOs, devices) cannot be blobs and
are skipped with a warning on stderr — links are never followed. The server
listing (`GET /blobs`) is fetched once; each local file whose key is missing
there or whose `sha256` differs is streamed with `PUT /blobs/{key}`, and the
`sha256` the server reports back is checked against the local one. Progress
goes to stdout (one line per uploaded file plus a summary), warnings and
errors to stderr.

`pull` fetches the listing once and compares each blob's `sha256` with the
file at `<dir>/<key>`: a blob with no local file, or whose hash differs, is
fetched with `GET /blobs/{key}`; one with an identical local file is skipped
without a request. Each download is streamed into a staging file
(`.syncbox-tmp-<16 hex digits>`) in the target's directory, hashed on the
way, flushed to disk and `rename(2)`d onto `<dir>/<key>` only if the hash
matches the listing — so a file under `<dir>` is either untouched or
complete, never half-written, and a blob replaced on the server during the
pull (or a corrupted transfer) is reported instead of installed. Replacing a
file keeps its permission bits; a new file gets the default ones. Missing
parent directories are created. Staging files are removed on every outcome,
including an interrupted run (Ctrl-C, SIGTERM); only a hard kill can leave
one behind. Keys from the listing are not trusted: an absolute key, one with
`.` or `..` segments, empty segments or NUL bytes is refused, and a key is
never resolved through a symlink — a symlinked directory on the way, or a
directory, symlink or special file at the target itself, is reported as "in
the way" and nothing is written, mirroring `push`, which never follows links
either. Local files and directories the server does not list are never
deleted or modified; `pull` only adds and replaces.

`status` is the dry run of both: it scans `<dir>` like `push`, fetches the
listing once like `pull`, and compares the two by key and `sha256`. Every key
falls into exactly one group — `upload` (only local; `push` would upload it),
`download` (only on the server; `pull` would download it), `differs` (on both
sides with different content; `push` would upload the local version, `pull`
would download the server's — which one `sync` will pick is ticket 10's
conflict rule, and `status` does not guess) or unchanged (identical, only
counted). Lines are grouped in that order and sorted by key, followed by a
summary line; an identical tree prints just the `in sync` summary. The
command never changes anything: no file under `<dir>` is created, modified
or removed, and the only request it sends is `GET /blobs` — the listing
already carries every hash the comparison needs, so not even `GET
/blobs/{key}` is issued, let alone `PUT` or `DELETE`. A download that `pull`
would refuse (a directory or symlink where the file would go, a key that
could leave the directory) is still listed as a download, with a `pull would
fail: …` note. The exit code is `0` whenever the comparison succeeded,
regardless of how many differences there are.

Exit codes: `0` success, `1` failure (server unreachable, server answered
outside the contract, unreadable file, file name that is not valid UTF-8 and
so cannot be a key, SHA-256 mismatch after a transfer, something in the way
of a file to be written, disk error while writing), `2` usage error. In this
version a failure stops the command at the first problem with a clear
message; continuing past per-file failures and reporting them at the end is
ticket 11.

Inside the container `<dir>` is bind-mounted at `/work` — read-only for
`push` and `status`, read-write for `pull` and `sync` (`run-client` picks the
mode per command through `SYNCBOX_DIR_MODE`) — and the container uses the
host network, so a `--server` URL that is valid for the caller
(`http://127.0.0.1:8080`, `http://localhost:8080`, a LAN address) is valid
inside the container too — nothing is rewritten. The container runs as the
caller's uid/gid, so it reads files with the caller's permissions and the
files `pull` creates belong to the caller.

Blobs are stored as plain files under `<data-dir>/blobs/<key>`; `<data-dir>/tmp/`
is the staging area for writes in progress (see “Atomic writes”). The listing
is derived from the files themselves on every request (no metadata index):
`key` is the path relative to `<data-dir>/blobs/`, and `size`, `sha256` and
`modified_at` are all read from one open file, so each entry describes a
single version even while the key is being replaced. Blobs placed into that
directory by other means are therefore listed too; directories, in-progress
staging files and names that are not valid UTF-8 are skipped.

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

## Atomic writes

`PUT` never writes to the target file. The body is streamed into a freshly
created staging file `<data-dir>/tmp/put-<32 hex digits>`, flushed and
`fsync`ed, and only then `rename(2)`d onto `<data-dir>/blobs/<key>`. Since
`rename(2)` swaps the directory entry atomically, a `GET` started at any
moment sees either the previous complete blob or the new complete one, never
a partially written file; a reader that already has the old file open reads
it to the end even though its directory entry is gone. The server does not
hold any locks: concurrent `PUT`s to the same key each stage into their own
randomly named file, the last `rename` wins and the other versions are
unlinked whole, and `PUT`s to different keys share nothing but the staging
directory. `modified_at` in the `PUT` response is the staged file's mtime,
which `rename` preserves.

`rename(2)` is only atomic within one filesystem, so the staging directory is
a sibling of the storage root inside the same data dir rather than the system
temp dir. This is verified, not assumed: at boot and on every `PUT` the server
checks that `blobs/` and `tmp/` report the same device, and refuses (exit 1 at
boot, `500` on `PUT`, nothing written) instead of falling back to a copy if
someone mounts them on different filesystems.

Staging files never outlive the request: on success the file has been renamed
away, and on any failure (rejected key, I/O error, client disconnect) it is
unlinked before the response. At boot the server removes `put-*` files a
previous process may have left behind by dying mid-write and reports the count
on stderr — safe because one server process owns a data dir, which is also
why no cross-process lock file is needed. `tmp/` lies outside the storage
root, so a staging file is never listed and cannot be reached through any
key (`../tmp/...` is rejected lexically, a symlink into `tmp/` by the
`realpath` check).

## Tests

```sh
./run-tests
```

The suite covers the write path deterministically (a probing request body
watches the disk mid-write: the target keeps its old content and inode, the
staging file is on the target's filesystem, and the staged inode itself ends
up under the key) and stochastically (writer, reader and listing threads on
one key, both in-process and through the real Puma server). Aborted uploads
are exercised with raw sockets against the real server.

The client is covered at three levels: pure unit tests (option/URL parsing,
key encoding, directory scanning including symlinks, special files and
non-UTF-8 names, key-to-path mapping with unsafe keys and symlinked or
non-directory ancestors), `Push` and `Pull` against a scripted stand-in for
the API (which files are sent or written, what is left alone, staging-file
cleanup, SHA-256 mismatches, the report), `Status` against a stand-in whose
mutating methods raise (each direction — local-only, server-only, different
content on both sides — the in-sync case, and a before/after snapshot of the
directory), and the real `bin/syncbox` process pushing into, pulling out of
and reporting status against the real `bin/syncbox-server` process over
HTTP, comparing SHA-256 hashes end to end — including the unreachable-server,
something-in-the-way and not-implemented paths. `status` is additionally run
against a recording HTTP stub that proves the only request it sends is
`GET /blobs`, and the real server's listing (hashes and `modified_at`) is
checked to be identical before and after. `Api#get` is also exercised
against truncated bodies and an unwritable destination (`/dev/full`).

## Layout

| Path                      | Purpose                                              |
| ------------------------- | ---------------------------------------------------- |
| `bin/syncbox-server`      | In-container server entry point (parses flags, boots Puma) |
| `bin/syncbox`             | In-container client entry point (the spec's `syncbox` executable) |
| `lib/syncbox/server/`     | `Config` (CLI/env), `App` (Rack routes), `BlobStore` (files on disk), `Runner` (Puma) |
| `lib/syncbox/client/`     | `Options` (CLI/env), `Api` (HTTP), `LocalTree` (scan, key↔path, SHA-256), `Push`, `Pull`, `Status`, `Runner` |
| `test/`, `test/client/`   | Minitest: unit tests plus real-process HTTP tests for server and client |
| `compose.yaml`            | Single source of truth for build, network, ports and volumes |
| `run-server`, `run-client`, `run-tests` | Spec-mandated wrappers around `docker compose` |

## Status

- [x] Ticket 1: server skeleton, `GET /healthz`, `--data-dir` / `--port` config
- [x] Ticket 2: `PUT /blobs/{key}` / `GET /blobs/{key}` happy path (nested keys)
- [x] Ticket 3: `GET /blobs` listing with `key` / `size` / `sha256` / `modified_at`
- [x] Ticket 4: `DELETE /blobs/{key}` (`204` / `404`, emptied directories pruned)
- [x] Ticket 5: key validation on every `/blobs/{key}` method (`..`, absolute paths,
      unrepresentable names, symlink escapes) — see “Key validation”
- [x] Ticket 6: atomic writes under concurrent `PUT` (staging file + `rename`,
      same-filesystem check, staging cleanup on every outcome and at boot) —
      see “Atomic writes”
- [x] Ticket 7: client `push` (`run-client` / `bin/syncbox`, SHA-256 comparison
      against `GET /blobs`, upload of missing and changed files only) — see “Client”
- [x] Ticket 8: client `pull` (download of missing and changed blobs only, staging
      file + `rename`, untrusted keys refused, read-write mount only for `pull`/`sync`) — see “Client”
- [x] Ticket 9: client `status` (dry run: upload / download / differs groups by
      key and SHA-256, strictly read-only — the only request is `GET /blobs`,
      nothing under `<dir>` is touched, exit 0 with or without differences) — see “Client”
- [ ] Ticket 10: client `sync` (accepted by the interface, reports “not implemented yet”)
- [ ] Ticket 11: network/partial-failure handling on the client
