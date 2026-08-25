from flask import Flask


def create_app(data_dir):
    app = Flask(__name__)
    app.config["DATA_DIR"] = data_dir

    @app.get("/healthz")
    def healthz():
        return "", 200

    return app
