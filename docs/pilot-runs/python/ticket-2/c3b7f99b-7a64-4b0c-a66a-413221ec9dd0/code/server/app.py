import hashlib
from pathlib import Path

from flask import Flask, abort, jsonify, request, send_file


def create_app(data_dir):
    app = Flask(__name__)
    app.config["DATA_DIR"] = Path(data_dir)

    @app.get("/healthz")
    def healthz():
        return "", 200

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
