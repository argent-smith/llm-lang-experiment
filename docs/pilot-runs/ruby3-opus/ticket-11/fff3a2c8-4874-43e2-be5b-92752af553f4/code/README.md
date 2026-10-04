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

### Atomic uploads

`PUT` streams the body into a fresh staging file `<data-dir>/tmp/<random>.part`
(fsynced), then `rename(2)`s it over `<data-dir>/blobs/<key>`. Consequences:

- A `GET` or `GET /blobs` sees either the whole old blob or the whole new one,
  never a partial write; a download already in progress keeps streaming the
  version it opened.
- Concurrent `PUT`s to the same key each report the hash of their own body; the
  last rename wins and the stored blob is one of the uploaded bodies, intact.
  `PUT`s to different keys share nothing but the directories above them.
- Parent directories of a new key are created only after the whole body is staged.
- Staging files are outside `blobs/`, so they're never listed or reachable by
  any key, and they are removed when the request ends, whether it succeeded or
  failed. A body cut short by the client never reaches the app (Puma buffers
  the body first). Files left by a server killed mid-upload are removed on the
  next start.
- On startup the server checks that a file can be renamed from `tmp/` into
  `blobs/`, and refuses to start if not (e.g. `blobs/` is a separate
  filesystem or mount): `rename(2)` is atomic only within one mount and fails
  with `EXDEV` across mounts — it never falls back to copying.

Coordination between several server processes on one data dir is out of scope.

`GET /blobs` returns `[{"key", "size", "sha256", "modified_at"}]` for every
regular file under `<data-dir>/blobs`, sorted by key (`modified_at` is the file
mtime, ISO 8601 UTC). Files placed there directly are listed too; symlinks,
special files and names that aren't valid UTF-8 are skipped. Hashes are
computed on each request.

`DELETE /blobs/{key}` answers `204` (no body) when the blob was removed and `404`
when there is none — directories and symlinks are not blobs, so they are never
followed or removed. Directories left empty by a delete are pruned, so their
paths can become keys again.

### Keys and directory traversal

A key is a relative POSIX path (`docs/readme.txt`). `PUT`, `GET` and `DELETE
/blobs/{key}` answer `400` for a key that:

- contains a `..` segment, or a `.`/empty segment (`a//b`, `a/`), or is absolute
  (`/etc/passwd`, `%2Fetc%2Fpasswd`) — `%2F` counts as a separator, `%2e` as a dot;
- can't be a file name here: not valid UTF-8 after percent-decoding (incl.
  encoded surrogates and overlong forms such as `%C0%AE`), contains NUL, has
  malformed percent-escapes, or exceeds `NAME_MAX`/`PATH_MAX`.

`..` inside a name (`a..b`, `...`) is an ordinary character sequence. On top
of these textual checks the store confines the actual disk path: the
normalized path must lie strictly inside `<data-dir>/blobs`, and resolving it
with `realpath` must not change it, so a symlink placed in the store by hand is
never followed (`PUT` through it is `400`, `GET`/`DELETE` are `404`). The data
dir itself may be a symlink.

## Client

```sh
./run-client push <dir> --server <url>
./run-client pull <dir> --server <url>
./run-client sync <dir> --server <url>
./run-client status <dir> --server <url>
SYNCBOX_SERVER=<url> ./run-client push <dir>
```

`--server` takes precedence over `SYNCBOX_SERVER`; it must be an `http://` or
`https://` URL (a path prefix such as `http://host/syncbox` is allowed). The
client runs in the `client` compose service: `<dir>` must be an existing
directory and is bind-mounted into the container (read-only for `status`),
which uses the host's network, so `http://127.0.0.1:<port>` reaches a server
started with `run-server` on this machine. SIGTERM/SIGINT stop the container.

`push` walks `<dir>` recursively, hashes every regular file with SHA-256 and
compares it with `GET /blobs`. It `PUT`s the files that the server lacks or holds
with a different hash, under the file's relative POSIX path as the key
(`docs/readme.txt`). Files identical to the server's version are not sent again,
and blobs that exist only on the server are left alone. Each upload is printed
(`uploaded <key>`), then a summary (`push: N uploaded, M unchanged`).
Symlinks (never followed), special files and names that aren't valid UTF-8
are skipped with a warning on stderr.

`pull` is the reverse: it fetches `GET /blobs`, and `GET`s every blob that is
missing in `<dir>` or whose local file has a different SHA-256, writing it to
the key's relative POSIX path and creating directories as needed. Files
identical to the server's version are not downloaded again, and local files
the server doesn't have are left alone. Each download is printed
(`downloaded <key>`), then a summary (`pull: N downloaded, M unchanged`).
A download is streamed into a staging file next to its target
(`.syncbox-<random>.part`, removed on failure) and renamed over it once
complete, so a failed or interrupted pull never leaves a half-written file; a
body cut short of its `Content-Length` counts as a failure. A replaced file
keeps its permissions. Keys come from the server, so pull never writes
outside `<dir>`: keys that aren't plain relative paths (`..`, absolute, empty
or `.` segments, NUL) are skipped with a warning, and so are keys whose path
runs through a symlink (never followed) or ends at a symlink or special file
(never replaced).

`status` is a dry run of `push` and `pull`: it compares `<dir>` with
`GET /blobs` by key and SHA-256, by the same rules, and prints what they would
do, changing nothing on either side. Its only request is `GET /blobs` (no
`PUT`/`DELETE`, not even a blob download), local files are only read, and
`run-client` mounts `<dir>` read-only for it. Each difference is one line,
uploads first, then downloads, each sorted by key:

```
upload    new      local-only.txt      # push would upload it; the server lacks it
upload    changed  both.txt            # push would upload it; the server's copy differs
download  changed  both.txt            # pull would download it; the local copy differs
download  new      docs/remote.txt     # pull would download it; it is missing locally
status: 2 to upload, 2 to download, 1 unchanged
```

A file whose contents differ is listed in both directions, as `push` and `pull`
would each overwrite the other side's copy; which one wins is up to `sync`.
With no differences it prints `status: in sync, N unchanged`. It skips, with the
same warnings, whatever `push` and `pull` would skip; a key that `pull` couldn't
write because a file or directory is in the way is reported on stderr
(`syncbox: cannot download a/b: a is not a directory`) instead of failing.
Exit status is `0` whenever the comparison succeeds, whether or not anything
differs.

`sync` is `push` and `pull` in one pass, by the same rules (same keys, same
skips and warnings, same safe writes). A file on one side only is copied to the
other. For a file whose SHA-256 differs between the sides, sync checks which
side changed since the last sync:

- only the local copy changed: it is uploaded;
- only the server's copy changed: it is downloaded;
- both changed (a conflict): the copy with the later modification time wins,
  i.e. the local file's mtime against the blob's `modified_at` from `GET /blobs`.
  On a tie the local copy wins. Times are compared at the precision the server
  reports (microseconds), so nanoseconds the server can't show don't count.

Nothing is deleted on either side: deletions aren't synced. A file deleted on
one side is copied back from the other on the next sync.

Each transfer is printed (`uploaded <key>` / `downloaded <key>`). A conflict
also gets a line before the transfer that says which copy won and why. Then
comes a summary:

```
conflict notes.txt: changed on both sides since the last sync; the server's copy is newer
downloaded notes.txt
uploaded todo.txt
sync: 1 uploaded, 1 downloaded, 4 unchanged, 1 conflict
```

To know what changed since the last sync, sync keeps a state file,
`<dir>/.syncbox-state.json`. For each server URL it records the SHA-256 that
each key had on both sides when sync last found or made them equal. The file
belongs to syncbox and isn't content: `push`, `pull`, `status` and `sync`
never upload it. A key that contains `.syncbox-state.json` as a path segment
is skipped with a warning, at any depth, so a subdirectory synced on its own
keeps its state to itself. The state lives with the directory: a new directory,
or one syncing with a server for the first time, has none. A state file that
can't be read is ignored with a warning. Without a recorded state, a file that
differs on both sides can't be traced to one side's change, so it is handled
like a conflict (`differs on both sides, never synced`). Server URLs are
compared without a trailing `/` and with the default port filled in. The file
is rewritten only when the state changes, and not created until something has
been synced. If sync fails part way, what it synced up to then is still
recorded.

### Errors and exit status

Exit status: `0` on success, `2` for a bad command line, `1` if anything failed.
The spec asks only for "non-zero" in both cases below, so they share `1`; the
message on stderr says what went wrong.

**Server unreachable.** If the first request (`GET /blobs`) fails, the command
stops before changing anything and prints why:

```
syncbox: cannot reach server http://127.0.0.1:8080: Connection refused
syncbox: cannot reach server http://nas.invalid:8080: cannot resolve host name nas.invalid: Name or service not known
syncbox: cannot reach server http://10.0.0.9:8080: connection timed out after 10 seconds
syncbox: no answer from server http://127.0.0.1:8080 to GET /blobs within 60 seconds
syncbox: server answered GET /blobs with HTTP 500: <first line of the body>
```

The same goes for a missing `<dir>` and an unexpected listing. Every network
operation has a fixed time limit, so a dead or stuck server can't hang the
client: 10 s to connect (name lookup, TCP and TLS handshake), 60 s for each
read of an answer, and 60 s for each write of a request body. Requests are
never retried.

**Partial failure.** A file that fails doesn't stop the others. This covers a
network error on its request (including the server going away part way), an
HTTP error status, a local file that can't be read or written, or a file in
the way of a directory. The other files are still processed. The summary line
counts the failures, and a report on stderr lists each one:

```
uploaded a.txt
uploaded docs/c.txt
push: 2 uploaded, 0 unchanged, 3 failed
syncbox: push failed for 3 files:
  server answered PUT b.txt with HTTP 500: disk on fire
  no answer from server http://127.0.0.1:8080 to PUT big.iso within 60 seconds
  cannot read secret.txt: Permission denied
```

A subdirectory that can't be listed is reported the same way
(`cannot read directory private: Permission denied`), and the rest of the
tree is still walked. `sync` skips every key under such a directory: its files
may well exist, so they're neither overwritten with the server's copies nor
dropped from the sync state. `sync` records the state of what it did sync. A
failed file keeps its old state, so the next sync picks it up again. `status`
reports local files it can't read and compares the rest. A failed download
never leaves a half-written file, and a failed upload leaves the server's copy
as it was.

## Tests

```sh
./run-tests
```

Runs the Minitest suite (`test/`) inside the `tests` compose service.

## Layout

- `bin/syncbox-server` — server entry point (inside the container)
- `bin/syncbox` — client CLI entry point (inside the container)
- `lib/syncbox/server/config.rb` — flag/env configuration
- `lib/syncbox/server/app.rb` — Rack app (HTTP API)
- `lib/syncbox/server/store.rb` — blob storage on disk, key validation
- `lib/syncbox/server/runner.rb` — Puma boot
- `lib/syncbox/client/cli.rb`, `options.rb` — client command line
- `lib/syncbox/client/errors.rb` — client errors (exit statuses) and the collection of per-file failures
- `lib/syncbox/client/local_dir.rb` — walking, hashing and safely writing the local directory
- `lib/syncbox/client/remote.rb` — HTTP API client
- `lib/syncbox/client/push.rb`, `pull.rb`, `status.rb`, `sync.rb` — `push`, `pull`, `status`, `sync`
- `lib/syncbox/client/sync_state.rb` — the state `sync` keeps in `<dir>/.syncbox-state.json`
- `compose.yaml`, `Dockerfile` — container setup; `run-server`, `run-client`, `run-tests` — wrappers
