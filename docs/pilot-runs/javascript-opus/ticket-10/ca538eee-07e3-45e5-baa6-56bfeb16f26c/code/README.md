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
./run-client push ./mydir --server http://127.0.0.1:8080  # upload new and changed files
./run-client pull ./mydir --server http://127.0.0.1:8080  # download new and changed blobs
./run-client status ./mydir --server http://127.0.0.1:8080  # dry run: what push/pull would transfer
./run-client sync ./mydir --server http://127.0.0.1:8080  # two-way: push and pull in one pass
./run-tests                                  # full test suite, non-zero exit on failure
```

`run-server` also reads `SYNCBOX_DATA_DIR` / `SYNCBOX_PORT`; flags take
precedence. The data directory is created if missing and bind-mounted into
the container; files are written with the invoking user's UID/GID.

## Client

`run-client <push|pull|status|sync> <dir> --server <url>` runs the `syncbox`
CLI (`bin/syncbox`) in a container. `--server` can also come from
`SYNCBOX_SERVER`; the flag takes precedence. `<dir>` must exist, except for
`pull`, which creates it. It is bind-mounted into the container, read-only
except for `pull` and `sync` (compose services `client`, `client-writable` and
`client-sync`), and the container runs as the invoking user, so files it
writes belong to them. The container
shares the host's network, so `--server` means the same as on the host
(`http://127.0.0.1:<port>` reaches a server started by `run-server`).

`push` walks `<dir>` recursively and keys each regular file by its relative
POSIX path (`docs/readme.txt`). It fetches `GET /blobs` and `PUT`s every file
whose SHA-256 is missing from the server or differs from the server's. Files
identical to the server's copy are not sent, and nothing is deleted on either
side. Symbolic links, special files and names that are not valid UTF-8 are
skipped with a note on stderr. stdout gets one `uploaded <key>` line per upload
and a summary.

`pull` is the reverse: it fetches `GET /blobs` and `GET`s every blob that is
missing from `<dir>` or whose SHA-256 differs from the local file's, writing
it to the path named by its key and creating subdirectories as needed. Local
changes to such a file are overwritten. Files identical to the server's copy
are not fetched, and nothing is deleted on either side. Each download goes to
a temporary `.syncbox-*.part` file next to its target, is checked against the
SHA-256 from the listing, and is then renamed into place (keeping the
permissions of the file it replaces), so an interrupted pull leaves no
truncated files; on SIGINT/SIGTERM the temporary file is removed and the
exit code is `130`/`143`. Nothing is written outside `<dir>`: keys that are
not plain relative paths, and paths leading through or onto a symbolic link,
are skipped with a note on stderr. A directory where a file should go (or a
file where a directory should go) is a failure. stdout gets one
`downloaded <key>` line per download and a summary.

`status` is a dry run: it fetches `GET /blobs`, hashes the files in `<dir>`
and prints what push would upload and what pull would download, changing
nothing on either side (no other requests are made, and `<dir>` is mounted
read-only). A file whose SHA-256 differs on the two sides is listed in both
directions: push would replace the server's copy, pull the local one.
Whatever push or pull would skip (symbolic links, invalid keys) is noted on
stderr and left out, and so is a blob pull could not write because something
is in the way locally. Example:

```
Would upload to the server (push): 2 files
  differs  changed.txt
  new      sub/new.txt
Would download from the server (pull): 2 files
  differs  changed.txt
  new      remote/only.txt
1 file differs on both sides: push would replace the server's copy, pull the local one.
status: 2 to upload, 2 to download, 1 up to date
```

With nothing to transfer it prints `Up to date: nothing to upload or
download.` and the summary line. Keys containing control characters are
printed JSON-quoted.

`sync` is push and pull in one pass. It hashes `<dir>`, fetches `GET /blobs`
and, key by key:

- a file on one side only is copied to the other (`PUT` or `GET`);
- a file with the same SHA-256 on both sides is left alone;
- a file that differs goes from the side that changed since the last sync to
  the side that did not;
- a file changed on **both** sides since the last sync goes the way of the
  copy with the more recent modification time (local mtime against the
  server's `modified_at`, both in whole milliseconds); on a tie the local
  copy wins. The losing copy is overwritten.

Nothing is deleted on either side: a file removed on one side is copied back
from the other. Uploads and downloads behave exactly as in push and pull
(temporary file and SHA-256 check for downloads, the same skipped files and
blobs, a directory in the way is a failure, SIGINT/SIGTERM stops with
`130`/`143`). stdout gets one `uploaded <key>` or `downloaded <key>` line per
transfer, with `(changed on both sides, local copy is newer)`,
`(changed on both sides, server copy is newer)` or `(changed on both sides
at the same time, local copy kept)` appended for conflicts, and a summary:

```
uploaded notes/todo.txt
downloaded report.pdf (changed on both sides, server copy is newer)
sync: 1 uploaded, 1 downloaded, 12 already up to date, 1 conflict resolved
```

"Since the last sync" means against the SHA-256 that both sides had in
common when sync last ran for this directory and this server. Sync keeps
that in a JSON state file **outside** `<dir>`, so the synced directory only
ever holds synced files: under `$SYNCBOX_STATE_DIR`, else
`$XDG_STATE_HOME/syncbox`, else `~/.local/state/syncbox`. `run-client` mounts
`<state root>/dirs/<sha256 of the directory's real path>/` into the container
as `/state`; in it there is one file per server URL. The state is written
atomically at the end of every run, also one that failed or was interrupted
(for the files it got to). At the first sync there is no state yet, and
deleting the state file brings that back: files on one side only are simply
copied, and a file that differs on both sides is settled by the
modification-time rule above. Moving the directory has the same effect. push
and pull neither read nor update the state, which does not matter: whatever
is identical on both sides at the next sync becomes its new base.

Exit codes: `0` success (for `status`, whether or not anything differs),
`1` failure (message on stderr; push, pull and sync stop at the first failure),
`2` invalid arguments.

`docker compose run` does not pass signals on to the container. So
`run-client` gives the client a TTY when it runs in a terminal, which lets
Ctrl+C reach the client itself. Without a terminal, the streams stay separate,
and a client whose wrapper is killed runs to completion.

## Keys

A key is a relative POSIX path, percent-decoded from the URL (`%2F` counts as
`/`). `PUT`, `GET` and `DELETE` answer `400` for a key that is empty, absolute,
contains an empty, `.` or `..` segment, a NUL, invalid UTF-8 or a lone
surrogate, or a segment over 255 bytes. Independently of that, the store
resolves every key to a path on disk and refuses it unless the result lies
strictly inside the blob root, both lexically and after following any
symlinks found in the data directory (the server never creates symlinks; a
symlink as the key itself is not treated as a blob).

## Atomic writes

`PUT` streams the body into `<data-dir>/tmp/<random>.part`, fsyncs it and
renames it to `<data-dir>/blobs/<key>`. Both live on the same mount (checked at
startup; the server refuses to start otherwise), so the rename atomically
replaces the old blob: a concurrent `GET` returns either the old or the new
contents in full, never a mix, and parallel `PUT`s to one key leave exactly one
complete version (the last rename wins). Files in `tmp/` are never listed or
reachable by any key. A failed or aborted upload removes its temp file;
leftovers from a crash are removed at the next startup, and unfinished uploads
are discarded on shutdown.

## Layout

| Path                   | Purpose                                                   |
| ---------------------- | --------------------------------------------------------- |
| `src/server-main.js`   | server entry point (args, data dir checks, signals)       |
| `src/config.js`        | flag/env parsing                                          |
| `src/server.js`        | HTTP routing and handlers                                 |
| `src/blobs.js`         | blob key validation and on-disk storage                   |
| `bin/syncbox`          | client executable (runs `src/client-main.js`)             |
| `src/client-config.js` | client argument parsing                                   |
| `src/client.js`        | HTTP client for the server API                            |
| `src/local-files.js`   | walking and hashing the local directory                   |
| `src/push.js`          | the push command                                          |
| `src/pull.js`          | the pull command                                          |
| `src/status.js`        | the status command (dry run)                              |
| `src/sync.js`          | the sync command and its conflict rule                    |
| `src/sync-state.js`    | where and how sync keeps its state between runs           |
| `test/`                | `node:test` suites (unit + spawned-process integration)   |
| `Dockerfile`           | `server`, `client` and `test` build targets               |
| `compose.yaml`         | the only place where Docker build/run options are defined |
| `run-server`, `run-client`, `run-tests` | wrappers required by the spec            |
