from syncbox_server.app import create_app
from syncbox_server.config import Config


def test_healthz_returns_200(tmp_path):
    app = create_app(Config(data_dir=str(tmp_path), port=8080))
    client = app.test_client()

    response = client.get("/healthz")

    assert response.status_code == 200
