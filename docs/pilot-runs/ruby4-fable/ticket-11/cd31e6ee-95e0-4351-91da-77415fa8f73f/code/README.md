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

# Both ways in one pass: files only here go up, blobs only there come down,
# a file changed on one side since the last sync is copied to the other, and
# a file changed on both sides goes to the fresher mtime / modified_at
# (local wins a tie). Nothing is ever deleted on either side.
./run-client sync ./photos --server http://127.0.0.1:8080
#   uploaded 2024/trip/IMG_0003.jpg (new, 2871200 bytes)
#   downloaded 2024/trip/IMG_0002.jpg (new, 2960113 bytes)
#   uploaded notes.txt (changed locally, 440 bytes)
#   downloaded todo.md (conflict, server is newer, 1024 bytes)
#   sync done: 2 uploaded, 2 downloaded, 58 unchanged, 1 conflict(s) resolved

SYNCBOX_SERVER=http://127.0.0.1:8080 ./run-client pull ./photos   # env instead of --server
```

`run-client <push|pull|sync|status> <dir> --server <url>` forwards the
subcommand and arguments to the `syncbox` executable (`bin/syncbox`) running
in a container; `--server` falls back to `SYNCBOX_SERVER`.

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
would download the server's — which one `sync` picks is decided by its
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

`sync` is `push` and `pull` in one pass plus the spec's conflict rule. It
scans `<dir>`, fetches the listing once and walks the union of keys. A key
present on one side only is copied to the other (`uploaded … (new, …)` /
`downloaded … (new, …)`); a key identical on both sides is left alone. When
the hashes differ, the *last known common state* decides whose change it is:
`sync` records, in `<dir>/.syncbox/state.json`, the SHA-256 of every key
that was identical on both sides at the end of a run. On the next run a side
whose hash still equals that recorded value has not changed, so the
difference belongs to the other side alone and is copied in that direction
(`changed locally` → upload, `changed on server` → download) — timestamps
play no role in these cases. Only when *both* sides have moved away from the
common version is it a conflict, resolved exactly as the spec says: the
fresher of the server's `modified_at` (the time the blob was stored, from
`GET /blobs`) and the local file's mtime wins, and on a tie the local version
wins (`conflict, server is newer` / `conflict, local is newer` /
`conflict, same mtime, local wins`). The two instants are compared exactly;
since `modified_at` has millisecond precision, a local mtime inside the same
millisecond but after it counts as newer, which gives the same answer as the
tie rule. Content is compared by hash only — a file touched but not changed
is unchanged. When no common version is known yet (the first run on a
directory, or a key never seen in sync before) and the two sides differ, the
same mtime rule picks the side to copy, reported as `differs on both sides,
…` and not counted as a conflict; the run that ends with the sides agreeing
establishes the common state for the next one.

`sync` never deletes anything, on either side: a file deleted locally since
the last run comes back from the server (`missing locally`), a blob deleted on
the server is re-uploaded from the local copy (`missing on server`), a key
gone from both sides is simply forgotten. Propagating deletions is not part
of the spec. Transfers are the same as `push`'s and `pull`'s (streamed `PUT`
with the returned hash checked, staged `GET` renamed into place only when the
hash matches the listing), with one progress line per transfer in key order
and a summary; the exit code is `0` when the run completed.

The state lives inside `<dir>` because that is the only thing the client
container can see between runs. `.syncbox/` at the top of `<dir>` is
reserved for it: the scan never descends into it (so `push`, `status` and
`sync` never upload it) and a key under it is refused like an unsafe key (so
no download can write into it). Entries are kept per server URL, so a
directory may be synced with several servers; the file is rewritten
atomically (staging file + `rename`) and also after a failed run, for the
keys that were already reconciled, so a rerun continues where the failed one
stopped. A corrupt or newer-versioned state file is reported with its path
before anything is transferred; deleting it resets the common state, after
which the next run uses the no-common-state rules above. `.syncbox/` is also
excluded when `<dir>` is mounted read-only (`push`, `status`), which simply
means those commands never write it.

### Errors and exit codes

Every network operation has an explicit, fixed timeout: 10 s to open a
connection (name resolution and TCP handshake together), 60 s between two
chunks when reading a response, 60 s between two chunks when sending a
body. A server that is down, a name that does not resolve, an address that
drops packets or a server that accepts the connection and never answers
therefore ends in an error, never in a hang. The error names the server, the
cause in plain words and the request:

```
syncbox: cannot reach server at http://127.0.0.1:8080: connection refused by 127.0.0.1:8080 (is the server running there?) (GET /blobs)
syncbox: cannot reach server at http://nas.local:8080: cannot resolve host name "nas.local" (Name or service not known) (GET /blobs)
syncbox: cannot reach server at http://10.0.0.9:8080: no response from 10.0.0.9:8080 within 60s (read timeout) (PUT /blobs/big.bin)
```

A request that fails on a keep-alive connection the server has since closed
is retried once on a fresh connection; a timeout is never retried.

The spec's partial-failure rule applies to `push`, `pull`, `sync` and
`status` alike: when one file out of many fails, the others are still
processed. A failure is reported on stderr the moment it happens
(`syncbox: failed <key>: <reason>`), the command runs to the end, prints its
summary with a `failed` count, and then lists the failed keys once more:

```
uploaded a.txt (new, 1 bytes)
uploaded c.txt (new, 1 bytes)
push done: 2 uploaded, 0 unchanged, 1 failed, 3 file(s) scanned
syncbox: failed docs/b.txt: server answered 500 Internal Server Error to PUT /blobs/docs/b.txt
syncbox: push incomplete: 1 of 3 file(s) failed
syncbox:   docs/b.txt: server answered 500 Internal Server Error to PUT /blobs/docs/b.txt
```

Per-file failures are: the server answered the file's request with an
unexpected status (a `5xx`, a `404` for a blob deleted since the listing); a
network error or timeout on that one request; the server stored or served
bytes with a different SHA-256 than promised; a local file that cannot be
read or whose name is not valid UTF-8 (so cannot be a key); a local
directory that cannot be listed; a download with a directory or symlink in
the way, an unsafe key, or a disk error; a `sync` conflict whose server
`modified_at` is not a timestamp. In `sync` a failed key keeps its last
common state, so the next run tries it again, and a local file that could
not be read is never overwritten by the server's version — the key is left
out of that run. In `status` such a key is reported as `not compared`.

Two files in a row whose requests cannot reach the server mean the server
is gone rather than the files: the command stops instead of failing every
remaining file one by one (against a black-holed address each would wait
for the connect timeout), prints the report with the number of files not
attempted, and exits as "unreachable":

```
syncbox: failed b.txt: cannot reach server at http://127.0.0.1:8080: connection refused by 127.0.0.1:8080 (is the server running there?) (PUT /blobs/b.txt)
syncbox: failed c.txt: cannot reach server at http://127.0.0.1:8080: connection refused by 127.0.0.1:8080 (is the server running there?) (PUT /blobs/c.txt)
syncbox: push aborted: 2 of 5 file(s) failed, 2 not attempted
syncbox:   b.txt: cannot reach server at http://127.0.0.1:8080: connection refused by 127.0.0.1:8080 (is the server running there?) (PUT /blobs/b.txt)
syncbox:   c.txt: cannot reach server at http://127.0.0.1:8080: connection refused by 127.0.0.1:8080 (is the server running there?) (PUT /blobs/c.txt)
syncbox: server unreachable: cannot reach server at http://127.0.0.1:8080: connection refused by 127.0.0.1:8080 (is the server running there?) (PUT /blobs/c.txt); giving up after 2 consecutive requests failed (2 file(s) not attempted — rerun once the server is back)
```

Exit codes:

| Code  | Meaning |
| ----- | ------- |
| `0`   | Success: every file went through (for `status`: the comparison is complete). |
| `1`   | Failure: the command could not do its job — the server is unreachable (connection refused, unknown host, timeout) or stopped answering mid-run, the listing is outside the contract, the directory is missing, the sync state is corrupt or cannot be saved. |
| `2`   | Usage error (bad arguments, missing `--server`). |
| `3`   | Partial failure: the command ran to the end, but one or more files failed and are listed on stderr; the others were processed. |
| `130` | Interrupted (Ctrl-C / SIGTERM); `sync` still saves the state for the keys it reconciled. |

The spec only requires "non-zero" for the last two failure kinds; `1` and
`3` keep "nothing could be done" apart from "most of it was done" for
scripts. The successful paths — output and exit code `0` — are unchanged
from the earlier tickets.

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
directory), `Sync` against an in-memory server with per-key `modified_at`
(one-sided files both ways, changed-only-locally and changed-only-on-server
regardless of timestamps, every branch of the conflict rule including the
tie and sub-millisecond mtimes, the no-common-state case, deletions not
propagated, per-server state, state saved up to a failed transfer, corrupt
state and reserved keys refused), `SyncState` on its own (round trips,
atomic rewrite, malformed files), and the real `bin/syncbox` process
pushing into, pulling out of, syncing with and reporting status against the
real `bin/syncbox-server` process over HTTP, comparing SHA-256 hashes end to
end — the sync scenario walks two directories through first runs, one-sided
edits, both conflict outcomes, an exact-tie conflict (local mtime set to the
server's `modified_at`) and deletions on each side — including the
unreachable-server and something-in-the-way paths. `status` is additionally run
against a recording HTTP stub that proves the only request it sends is
`GET /blobs`, and the real server's listing (hashes and `modified_at`) is
checked to be identical before and after. `Api#get` is also exercised
against truncated bodies and an unwritable destination (`/dev/full`).

Network errors and partial failures (ticket 11) are driven through
`FakeHttpServer` (`test/support/`), an in-memory implementation of the API
on a raw socket that can answer `5xx` for one key, never answer at all, or
close its port after N requests as a crashed server would. `Api` is checked
for the message and bounded wait of connection refused, unknown host and a
server that never answers (read timeout), and for not retrying a timeout on
a reused connection; the `Runner` in-process (with shortened timeouts) for
exit `1` and the stderr message on refused / unknown-host / never-answering
servers for every command, exit `3` with the report on a partial failure,
and exit `1` after the report when the server dies mid-run; `Push`, `Pull`
and `Sync` against their stand-ins for one failing file among many (`5xx`,
a transient network error, SHA-256 mismatch, unreadable or non-UTF-8-named
local file, unsafe or in-the-way key, unparseable `modified_at`) — the rest
transferred, the summary and report exact, `sync`'s state kept for the
failed key and the unreadable file never overwritten — and for the
two-in-a-row unreachable rule; `LocalTree.scan` with a failure handler
(unreadable file, unlistable directory, non-UTF-8 name reported, the rest
scanned; the directory itself unreadable still an error); `Status` with an
entry it cannot compare. The real `bin/syncbox` process is run against
`FakeHttpServer` for `push`, `pull` and `sync` with one failing key (exit
`3`, the others transferred, no staging file left, the report on stderr),
`status` and `push` with an unreadable file, a server that dies mid-push
(exit `1`, report, bounded time), an unresolvable host name and connection
refused for every command.

## Layout

| Path                      | Purpose                                              |
| ------------------------- | ---------------------------------------------------- |
| `bin/syncbox-server`      | In-container server entry point (parses flags, boots Puma) |
| `bin/syncbox`             | In-container client entry point (the spec's `syncbox` executable) |
| `lib/syncbox/server/`     | `Config` (CLI/env), `App` (Rack routes), `BlobStore` (files on disk), `Runner` (Puma) |
| `lib/syncbox/client/`     | `Options` (CLI/env), `Api` (HTTP, timeouts), `LocalTree` (scan, key↔path, SHA-256), `Transfer` (upload/download), `Failures` (partial-failure bookkeeping and report), `SyncState` (last common state), `Push`, `Pull`, `Status`, `Sync`, `Runner` (exit codes) |
| `test/`, `test/client/`   | Minitest: unit tests plus real-process HTTP tests for server and client; `test/support/` holds the fake HTTP server |
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
- [x] Ticket 10: client `sync` (both directions in one pass, last common state in
      `<dir>/.syncbox/state.json`, conflicts resolved by the spec's rule: fresher
      `modified_at`/mtime wins, local on a tie; no deletions either way) — see “Client”
- [x] Ticket 11: network errors and partial failures on the client (fixed timeouts on
      every request with the cause in the message, per-file failures reported and
      the rest still processed, end-of-run report, exit `1` / `3`) — see “Errors and exit codes”
