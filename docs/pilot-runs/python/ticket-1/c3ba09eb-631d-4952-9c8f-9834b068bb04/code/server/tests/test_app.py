from server.app import create_app


def test_healthz_returns_200(tmp_path):
    app = create_app(tmp_path)
    client = app.test_client()

    response = client.get("/healthz")

    assert response.status_code == 200


def test_healthz_wrong_method_not_allowed(tmp_path):
    app = create_app(tmp_path)
    client = app.test_client()

    response = client.post("/healthz")

    assert response.status_code == 405
