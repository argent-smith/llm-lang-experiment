import hashlib
import os
import tempfile
from datetime import datetime, timezone

from flask import Flask, Response, abort, jsonify, request

from .config import Config

_TMP_PREFIX = ".syncbox-tmp-"
_ITEM_PREFIX = "/blobs/"


class InvalidKey(Exception):
    pass


def _resolve_blob_path(root: str, key: str) -> str:
    """Resolve `key` to an on-disk path inside `root`.

    Raises InvalidKey if the key is malformed (empty, absolute, containing
    '.'/'..' segments), can't be represented as a filesystem path, or -
    once symlinks are resolved - would land outside `root` (e.g. via a
    symlink planted inside the storage directory).
    """
    if not key:
        raise InvalidKey("key must not be empty")
    if "\x00" in key:
        raise InvalidKey("key must not contain a NUL byte")
    parts = key.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise InvalidKey("key must not contain empty, '.', or '..' segments")
    try:
        key.encode("utf-8", errors="strict")
        candidate = os.path.join(root, *parts)
        real_root = os.path.realpath(root)
        real_candidate = os.path.realpath(candidate)
        escapes_root = os.path.commonpath([real_root, real_candidate]) != real_root
    except (UnicodeError, ValueError, OSError) as exc:
        raise InvalidKey("key is not representable on this filesystem") from exc
    if escapes_root:
        raise InvalidKey("key escapes the storage root")
    return candidate


def _sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def create_app(config: Config) -> Flask:
    app = Flask(__name__)
    app.config["SYNCBOX_CONFIG"] = config

    root = config.data_dir
    os.makedirs(root, exist_ok=True)

    @app.get("/healthz")
    def healthz():
        return "", 200

    @app.get("/blobs")
    def list_blobs():
        items = []
        for dirpath, _dirnames, filenames in os.walk(root):
            for name in filenames:
                if name.startswith(_TMP_PREFIX):
                    continue
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, root).replace(os.sep, "/")
                try:
                    st = os.stat(full)
                    sha256 = _sha256_file(full)
                except OSError:
                    continue
                modified_at = datetime.fromtimestamp(
                    st.st_mtime, tz=timezone.utc
                ).strftime("%Y-%m-%dT%H:%M:%SZ")
                items.append(
                    {
                        "key": rel,
                        "size": st.st_size,
                        "sha256": sha256,
                        "modified_at": modified_at,
                    }
                )
        return jsonify(items), 200

    def get_blob(key):
        try:
            path = _resolve_blob_path(root, key)
        except InvalidKey as exc:
            return jsonify(error=str(exc)), 400
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            abort(404)
        return Response(data, mimetype="application/octet-stream")

    def put_blob(key):
        try:
            dest = _resolve_blob_path(root, key)
        except InvalidKey as exc:
            return jsonify(error=str(exc)), 400

        data = request.get_data()
        dest_dir = os.path.dirname(dest)
        tmp_path = None
        try:
            os.makedirs(dest_dir, exist_ok=True)
            # The temp file lives in dest_dir itself (not a shared tmp dir)
            # so it is always on the same filesystem as dest, guaranteeing
            # os.replace below is an atomic rename rather than a cross-device
            # copy - concurrent GETs on this key always see fully old or
            # fully new content, never a partial write.
            fd, tmp_path = tempfile.mkstemp(dir=dest_dir, prefix=_TMP_PREFIX)
            with os.fdopen(fd, "wb") as f:
                f.write(data)
            os.replace(tmp_path, dest)
            tmp_path = None
        except OSError:
            return jsonify(error="key cannot be stored on this filesystem"), 400
        finally:
            if tmp_path is not None:
                try:
                    os.remove(tmp_path)
                except OSError:
                    pass

        return (
            jsonify(key=key, sha256=hashlib.sha256(data).hexdigest(), size=len(data)),
            201,
        )

    def delete_blob(key):
        try:
            path = _resolve_blob_path(root, key)
        except InvalidKey as exc:
            return jsonify(error=str(exc)), 400
        try:
            os.remove(path)
        except OSError:
            abort(404)
        return "", 204

    _blob_item_handlers = {"GET": get_blob, "PUT": put_blob, "DELETE": delete_blob}

    @app.before_request
    def dispatch_blob_item():
        # Routed manually (rather than via a Flask/Werkzeug URL rule) so that
        # arbitrary key values — including ones Werkzeug's own URL matcher
        # would special-case (encoded slashes, control characters, repeated
        # slashes, ".."/"." segments, an empty key) — all reach the same
        # validation instead of surfacing routing-layer status codes that
        # the API contract for /blobs/{key} doesn't declare.
        path = request.path
        if not path.startswith(_ITEM_PREFIX):
            return None
        handler = _blob_item_handlers.get(request.method)
        if handler is None:
            abort(405)
        key = path[len(_ITEM_PREFIX) :]
        return handler(key)

    return app
