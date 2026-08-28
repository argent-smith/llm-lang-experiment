import hashlib
import re

import pytest

from server.app import InvalidKeyError, create_app, resolve_blob_path


def test_healthz_returns_200(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.get("/healthz")

    assert response.status_code == 200


def test_put_blob_returns_201_with_key_sha256_size(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    content = b"hello world"

    response = client.put("/blobs/greeting.txt", data=content)

    assert response.status_code == 201
    assert response.get_json() == {
        "key": "greeting.txt",
        "sha256": hashlib.sha256(content).hexdigest(),
        "size": len(content),
    }


def test_put_blob_writes_file_to_data_dir(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    client.put("/blobs/greeting.txt", data=b"hello world")

    assert (tmp_path / "greeting.txt").read_bytes() == b"hello world"


def test_put_blob_creates_nested_directories(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.put("/blobs/docs/readme.txt", data=b"nested content")

    assert response.status_code == 201
    assert response.get_json()["key"] == "docs/readme.txt"
    assert (tmp_path / "docs" / "readme.txt").read_bytes() == b"nested content"


def test_put_blob_overwrites_existing_key(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    client.put("/blobs/greeting.txt", data=b"first")
    response = client.put("/blobs/greeting.txt", data=b"second")

    assert response.status_code == 201
    assert (tmp_path / "greeting.txt").read_bytes() == b"second"


def test_get_blob_returns_content_after_put(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    content = b"hello world"
    client.put("/blobs/greeting.txt", data=content)

    response = client.get("/blobs/greeting.txt")

    assert response.status_code == 200
    assert response.data == content


def test_get_blob_nested_key_after_put(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    client.put("/blobs/docs/readme.txt", data=b"nested content")

    response = client.get("/blobs/docs/readme.txt")

    assert response.status_code == 200
    assert response.data == b"nested content"


def test_get_blob_returns_404_when_missing(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.get("/blobs/missing.txt")

    assert response.status_code == 404


def test_list_blobs_returns_empty_array_for_empty_store(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.get("/blobs")

    assert response.status_code == 200
    assert response.get_json() == []


def test_list_blobs_returns_metadata_for_stored_blobs(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    content = b"hello world"
    client.put("/blobs/greeting.txt", data=content)

    response = client.get("/blobs")

    assert response.status_code == 200
    body = response.get_json()
    assert len(body) == 1
    entry = body[0]
    assert entry["key"] == "greeting.txt"
    assert entry["size"] == len(content)
    assert entry["sha256"] == hashlib.sha256(content).hexdigest()
    assert re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}", entry["modified_at"])


def test_list_blobs_includes_nested_keys_as_posix_paths(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    client.put("/blobs/docs/readme.txt", data=b"nested content")

    response = client.get("/blobs")

    body = response.get_json()
    assert [entry["key"] for entry in body] == ["docs/readme.txt"]


def test_list_blobs_lists_multiple_blobs(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    client.put("/blobs/a.txt", data=b"a")
    client.put("/blobs/docs/b.txt", data=b"bb")

    response = client.get("/blobs")

    body = response.get_json()
    keys = sorted(entry["key"] for entry in body)
    assert keys == ["a.txt", "docs/b.txt"]


def test_delete_blob_returns_204_and_removes_file(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    client.put("/blobs/greeting.txt", data=b"hello world")

    response = client.delete("/blobs/greeting.txt")

    assert response.status_code == 204
    assert response.data == b""
    assert not (tmp_path / "greeting.txt").exists()


def test_delete_blob_returns_404_when_missing(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.delete("/blobs/missing.txt")

    assert response.status_code == 404


def test_delete_blob_nested_key(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    client.put("/blobs/docs/readme.txt", data=b"nested content")

    response = client.delete("/blobs/docs/readme.txt")

    assert response.status_code == 204
    assert not (tmp_path / "docs" / "readme.txt").exists()


def test_deleted_blob_is_absent_from_get_and_list(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    client.put("/blobs/greeting.txt", data=b"hello world")

    client.delete("/blobs/greeting.txt")

    assert client.get("/blobs/greeting.txt").status_code == 404
    assert client.get("/blobs").get_json() == []


def test_delete_blob_does_not_affect_other_blobs(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    client.put("/blobs/a.txt", data=b"a")
    client.put("/blobs/docs/b.txt", data=b"bb")

    client.delete("/blobs/a.txt")

    response = client.get("/blobs")
    keys = sorted(entry["key"] for entry in response.get_json())
    assert keys == ["docs/b.txt"]


TRAVERSAL_KEYS = [
    "../secret.txt",
    "../../etc/passwd",
    "docs/../../secret.txt",
    "docs/../../../secret.txt",
    "a/b/../../../secret.txt",
    "..",
    "%2e%2e/secret.txt",
]


@pytest.mark.parametrize("key", TRAVERSAL_KEYS)
def test_put_blob_rejects_dotdot_traversal(tmp_path, key):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.put(f"/blobs/{key}", data=b"pwned")

    assert response.status_code == 400
    assert not (tmp_path.parent / "secret.txt").exists()


@pytest.mark.parametrize("key", TRAVERSAL_KEYS)
def test_get_blob_rejects_dotdot_traversal(tmp_path, key):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.get(f"/blobs/{key}")

    assert response.status_code == 400


@pytest.mark.parametrize("key", TRAVERSAL_KEYS)
def test_delete_blob_rejects_dotdot_traversal(tmp_path, key):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.delete(f"/blobs/{key}")

    assert response.status_code == 400


def test_resolve_blob_path_rejects_absolute_key(tmp_path):
    with pytest.raises(InvalidKeyError):
        resolve_blob_path(str(tmp_path), "/etc/passwd")


def test_resolve_blob_path_accepts_relative_key(tmp_path):
    path = resolve_blob_path(str(tmp_path), "docs/readme.txt")

    assert path == (tmp_path / "docs" / "readme.txt").resolve()


def test_get_blob_double_slash_key_never_leaks_outside_root(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    # A leading "/" right after /blobs/ can only reach the app via Werkzeug's
    # slash-merging redirect, which rewrites it to a key relative to root
    # before our view ever sees it -- confirm that stays true, i.e. it must
    # never resolve to a real /etc/passwd on the host.
    response = client.get("/blobs//etc/passwd", follow_redirects=True)

    assert response.status_code == 404


def test_put_blob_rejects_key_with_null_byte(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.put("/blobs/foo%00bar", data=b"x")

    assert response.status_code == 400


def test_put_blob_rejects_key_with_replacement_character(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.put("/blobs/��", data=b"x")

    assert response.status_code == 400


def test_traversal_key_does_not_escape_via_symlink(tmp_path):
    outside = tmp_path.parent / "outside-dir"
    outside.mkdir(exist_ok=True)
    (tmp_path / "escape").symlink_to(outside, target_is_directory=True)
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.put("/blobs/escape/secret.txt", data=b"pwned")

    assert response.status_code == 400
    assert not (outside / "secret.txt").exists()
    assert not (outside / "secret.txt").exists()


def test_legit_key_containing_dotdot_substring_is_allowed(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.put("/blobs/my..file.txt", data=b"content")

    assert response.status_code == 201
    assert (tmp_path / "my..file.txt").read_bytes() == b"content"
