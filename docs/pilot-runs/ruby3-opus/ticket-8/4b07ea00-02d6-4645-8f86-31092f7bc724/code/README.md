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
SYNCBOX_SERVER=<url> ./run-client push <dir>
```

`--server` takes precedence over `SYNCBOX_SERVER`; it must be an `http://` or
`https://` URL (a path prefix such as `http://host/syncbox` is allowed). The
client runs in the `client` compose service: `<dir>` must be an existing
directory and is bind-mounted into the container, which uses the host's
network, so `http://127.0.0.1:<port>` reaches a server started with
`run-server` on this machine. SIGTERM/SIGINT stop the container.

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

Exit status: `0` on success, `2` for a bad command line, `1` if the push or
pull fails (server unreachable, the server rejects an upload or a download, a
local file can't be read or written, a file is in the way of a directory or
the other way round): the client prints the reason to stderr and stops at the
first failure.

`sync` and `status` accept the same arguments but are not implemented yet:
they print a message saying so and exit with `1`.

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
- `lib/syncbox/client/local_dir.rb` — walking, hashing and safely writing the local directory
- `lib/syncbox/client/remote.rb` — HTTP API client
- `lib/syncbox/client/push.rb`, `pull.rb` — `push`, `pull`
- `compose.yaml`, `Dockerfile` — container setup; `run-server`, `run-client`, `run-tests` — wrappers
