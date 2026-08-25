import hashlib

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


def test_put_blob_returns_201_with_metadata(tmp_path):
    app = create_app(tmp_path)
    client = app.test_client()
    content = b"hello world"

    response = client.put("/blobs/greeting.txt", data=content)

    assert response.status_code == 201
    assert response.json == {
        "key": "greeting.txt",
        "sha256": hashlib.sha256(content).hexdigest(),
        "size": len(content),
    }


def test_put_blob_writes_file_to_disk(tmp_path):
    app = create_app(tmp_path)
    client = app.test_client()

    client.put("/blobs/greeting.txt", data=b"hello world")

    assert (tmp_path / "greeting.txt").read_bytes() == b"hello world"


def test_put_blob_creates_nested_directories(tmp_path):
    app = create_app(tmp_path)
    client = app.test_client()
    content = b"nested content"

    response = client.put("/blobs/docs/readme.txt", data=content)

    assert response.status_code == 201
    assert response.json["key"] == "docs/readme.txt"
    assert (tmp_path / "docs" / "readme.txt").read_bytes() == content


def test_put_blob_overwrites_existing_key(tmp_path):
    app = create_app(tmp_path)
    client = app.test_client()

    client.put("/blobs/greeting.txt", data=b"first")
    response = client.put("/blobs/greeting.txt", data=b"second version")

    assert response.status_code == 201
    assert (tmp_path / "greeting.txt").read_bytes() == b"second version"


def test_get_blob_returns_200_with_bytes(tmp_path):
    app = create_app(tmp_path)
    client = app.test_client()
    client.put("/blobs/greeting.txt", data=b"hello world")

    response = client.get("/blobs/greeting.txt")

    assert response.status_code == 200
    assert response.data == b"hello world"


def test_get_blob_nested_key(tmp_path):
    app = create_app(tmp_path)
    client = app.test_client()
    client.put("/blobs/docs/readme.txt", data=b"nested content")

    response = client.get("/blobs/docs/readme.txt")

    assert response.status_code == 200
    assert response.data == b"nested content"


def test_get_blob_missing_returns_404(tmp_path):
    app = create_app(tmp_path)
    client = app.test_client()

    response = client.get("/blobs/missing.txt")

    assert response.status_code == 404
