import hashlib
import os
from datetime import datetime, timezone
from pathlib import Path

from flask import Flask, jsonify, request, send_file


class InvalidKeyError(Exception):
    """Raised when a key can't be safely mapped to a path inside the data dir."""


def resolve_blob_path(data_dir, key):
    if not key or key.startswith("/") or "\x00" in key:
        raise InvalidKeyError(key)

    if ".." in key.split("/"):
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


def create_app(data_dir):
    app = Flask(__name__)
    app.config["DATA_DIR"] = data_dir

    @app.errorhandler(InvalidKeyError)
    def handle_invalid_key(error):
        return jsonify(error="invalid key"), 400

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
            stat = path.stat()
            blobs.append(
                {
                    "key": path.relative_to(root).as_posix(),
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
        os.makedirs(path.parent, exist_ok=True)

        content = request.get_data()
        with open(path, "wb") as f:
            f.write(content)

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
        if not path.is_file():
            return "", 404

        return send_file(path, mimetype="application/octet-stream")

    @app.delete("/blobs/<path:key>")
    def delete_blob(key):
        path = resolve_blob_path(data_dir, key)
        if not path.is_file():
            return "", 404

        path.unlink()
        return "", 204

    return app
