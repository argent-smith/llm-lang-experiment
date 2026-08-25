import hashlib
import os

from flask import Flask, jsonify, request, send_file


def create_app(data_dir):
    app = Flask(__name__)
    app.config["DATA_DIR"] = data_dir

    @app.get("/healthz")
    def healthz():
        return "", 200

    @app.put("/blobs/<path:key>")
    def put_blob(key):
        path = os.path.join(data_dir, key)
        os.makedirs(os.path.dirname(path), exist_ok=True)

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
        path = os.path.join(data_dir, key)
        if not os.path.isfile(path):
            return "", 404

        return send_file(path, mimetype="application/octet-stream")

    return app
