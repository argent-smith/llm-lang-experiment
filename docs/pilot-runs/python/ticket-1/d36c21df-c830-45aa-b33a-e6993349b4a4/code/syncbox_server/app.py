from flask import Flask

from .config import Config


def create_app(config: Config) -> Flask:
    app = Flask(__name__)
    app.config["SYNCBOX_CONFIG"] = config

    @app.get("/healthz")
    def healthz():
        return "", 200

    return app
