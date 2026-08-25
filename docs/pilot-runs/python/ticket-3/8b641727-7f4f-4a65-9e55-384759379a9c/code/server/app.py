import hashlib
from datetime import datetime, timezone
from pathlib import Path

from flask import Flask, abort, jsonify, request, send_file


def _blob_meta(data_dir, path):
    content = path.read_bytes()
    modified_at = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)
    return {
        "key": path.relative_to(data_dir).as_posix(),
        "size": len(content),
        "sha256": hashlib.sha256(content).hexdigest(),
        "modified_at": modified_at.isoformat().replace("+00:00", "Z"),
    }


def create_app(data_dir):
    app = Flask(__name__)
    app.config["DATA_DIR"] = Path(data_dir)

    @app.get("/healthz")
    def healthz():
        return "", 200

    @app.get("/blobs")
    def list_blobs():
        data_dir = app.config["DATA_DIR"]
        blobs = [
            _blob_meta(data_dir, path)
            for path in sorted(data_dir.rglob("*"))
            if path.is_file()
        ]
        return jsonify(blobs), 200

    @app.put("/blobs/<path:key>")
    def put_blob(key):
        content = request.get_data()
        path = app.config["DATA_DIR"] / key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)

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
        path = app.config["DATA_DIR"] / key
        if not path.is_file():
            abort(404)
        return send_file(path, mimetype="application/octet-stream")

    return app
