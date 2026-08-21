from __future__ import annotations

import datetime
import hashlib
import os
import pathlib

from flask import Flask, Response, jsonify, request


def create_app(data_dir: str) -> Flask:
    app = Flask(__name__)
    app.config["DATA_DIR"] = data_dir

    @app.get("/healthz")
    def healthz():
        return "", 200

    @app.get("/blobs")
    def list_blobs():
        root = pathlib.Path(data_dir)
        blobs = []
        for path in root.rglob("*"):
            if not path.is_file():
                continue
            key = path.relative_to(root).as_posix()
            stat = path.stat()
            with open(path, "rb") as f:
                sha256 = hashlib.sha256(f.read()).hexdigest()
            modified_at = datetime.datetime.fromtimestamp(
                stat.st_mtime, tz=datetime.timezone.utc
            ).isoformat()
            blobs.append(
                {
                    "key": key,
                    "size": stat.st_size,
                    "sha256": sha256,
                    "modified_at": modified_at,
                }
            )
        blobs.sort(key=lambda b: b["key"])
        return jsonify(blobs), 200

    @app.put("/blobs/<path:key>")
    def put_blob(key: str):
        content = request.get_data()

        path = os.path.join(data_dir, key)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(content)

        return jsonify(
            {
                "key": key,
                "sha256": hashlib.sha256(content).hexdigest(),
                "size": len(content),
            }
        ), 201

    @app.get("/blobs/<path:key>")
    def get_blob(key: str):
        path = os.path.join(data_dir, key)
        if not os.path.isfile(path):
            return "", 404

        with open(path, "rb") as f:
            content = f.read()
        return Response(content, mimetype="application/octet-stream")

    return app
