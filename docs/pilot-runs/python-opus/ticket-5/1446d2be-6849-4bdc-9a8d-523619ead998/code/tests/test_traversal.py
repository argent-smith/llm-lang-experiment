"""Directory traversal through the key of PUT, GET and DELETE /blobs/{key}.

A key must never reach a file outside the store: neither through "..",
absolute paths or bad encodings in the key itself (rejected before the
filesystem is touched), nor through symlinks found inside the store
(rejected once the key's path is resolved).
"""

from __future__ import annotations

import json
import os
from urllib.parse import quote

import pytest

from syncbox.server.storage import BlobStore, InvalidKey

from .test_blobs import (
    INVALID_KEY_PATHS,
    delete,
    get,
    list_blobs,
    put,
    raw_request,
)

METHODS = ("PUT", "GET", "DELETE")

TRAVERSAL_PATHS = [
    "/blobs/../victim.txt",
    "/blobs/a/../../victim.txt",
    "/blobs/%2e%2e/victim.txt",
    "/blobs/%2E%2E%2Fvictim.txt",
    "/blobs/a%2F..%2F..%2Fvictim.txt",
    "/blobs/.%2e/victim.txt",
    "/blobs/..%2fblobs%2f..%2fvictim.txt",
]


def assert_nothing_escaped_beside_victim(tmp_path):
    """Like assert_nothing_escaped, but the data dir may also hold victim.txt."""
    assert {p.name for p in tmp_path.iterdir()} <= {"blobs", "tmp", "victim.txt"}
    tmp_dir = tmp_path / "tmp"
    assert not tmp_dir.exists() or not any(tmp_dir.iterdir())


def request(conn, method: str, path: str, body: bytes = b"data"):
    conn.request(method, path, body=body if method == "PUT" else None)
    resp = conn.getresponse()
    return resp, resp.read()


@pytest.fixture
def victim(tmp_path):
    """A file beside the store (in the data dir) and one outside the data dir."""
    inside = tmp_path / "victim.txt"
    inside.write_bytes(b"precious")
    outside = tmp_path.parent / f"{tmp_path.name}-outside"
    outside.mkdir()
    (outside / "secret").write_bytes(b"secret")
    yield outside
    assert inside.read_bytes() == b"precious"
    assert sorted(p.name for p in outside.iterdir()) == ["secret"]
    assert (outside / "secret").read_bytes() == b"secret"


# --- keys rejected by their text --------------------------------------------


@pytest.mark.parametrize("path", INVALID_KEY_PATHS)
def test_get_rejects_invalid_keys_with_400(conn, tmp_path, path):
    put(conn, "a/b", b"keep")
    resp, body = request(conn, "GET", path)
    assert resp.status == 400
    assert "error" in json.loads(body)
    assert_nothing_escaped_beside_victim(tmp_path)


@pytest.mark.parametrize("method", METHODS)
@pytest.mark.parametrize("path", TRAVERSAL_PATHS)
def test_traversal_is_rejected_with_400(conn, tmp_path, victim, method, path):
    put(conn, "a/b", b"keep")
    resp, body = request(conn, method, path)
    assert resp.status == 400, body
    assert "error" in json.loads(body)
    assert [b["key"] for b in list_blobs(conn)] == ["a/b"]
    assert_nothing_escaped_beside_victim(tmp_path)


@pytest.mark.parametrize("method", METHODS)
def test_absolute_key_is_rejected_with_400(conn, tmp_path, victim, method):
    for path in ("/blobs//" + quote(str(victim / "secret")).lstrip("/"),
                 "/blobs/" + quote(str(victim / "secret"), safe=""),
                 "/blobs/%2Fetc%2Fpasswd"):
        resp, body = request(conn, method, path)
        assert resp.status == 400, (path, body)
    assert list_blobs(conn) == []
    assert_nothing_escaped_beside_victim(tmp_path)


@pytest.mark.parametrize("method", METHODS)
def test_raw_traversal_in_request_line_is_rejected_with_400(server, conn, tmp_path, victim, method):
    # Sent verbatim, without any client-side normalisation of the path.
    for target in (b"/blobs/../victim.txt", b"/blobs/a/../../victim.txt",
                   b"/blobs/..\\victim.txt/../../victim.txt", b"/blobs/\xed\xa0\x80/../x",
                   b"/blobs/%c0%ae%c0%ae/victim.txt"):  # overlong UTF-8 for ".."
        status, response = raw_request(
            server, b"%s %s HTTP/1.1\r\nContent-Length: 4\r\n\r\ndata" % (method.encode(), target)
        )
        assert status == 400, (target, response)
    assert list_blobs(conn) == []
    assert_nothing_escaped_beside_victim(tmp_path)


@pytest.mark.parametrize("method", METHODS)
def test_unrepresentable_keys_are_rejected_with_400(conn, tmp_path, method):
    for path in ("/blobs/%ff", "/blobs/a/%c3", "/blobs/%ed%b0%80",  # lone surrogate
                 "/blobs/%ed%a0%bd%ed%b8%80",  # surrogate pair, CESU-8 style
                 "/blobs/a%00b", "/blobs/" + "x" * 256,
                 "/blobs/" + "/".join(["d" * 200] * 30)):
        resp, body = request(conn, method, path)
        assert resp.status == 400, (path, body)
        assert "error" in json.loads(body)
    assert list_blobs(conn) == []
    assert_nothing_escaped_beside_victim(tmp_path)


# --- keys rejected once their path is resolved ------------------------------


def test_symlinked_directory_cannot_lead_out_of_the_store(conn, tmp_path, victim):
    put(conn, "ok", b"1")
    (tmp_path / "blobs" / "out").symlink_to(victim, target_is_directory=True)

    status, body = put(conn, "out/new", b"evil")
    assert status == 400, body
    status, body = put(conn, "out/secret", b"evil")
    assert status == 400, body
    status, body = put(conn, "out/sub/new", b"evil")
    assert status == 400, body

    resp, body = get(conn, "out/secret")
    assert resp.status == 400, body
    assert b"secret" not in body
    resp, _ = delete(conn, "out/secret")
    assert resp.status == 400

    # The store keeps working; the symlink is not listed as a blob.
    assert [b["key"] for b in list_blobs(conn)] == ["ok"]
    assert get(conn, "ok")[1] == b"1"


def test_symlink_chain_cannot_lead_out_of_the_store(conn, tmp_path, victim):
    root = tmp_path / "blobs"
    root.mkdir()
    (root / "hop").symlink_to("..")  # relative: blobs/hop -> data dir
    (root / "a").mkdir()
    (root / "a" / "up").symlink_to("../../..", target_is_directory=True)

    for key in ("hop/victim.txt", "hop/blobs/hop/victim.txt", f"a/up/{victim.name}/secret"):
        assert put(conn, key, b"evil")[0] == 400, key
        assert get(conn, key)[0].status == 400, key
        assert delete(conn, key)[0].status == 400, key
    assert list_blobs(conn) == []


def test_symlinked_file_pointing_outside_is_not_served(conn, tmp_path, victim):
    root = tmp_path / "blobs"
    root.mkdir()
    (root / "leak").symlink_to(victim / "secret")
    resp, body = get(conn, "leak")
    assert resp.status in {400, 404}
    assert b"secret" not in body
    assert delete(conn, "leak")[0].status in {400, 404}
    assert (root / "leak").is_symlink()


def test_symlink_staying_inside_the_store_is_allowed(conn, tmp_path):
    root = tmp_path / "blobs"
    (root / "real").mkdir(parents=True)
    (root / "alias").symlink_to("real", target_is_directory=True)
    assert put(conn, "alias/x", b"inside")[0] == 201
    assert (root / "real" / "x").read_bytes() == b"inside"
    assert get(conn, "alias/x")[1] == b"inside"


def test_data_dir_given_through_a_symlink(server_factory, tmp_path):
    real = tmp_path / "real"
    real.mkdir()
    (tmp_path / "link").symlink_to(real, target_is_directory=True)
    conn = server_factory(tmp_path / "link")
    assert put(conn, "docs/readme.txt", b"hello")[0] == 201
    assert get(conn, "docs/readme.txt")[1] == b"hello"
    assert (real / "blobs" / "docs" / "readme.txt").read_bytes() == b"hello"
    assert delete(conn, "docs/readme.txt")[0].status == 204


# --- the store checks keys on its own ---------------------------------------


@pytest.mark.parametrize("key", ["", ".", "..", "../x", "a/../../x", "a/..", "./..", "a/b/../../.."])
def test_store_rejects_keys_resolving_outside_its_root(tmp_path, key):
    # Even a key that bypassed validate_key can't leave the store.
    (tmp_path / "victim.txt").write_bytes(b"precious")
    store = BlobStore(tmp_path)
    with pytest.raises(InvalidKey):
        store.put(key, [b"evil"])
    with pytest.raises(InvalidKey):
        store.open(key)
    with pytest.raises(InvalidKey):
        store.delete(key)
    assert (tmp_path / "victim.txt").read_bytes() == b"precious"
    assert_nothing_escaped_beside_victim(tmp_path)


def test_store_rejects_keys_that_are_not_file_names(tmp_path):
    store = BlobStore(tmp_path)
    for key in ("\ud800", "a\0b"):  # lone surrogate, NUL
        for call in (lambda: store.put(key, [b"x"]), lambda: store.open(key),
                     lambda: store.delete(key)):
            with pytest.raises(InvalidKey):
                call()
    assert_nothing_escaped_beside_victim(tmp_path)


def test_store_resolves_its_root(tmp_path):
    (tmp_path / "real").mkdir()
    (tmp_path / "link").symlink_to("real", target_is_directory=True)
    store = BlobStore(tmp_path / "link")
    assert store.root == tmp_path.resolve() / "real" / "blobs"
    assert store.put("k", [b"v"]).size == 1
    assert os.path.isfile(tmp_path / "real" / "blobs" / "k")
