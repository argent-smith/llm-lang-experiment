import io
import sys

import pytest

from syncbox_server.app import create_app
from syncbox_server.config import Config

GET_STATUSES = {200, 404, 400}
PUT_STATUSES = {201, 400}
DELETE_STATUSES = {204, 404, 400}

INVALID_KEYS = [
    "",
    "..",
    ".",
    "../etc/passwd",
    "a/..",
    "a/../b",
    "a//b",
    "a/",
    "/abs",
    "a\x00b",
    "a" * 300,
]

# Not necessarily invalid — legal-but-unusual key text a fuzzer might try.
# These only need to stay inside the declared status codes, not hit 400.
GARBAGE_KEYS = INVALID_KEYS + [
    "weird\"quote",
    "weird;semicolon",
    "weird\\backslash",
    "  spaces  ",
]


@pytest.fixture
def client(tmp_path):
    app = create_app(Config(data_dir=str(tmp_path), port=8080))
    return app.test_client()


def test_list_blobs_empty_returns_200(client):
    response = client.get("/blobs")

    assert response.status_code == 200
    assert response.get_json() == []


def test_put_get_list_delete_roundtrip(client):
    put_response = client.put("/blobs/docs/readme.txt", data=b"hello world")
    assert put_response.status_code == 201
    body = put_response.get_json()
    assert body["key"] == "docs/readme.txt"
    assert body["size"] == len(b"hello world")
    assert len(body["sha256"]) == 64

    [meta] = client.get("/blobs").get_json()
    assert meta["key"] == "docs/readme.txt"
    assert meta["sha256"] == body["sha256"]
    assert meta["size"] == body["size"]

    get_response = client.get("/blobs/docs/readme.txt")
    assert get_response.status_code == 200
    assert get_response.data == b"hello world"

    delete_response = client.delete("/blobs/docs/readme.txt")
    assert delete_response.status_code == 204

    assert client.get("/blobs/docs/readme.txt").status_code == 404
    assert client.get("/blobs").get_json() == []


def test_get_missing_blob_returns_404(client):
    assert client.get("/blobs/missing").status_code == 404


def test_delete_missing_blob_returns_404(client):
    assert client.delete("/blobs/missing").status_code == 404


@pytest.mark.parametrize("key", INVALID_KEYS)
def test_put_rejects_invalid_keys_with_400(client, key):
    response = client.put(f"/blobs/{key}", data=b"x")

    assert response.status_code == 400


@pytest.mark.parametrize("key", GARBAGE_KEYS)
def test_blob_endpoints_never_answer_outside_the_declared_contract(client, key):
    # GET /blobs is unconditional per the schema: only 200 is declared.
    assert client.get("/blobs").status_code == 200

    get_status = client.get(f"/blobs/{key}").status_code
    assert get_status in GET_STATUSES, (key, get_status)

    put_status = client.put(f"/blobs/{key}", data=b"x").status_code
    assert put_status in PUT_STATUSES, (key, put_status)

    delete_status = client.delete(f"/blobs/{key}").status_code
    assert delete_status in DELETE_STATUSES, (key, delete_status)


def test_get_blobs_returns_200_regardless_of_stored_content(client):
    for key in GARBAGE_KEYS:
        client.put(f"/blobs/{key}", data=b"x")

    assert client.get("/blobs").status_code == 200


def _wsgi_response_status(app, method, path_info, body=b"x"):
    environ = {
        "REQUEST_METHOD": method,
        "SCRIPT_NAME": "",
        "PATH_INFO": path_info,
        "QUERY_STRING": "",
        "SERVER_NAME": "127.0.0.1",
        "SERVER_PORT": "80",
        "SERVER_PROTOCOL": "HTTP/1.1",
        "wsgi.version": (1, 0),
        "wsgi.url_scheme": "http",
        "wsgi.input": io.BytesIO(body),
        "wsgi.errors": sys.stderr,
        "wsgi.multithread": False,
        "wsgi.multiprocess": False,
        "wsgi.run_once": False,
        "CONTENT_LENGTH": str(len(body)),
    }
    captured = {}

    def start_response(status, headers):
        captured["status"] = status

    result = app.wsgi_app(environ, start_response)
    b"".join(result)
    return int(captured["status"].split()[0])


def test_key_with_control_characters_does_not_crash_get(tmp_path):
    # A key containing raw CR/LF (as arrives once a real WSGI server
    # percent-decodes a URL like /blobs/weird%0D%0Aname) must not make the
    # server blow up when it is later downloaded — response status must
    # still be one of the ones GET /blobs/{key} declares, never a 5xx.
    app = create_app(Config(data_dir=str(tmp_path), port=8080))
    key = "weird\r\nname"

    put_status = _wsgi_response_status(app, "PUT", "/blobs/" + key)
    assert put_status in PUT_STATUSES

    get_status = _wsgi_response_status(app, "GET", "/blobs/" + key)
    assert get_status in GET_STATUSES
    assert get_status < 500
