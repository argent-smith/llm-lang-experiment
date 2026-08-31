import hashlib
import os
import re
import threading

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


# --- Atomic write / concurrent PUT (ticket 6) -------------------------------


def test_put_blob_leaves_no_temp_files_after_success(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    client.put("/blobs/docs/readme.txt", data=b"content")

    leftover = [p for p in tmp_path.rglob("*") if p.is_file() and p.name != "readme.txt"]
    assert leftover == []


def test_put_blob_removes_temp_file_on_write_failure(tmp_path, monkeypatch):
    app = create_app(str(tmp_path))
    client = app.test_client()

    def failing_replace(src, dst):
        raise OSError("simulated failure")

    monkeypatch.setattr(os, "replace", failing_replace)

    response = client.put("/blobs/key.txt", data=b"content")

    assert response.status_code == 500
    assert not (tmp_path / "key.txt").exists()
    leftover = [p for p in tmp_path.rglob("*") if p.is_file()]
    assert leftover == []


def test_get_during_in_progress_put_never_sees_partial_content(tmp_path, monkeypatch):
    app = create_app(str(tmp_path))
    client = app.test_client()
    old_content = b"OLD" * 10000
    client.put("/blobs/key.txt", data=old_content)

    reached_replace = threading.Event()
    release_replace = threading.Event()
    real_replace = os.replace

    def patched_replace(src, dst):
        reached_replace.set()
        assert release_replace.wait(timeout=5)
        real_replace(src, dst)

    monkeypatch.setattr(os, "replace", patched_replace)

    new_content = b"NEW" * 10000
    results = {}

    def do_put():
        results["response"] = client.put("/blobs/key.txt", data=new_content)

    put_thread = threading.Thread(target=do_put)
    put_thread.start()
    assert reached_replace.wait(timeout=5), "PUT never reached the rename step"

    # Rename hasn't happened yet -- a reader must see the fully old file,
    # never a truncated or partially-written one.
    mid_write = client.get("/blobs/key.txt")
    assert mid_write.status_code == 200
    assert mid_write.data == old_content

    release_replace.set()
    put_thread.join(timeout=5)

    assert results["response"].status_code == 201
    final = client.get("/blobs/key.txt")
    assert final.data == new_content


def test_concurrent_put_different_keys_do_not_interfere(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    barrier = threading.Barrier(2)
    results = {}
    content_a = b"A" * 50000
    content_b = b"B" * 50000

    def put_a():
        barrier.wait(timeout=5)
        results["a"] = client.put("/blobs/a.txt", data=content_a)

    def put_b():
        barrier.wait(timeout=5)
        results["b"] = client.put("/blobs/docs/b.txt", data=content_b)

    t1 = threading.Thread(target=put_a)
    t2 = threading.Thread(target=put_b)
    t1.start()
    t2.start()
    t1.join(timeout=5)
    t2.join(timeout=5)

    assert results["a"].status_code == 201
    assert results["b"].status_code == 201
    assert (tmp_path / "a.txt").read_bytes() == content_a
    assert (tmp_path / "docs" / "b.txt").read_bytes() == content_b


def test_list_blobs_excludes_temp_directory_contents(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    client.put("/blobs/keep.txt", data=b"kept")

    tmp_dir = tmp_path / ".syncbox-tmp"
    tmp_dir.mkdir(exist_ok=True)
    (tmp_dir / "leftover.tmp").write_bytes(b"leftover")

    response = client.get("/blobs")

    keys = [entry["key"] for entry in response.get_json()]
    assert keys == ["keep.txt"]


@pytest.mark.parametrize(
    "key", [".syncbox-tmp/x", "docs/.syncbox-tmp/y", ".syncbox-tmp"]
)
def test_reserved_tmp_segment_is_rejected_as_invalid_key(tmp_path, key):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.put(f"/blobs/{key}", data=b"x")

    assert response.status_code == 400
