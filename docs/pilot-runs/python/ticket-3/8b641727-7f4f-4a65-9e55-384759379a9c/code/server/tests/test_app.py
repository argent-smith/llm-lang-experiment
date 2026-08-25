import hashlib
from datetime import datetime

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


def test_list_blobs_empty_storage_returns_empty_array(tmp_path):
    app = create_app(tmp_path)
    client = app.test_client()

    response = client.get("/blobs")

    assert response.status_code == 200
    assert response.json == []


def test_list_blobs_returns_metadata_for_all_blobs(tmp_path):
    app = create_app(tmp_path)
    client = app.test_client()
    client.put("/blobs/greeting.txt", data=b"hello world")
    client.put("/blobs/docs/readme.txt", data=b"nested content")

    response = client.get("/blobs")

    assert response.status_code == 200
    by_key = {item["key"]: item for item in response.json}
    assert set(by_key) == {"greeting.txt", "docs/readme.txt"}

    greeting = by_key["greeting.txt"]
    assert greeting["size"] == len(b"hello world")
    assert greeting["sha256"] == hashlib.sha256(b"hello world").hexdigest()
    # modified_at is ISO 8601 UTC, parseable and ending in Z
    assert greeting["modified_at"].endswith("Z")
    datetime.fromisoformat(greeting["modified_at"].replace("Z", "+00:00"))

    readme = by_key["docs/readme.txt"]
    assert readme["size"] == len(b"nested content")
    assert readme["sha256"] == hashlib.sha256(b"nested content").hexdigest()


def test_list_blobs_reflects_overwrite(tmp_path):
    app = create_app(tmp_path)
    client = app.test_client()
    client.put("/blobs/greeting.txt", data=b"first")
    client.put("/blobs/greeting.txt", data=b"second version")

    response = client.get("/blobs")

    assert response.status_code == 200
    assert len(response.json) == 1
    assert response.json[0]["key"] == "greeting.txt"
    assert response.json[0]["size"] == len(b"second version")
    assert response.json[0]["sha256"] == hashlib.sha256(b"second version").hexdigest()
