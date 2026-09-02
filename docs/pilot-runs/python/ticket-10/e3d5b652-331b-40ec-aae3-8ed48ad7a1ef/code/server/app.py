import hashlib
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path

from flask import Flask, jsonify, request, send_file

# Reserved path segment used for atomic-write staging (see write_blob_atomic).
# Keys resolving into a directory with this name are rejected so temp files
# are never addressable through the public API.
TMP_DIR_NAME = ".syncbox-tmp"


class InvalidKeyError(Exception):
    """Raised when a key can't be safely mapped to a path inside the data dir."""


def resolve_blob_path(data_dir, key):
    if not key or key.startswith("/") or "\x00" in key:
        raise InvalidKeyError(key)

    segments = key.split("/")
    if ".." in segments or TMP_DIR_NAME in segments:
        raise InvalidKeyError(key)

    # U+FFFD is what invalid percent-encoded UTF-8 bytes decode to
    # (e.g. "%ff%fe") -- the original key bytes are unrecoverable.
    if "�" in key:
        raise InvalidKeyError(key)

    root = Path(data_dir).resolve()

    try:
        key.encode("utf-8", errors="strict")
        candidate = (root / key).resolve()
    except (UnicodeError, ValueError, OSError):
        raise InvalidKeyError(key)

    # Authoritative check: regardless of what the checks above missed, the
    # resolved path must stay inside root. Catches symlink escapes and any
    # traversal shape not caught by the segment/prefix checks above.
    if candidate != root and root not in candidate.parents:
        raise InvalidKeyError(key)

    return candidate


def write_blob_atomic(path, content):
    """Write content to path without ever exposing a partially-written file.

    Writes to a uniquely-named temp file inside a sibling ``.syncbox-tmp``
    directory (same parent as `path`, so guaranteed to be the same
    filesystem) and atomically renames it into place. A concurrent reader
    of `path` therefore always sees either the fully old file or the fully
    new one, never a torn write -- and concurrent writers of the same key
    each write their own temp file, so they never corrupt each other's data.

    Structural key validation (resolve_blob_path) can't catch every key the
    underlying filesystem refuses: some byte sequences that are valid UTF-8
    still aren't representable as a path entry on a given filesystem/locale
    and surface only once the OS actually tries to create/rename the file
    (EIO, ENOENT-after-write, EILSEQ "invalid or incomplete multibyte
    character", etc.), sometimes intermittently. Any such failure -- at
    mkdir, open, write, fsync, or rename -- means this key can't be stored,
    which is a 400 (invalid key) per the API contract, not a crash. We
    raise InvalidKeyError for any OSError/UnicodeError from that pipeline
    so callers get a uniform result regardless of which step failed or
    which specific bytes triggered it.
    """
    tmp_dir = path.parent / TMP_DIR_NAME
    tmp_path = None

    try:
        tmp_dir.mkdir(parents=True, exist_ok=True)
        tmp_path = tmp_dir / f"{uuid.uuid4().hex}.tmp"
        with open(tmp_path, "wb") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, path)
    except (OSError, UnicodeError) as exc:
        if tmp_path is not None:
            tmp_path.unlink(missing_ok=True)
        raise InvalidKeyError(str(path)) from exc
    except BaseException:
        if tmp_path is not None:
            tmp_path.unlink(missing_ok=True)
        raise


def blob_exists(path):
    """Check whether `path` names an existing blob file.

    Path.is_file() already swallows the common "doesn't exist" errnos
    (ENOENT, ENOTDIR, EBADF, ELOOP) and returns False for those. Anything
    else it lets through -- e.g. EIO or EILSEQ from a key whose decoded
    bytes the filesystem can't handle -- which means "this key can't even
    be looked up", i.e. a 400 (invalid key), not an unhandled crash.
    """
    try:
        return path.is_file()
    except (OSError, UnicodeError) as exc:
        raise InvalidKeyError(str(path)) from exc


def create_app(data_dir):
    app = Flask(__name__)
    app.config["DATA_DIR"] = data_dir

    @app.errorhandler(InvalidKeyError)
    def handle_invalid_key(error):
        return jsonify(error="invalid key"), 400

    @app.errorhandler(404)
    def handle_unrouted_blob_path(error):
        # A key Werkzeug's own routing can't match at all (e.g. one that
        # decodes to a literal "\n", which breaks the <path:key> regex)
        # never reaches our view functions, so it never reaches
        # resolve_blob_path either -- it surfaces here as a generic,
        # non-JSON 404 instead. That key is exactly as invalid as one
        # resolve_blob_path would reject, so treat it the same way: 400,
        # not an unexplained 404. Deliberate `return "", 404` from our own
        # view functions (blob genuinely missing) never raises, so it
        # never reaches this handler.
        if request.path.startswith("/blobs/"):
            return jsonify(error="invalid key"), 400
        return error

    @app.get("/healthz")
    def healthz():
        return "", 200

    @app.get("/blobs")
    def list_blobs():
        root = Path(data_dir)
        blobs = []
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            relative = path.relative_to(root)
            if TMP_DIR_NAME in relative.parts:
                continue
            stat = path.stat()
            blobs.append(
                {
                    "key": relative.as_posix(),
                    "size": stat.st_size,
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                    "modified_at": datetime.fromtimestamp(
                        stat.st_mtime, tz=timezone.utc
                    )
                    .isoformat()
                    .replace("+00:00", "Z"),
                }
            )

        return jsonify(blobs), 200

    @app.put("/blobs/<path:key>")
    def put_blob(key):
        path = resolve_blob_path(data_dir, key)
        content = request.get_data()
        write_blob_atomic(path, content)

        return (
            jsonify(
                key=key,
                sha256=hashlib.sha256(content).hexdigest(),
                size=len(content),
            ),
            201,
        )

    @app.get("/blobs/<path:key>")
    def get_blob(key):
        path = resolve_blob_path(data_dir, key)
        if not blob_exists(path):
            return "", 404

        try:
            return send_file(path, mimetype="application/octet-stream")
        except (OSError, UnicodeError) as exc:
            raise InvalidKeyError(str(path)) from exc

    @app.delete("/blobs/<path:key>")
    def delete_blob(key):
        path = resolve_blob_path(data_dir, key)
        if not blob_exists(path):
            return "", 404

        try:
            path.unlink()
        except (OSError, UnicodeError) as exc:
            raise InvalidKeyError(str(path)) from exc
        return "", 204

    return app
