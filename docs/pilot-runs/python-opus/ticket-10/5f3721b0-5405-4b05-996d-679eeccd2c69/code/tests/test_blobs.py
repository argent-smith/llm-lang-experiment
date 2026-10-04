"""PUT, GET and DELETE /blobs/{key} and GET /blobs, including garbage and edge-case keys.

Every response must be one the API contract lists for the operation:
GET /blobs -> 200; PUT /blobs/{key} -> 201 or 400; GET and DELETE
/blobs/{key} -> 200, 404 or 400.
"""

from __future__ import annotations

import hashlib
import http.client
import json
import os
import random
import re
import socket
import threading
from datetime import datetime, timedelta, timezone
from urllib.parse import quote, quote_from_bytes

import pytest

PUT_STATUSES = {201, 400}
GET_KEY_STATUSES = {200, 404, 400}
DELETE_KEY_STATUSES = {204, 404, 400}

ISO_UTC = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z")


def put(conn, key: str, body: bytes = b"", raw: bool = False):
    path = "/blobs/" + (key if raw else quote(key, safe="/"))
    conn.request("PUT", path, body=body, headers={"Content-Type": "application/octet-stream"})
    resp = conn.getresponse()
    return resp.status, json.loads(resp.read())


def get(conn, key: str, method: str = "GET"):
    conn.request(method, "/blobs/" + quote(key, safe="/"))
    resp = conn.getresponse()
    return resp, resp.read()


def delete(conn, key: str, raw: bool = False):
    conn.request("DELETE", "/blobs/" + (key if raw else quote(key, safe="/")))
    resp = conn.getresponse()
    return resp, resp.read()


def list_blobs(conn) -> list[dict]:
    conn.request("GET", "/blobs")
    resp = conn.getresponse()
    assert resp.status == 200
    assert resp.getheader("Content-Type") == "application/json"
    return json.loads(resp.read())


def raw_request(server, data: bytes) -> tuple[int, bytes]:
    """Send raw bytes on a fresh connection; return the status and the raw response."""
    with socket.create_connection(server.server_address[:2], timeout=5) as sock:
        sock.sendall(data)
        sock.shutdown(socket.SHUT_WR)
        chunks = []
        while chunk := sock.recv(65536):
            chunks.append(chunk)
    response = b"".join(chunks)
    return int(response.split(b" ", 2)[1]), response


def assert_nothing_escaped(tmp_path):
    """Only the store's own directories exist, and no upload is left behind."""
    assert {p.name for p in tmp_path.iterdir()} <= {"blobs", "tmp"}
    tmp_dir = tmp_path / "tmp"
    assert not tmp_dir.exists() or not any(tmp_dir.iterdir())


# --- GET /blobs -------------------------------------------------------------


def test_list_is_empty_initially(conn):
    assert list_blobs(conn) == []


def test_list_ignores_query_string_and_supports_head(conn):
    conn.request("GET", "/blobs?x=1")
    resp = conn.getresponse()
    assert resp.status == 200
    assert json.loads(resp.read()) == []

    conn.request("HEAD", "/blobs")
    resp = conn.getresponse()
    assert resp.status == 200
    assert resp.read() == b""


def test_list_reports_metadata(conn):
    put(conn, "b.txt", b"bee")
    put(conn, "docs/readme.txt", b"hello")
    put(conn, "a", b"")

    blobs = list_blobs(conn)
    assert [b["key"] for b in blobs] == ["a", "b.txt", "docs/readme.txt"]
    for blob in blobs:
        assert set(blob) == {"key", "size", "sha256", "modified_at"}
        assert ISO_UTC.fullmatch(blob["modified_at"])
    readme = blobs[2]
    assert readme["size"] == 5
    assert readme["sha256"] == hashlib.sha256(b"hello").hexdigest()
    assert blobs[0]["size"] == 0
    assert blobs[0]["sha256"] == hashlib.sha256(b"").hexdigest()


def test_list_includes_blobs_already_on_disk(conn, tmp_path):
    # Files the store holds are listed whether or not this process wrote them,
    # keyed by their path relative to the store root.
    contents = {"top.bin": b"\x00\x01", "docs/readme.txt": b"hi", "a/b/c/deep.txt": b"x" * 70000}
    for key, data in contents.items():
        path = tmp_path / "blobs" / key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    blobs = list_blobs(conn)
    assert [b["key"] for b in blobs] == sorted(contents)
    for blob in blobs:
        data = contents[blob["key"]]
        assert blob["size"] == len(data)
        assert blob["sha256"] == hashlib.sha256(data).hexdigest()


def test_list_reports_modification_time_in_utc(conn, tmp_path):
    put(conn, "docs/old.txt", b"old")
    # 2021-03-04T05:06:07.250000Z, set directly on the file.
    os.utime(tmp_path / "blobs" / "docs" / "old.txt", ns=(0, 1614834367_250000000))

    [blob] = list_blobs(conn)
    assert blob["modified_at"] == "2021-03-04T05:06:07.250000Z"


def test_list_modification_time_tracks_the_upload(conn):
    before = datetime.now(timezone.utc)
    put(conn, "fresh", b"data")
    after = datetime.now(timezone.utc)

    [blob] = list_blobs(conn)
    modified = datetime.fromisoformat(blob["modified_at"])
    assert modified.utcoffset() == timedelta(0)
    # Allow for filesystem timestamp granularity.
    assert before - timedelta(seconds=2) <= modified <= after + timedelta(seconds=2)


def test_list_reflects_overwrite(conn):
    put(conn, "k", b"first version")
    put(conn, "k", b"v2")

    [blob] = list_blobs(conn)
    assert (blob["key"], blob["size"]) == ("k", 2)
    assert blob["sha256"] == hashlib.sha256(b"v2").hexdigest()


def test_list_skips_files_put_could_not_have_created(conn, tmp_path):
    put(conn, "ok", b"1")
    root = tmp_path / "blobs"
    os.mkfifo(root / "fifo")
    (root / "link").symlink_to(root / "ok")
    (root / "bad\udcff").write_bytes(b"")  # name that is not valid UTF-8
    (root / "dir").mkdir()  # empty directories are not blobs
    (tmp_path / "tmp" / "upload-leftover").write_bytes(b"partial")

    assert [b["key"] for b in list_blobs(conn)] == ["ok"]


# --- PUT /blobs/{key} ---------------------------------------------------------


def test_put_returns_201_with_hash_and_size(conn):
    status, body = put(conn, "docs/readme.txt", b"hello")
    assert status == 201
    assert body == {
        "key": "docs/readme.txt",
        "sha256": hashlib.sha256(b"hello").hexdigest(),
        "size": 5,
    }


def test_put_without_body_or_content_length_stores_empty_blob(conn, tmp_path):
    # curl -X PUT -H 'Content-Type: application/octet-stream' .../blobs/0
    conn.putrequest("PUT", "/blobs/0")
    conn.putheader("Content-Type", "application/octet-stream")
    conn.endheaders()
    resp = conn.getresponse()
    assert resp.status == 201
    assert json.loads(resp.read()) == {
        "key": "0",
        "sha256": hashlib.sha256(b"").hexdigest(),
        "size": 0,
    }
    assert (tmp_path / "blobs" / "0").read_bytes() == b""


def test_put_overwrites_existing_blob(conn, tmp_path):
    put(conn, "k", b"old")
    status, body = put(conn, "k", b"newer")
    assert status == 201
    assert body["size"] == 5
    assert (tmp_path / "blobs" / "k").read_bytes() == b"newer"
    assert len(list_blobs(conn)) == 1


@pytest.mark.parametrize(
    "key",
    ["0", "-", "...", "..a", "a..", ".hidden", "a b", "a+b", "a?b", "a#b", "a%b", "a\\b",
     "привет/мир.txt", "\U0001f600", "a\nb", "x" * 255, "/".join(["d"] * 100)],
)
def test_put_accepts_unusual_but_valid_keys(conn, key):
    status, body = put(conn, key, b"data")
    assert status == 201, body
    assert body["key"] == key
    assert key in [b["key"] for b in list_blobs(conn)]


def test_put_decodes_percent_escapes_and_raw_utf8(server, conn):
    status, response = raw_request(
        server, "PUT /blobs/caf%C3%A9/naïve HTTP/1.1\r\nContent-Length: 0\r\n\r\n".encode()
    )
    assert status == 201, response
    assert [b["key"] for b in list_blobs(conn)] == ["café/naïve"]


INVALID_KEY_PATHS = [
    "/blobs/",  # empty key
    "/blobs/..",
    "/blobs/../x",
    "/blobs/a/../../x",
    "/blobs/a/..",
    "/blobs/%2e%2e/x",  # encoded traversal
    "/blobs/a%2F..%2F..%2Fx",
    "/blobs//etc/passwd",  # absolute
    "/blobs/%2Fetc/passwd",
    "/blobs/.",
    "/blobs/./a",
    "/blobs/a/./b",
    "/blobs/a//b",
    "/blobs/a/",
    "/blobs/a%00b",  # NUL
    "/blobs/%ff",  # invalid UTF-8
    "/blobs/%c3",  # truncated UTF-8
    "/blobs/%ed%a0%80",  # UTF-8-encoded surrogate
    "/blobs/" + "x" * 256,  # component longer than NAME_MAX
    "/blobs/" + "/".join(["d" * 200] * 30),  # path longer than PATH_MAX
]


@pytest.mark.parametrize("path", INVALID_KEY_PATHS)
def test_put_rejects_invalid_keys_with_400(conn, tmp_path, path):
    conn.request("PUT", path, body=b"data")
    resp = conn.getresponse()
    assert resp.status == 400
    assert "error" in json.loads(resp.read())
    assert list_blobs(conn) == []
    assert_nothing_escaped(tmp_path)


def test_put_rejects_overlong_request_line_with_400(server):
    # Exactly one byte over the stdlib's 64 KiB limit, so the server has read
    # everything sent and closing doesn't reset the connection.
    line = b"PUT /blobs/" + b"x" * 65526
    assert len(line) == 65537
    status, _ = raw_request(server, line)
    assert status == 400


@pytest.mark.parametrize("first, second", [("a", "a/b"), ("c/d", "c")])
def test_put_rejects_key_colliding_with_file_or_directory(conn, tmp_path, first, second):
    assert put(conn, first, b"1")[0] == 201
    status, body = put(conn, second, b"2")
    assert status == 400, body
    assert [b["key"] for b in list_blobs(conn)] == [first]
    assert_nothing_escaped(tmp_path)


def test_put_accepts_chunked_body(server, conn):
    status, response = raw_request(
        server,
        b"PUT /blobs/chunked HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        b"5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nX-Trailer: 1\r\n\r\n",
    )
    assert status == 201, response
    body = json.loads(response.split(b"\r\n\r\n", 1)[1])
    assert body["size"] == 11
    assert body["sha256"] == hashlib.sha256(b"hello world").hexdigest()


@pytest.mark.parametrize(
    "headers, body",
    [
        (b"Content-Length: abc\r\n", b""),
        (b"Content-Length: -1\r\n", b""),
        (b"Content-Length: 1\r\nContent-Length: 2\r\n", b"xx"),
        (b"Content-Length: 10\r\n", b"short"),
        (b"Transfer-Encoding: gzip\r\n", b""),
        (b"Transfer-Encoding: chunked\r\n", b"zz\r\nhello\r\n0\r\n\r\n"),
        (b"Transfer-Encoding: chunked\r\n", b"0x5\r\nhello\r\n0\r\n\r\n"),
        (b"Transfer-Encoding: chunked\r\n", b"5\r\nhelloXX0\r\n\r\n"),
        (b"Transfer-Encoding: chunked\r\n", b"5\r\nhel"),
    ],
)
def test_put_rejects_malformed_body_framing_with_400(server, conn, tmp_path, headers, body):
    status, _ = raw_request(server, b"PUT /blobs/k HTTP/1.1\r\n" + headers + b"\r\n" + body)
    assert status == 400
    assert list_blobs(conn) == []
    assert_nothing_escaped(tmp_path)


def test_keep_alive_after_put(conn):
    for i in range(5):
        assert put(conn, f"k{i}", b"x" * i)[0] == 201
    status, _ = put(conn, "..", b"y" * 1000)  # rejected body is drained
    assert status == 400
    assert len(list_blobs(conn)) == 5


# --- GET /blobs/{key} ---------------------------------------------------------


def test_get_returns_stored_bytes(conn, tmp_path):
    content = bytes(range(256)) * 3
    put(conn, "docs/readme.txt", content)
    assert (tmp_path / "blobs" / "docs" / "readme.txt").read_bytes() == content

    resp, body = get(conn, "docs/readme.txt")
    assert resp.status == 200
    assert resp.getheader("Content-Type") == "application/octet-stream"
    assert int(resp.getheader("Content-Length")) == len(content)
    assert body == content


def test_get_large_blob(conn):
    content = random.Random(0).randbytes(3 * 1024 * 1024 + 17)
    status, result = put(conn, "big.bin", content)
    assert status == 201
    assert result["sha256"] == hashlib.sha256(content).hexdigest()

    resp, body = get(conn, "big.bin")
    assert resp.status == 200
    assert body == content


def test_get_empty_blob(conn):
    put(conn, "empty", b"")
    resp, body = get(conn, "empty")
    assert resp.status == 200
    assert resp.getheader("Content-Length") == "0"
    assert body == b""


def test_get_after_overwrite_returns_new_content(conn):
    put(conn, "k", b"old contents")
    put(conn, "k", b"new")
    resp, body = get(conn, "k")
    assert resp.status == 200
    assert body == b"new"


def test_put_creates_nested_directories(conn, tmp_path):
    put(conn, "a/b/c/d.txt", b"deep")
    put(conn, "a/b/e.txt", b"sibling")
    assert (tmp_path / "blobs" / "a" / "b" / "c" / "d.txt").read_bytes() == b"deep"
    assert get(conn, "a/b/c/d.txt")[1] == b"deep"
    assert get(conn, "a/b/e.txt")[1] == b"sibling"


@pytest.mark.parametrize("key", ["missing", "no/such/dir/file", "docs", "docs/readme.txt/x"])
def test_get_missing_blob_returns_404(conn, key):
    # "docs" is a directory and "docs/readme.txt/x" runs through a file:
    # neither is a blob.
    put(conn, "docs/readme.txt", b"hello")
    resp, body = get(conn, key)
    assert resp.status == 404
    assert resp.getheader("Content-Type") == "application/json"
    assert "error" in json.loads(body)


def test_get_does_not_serve_non_regular_files(conn, tmp_path):
    put(conn, "ok", b"1")
    root = tmp_path / "blobs"
    os.mkfifo(root / "fifo")
    (root / "link").symlink_to(root / "ok")
    for key in ("fifo", "link"):
        resp, _ = get(conn, key)
        assert resp.status == 404, key


def test_head_blob_has_headers_but_no_body(conn):
    put(conn, "k", b"12345")
    resp, body = get(conn, "k", method="HEAD")
    assert resp.status == 200
    assert resp.getheader("Content-Length") == "5"
    assert body == b""

    resp, body = get(conn, "missing", method="HEAD")
    assert resp.status == 404
    assert body == b""


@pytest.mark.parametrize(
    "key",
    ["0", "...", ".hidden", "a b", "a+b", "a?b", "a#b", "a%b", "a\\b",
     "привет/мир.txt", "\U0001f600", "x" * 255],
)
def test_get_round_trips_unusual_keys(conn, key):
    content = f"content of {key}".encode()
    assert put(conn, key, content)[0] == 201
    resp, body = get(conn, key)
    assert resp.status == 200
    assert body == content


def test_get_decodes_percent_escapes_and_raw_utf8(server, conn):
    put(conn, "café/naïve", b"accent")
    status, response = raw_request(server, "GET /blobs/caf%C3%A9/naïve HTTP/1.1\r\n\r\n".encode())
    assert status == 200, response
    assert response.endswith(b"\r\n\r\naccent")


def test_get_ignores_query_string(conn):
    put(conn, "k", b"v")
    conn.request("GET", "/blobs/k?version=1")
    resp = conn.getresponse()
    assert resp.status == 200
    assert resp.read() == b"v"


def test_keep_alive_across_puts_and_gets(conn):
    for i in range(10):
        assert put(conn, f"k{i}", b"x" * i)[0] == 201
        resp, body = get(conn, f"k{i}")
        assert resp.status == 200
        assert body == b"x" * i
        assert not resp.will_close
    resp, _ = get(conn, "missing")
    assert resp.status == 404
    assert not resp.will_close
    assert get(conn, "k3")[1] == b"xxx"


# --- DELETE /blobs/{key} ------------------------------------------------------


def test_delete_returns_204_without_body(conn, tmp_path):
    put(conn, "docs/readme.txt", b"hello")
    resp, body = delete(conn, "docs/readme.txt")
    assert resp.status == 204
    assert body == b""
    # RFC 9110: a 204 response carries no Content-Length.
    assert resp.getheader("Content-Length") is None
    assert not (tmp_path / "blobs" / "docs" / "readme.txt").exists()


def test_deleted_blob_is_gone_from_get_and_list(conn):
    put(conn, "docs/readme.txt", b"hello")
    put(conn, "other", b"stays")
    assert delete(conn, "docs/readme.txt")[0].status == 204

    resp, body = get(conn, "docs/readme.txt")
    assert resp.status == 404
    assert "error" in json.loads(body)
    assert [b["key"] for b in list_blobs(conn)] == ["other"]
    assert get(conn, "other")[1] == b"stays"


@pytest.mark.parametrize("key", ["missing", "no/such/dir/file", "docs", "docs/readme.txt/x"])
def test_delete_missing_blob_returns_404(conn, key):
    # "docs" is a directory and "docs/readme.txt/x" runs through a file:
    # neither is a blob, and neither request may disturb the real one.
    put(conn, "docs/readme.txt", b"hello")
    resp, body = delete(conn, key)
    assert resp.status == 404
    assert resp.getheader("Content-Type") == "application/json"
    assert "error" in json.loads(body)
    assert [b["key"] for b in list_blobs(conn)] == ["docs/readme.txt"]


def test_delete_twice_returns_404_the_second_time(conn):
    put(conn, "k", b"v")
    assert delete(conn, "k")[0].status == 204
    assert delete(conn, "k")[0].status == 404


def test_delete_then_put_again(conn):
    put(conn, "k", b"first")
    delete(conn, "k")
    status, body = put(conn, "k", b"second")
    assert status == 201
    assert get(conn, "k")[1] == b"second"
    assert [(b["key"], b["size"]) for b in list_blobs(conn)] == [("k", 6)]


def test_delete_removes_directories_left_empty(conn, tmp_path):
    put(conn, "a/b/c/deep.txt", b"deep")
    put(conn, "a/sibling.txt", b"sibling")
    assert delete(conn, "a/b/c/deep.txt")[0].status == 204
    # "a/b/c" and "a/b" held only the deleted blob; "a" still holds one.
    assert sorted(p.name for p in (tmp_path / "blobs" / "a").iterdir()) == ["sibling.txt"]

    assert delete(conn, "a/sibling.txt")[0].status == 204
    assert list((tmp_path / "blobs").iterdir()) == []
    assert list_blobs(conn) == []


def test_delete_frees_the_key_of_a_former_directory(conn):
    # Once "a/b" is gone, "a" is no longer a directory, so it can be a blob.
    put(conn, "a/b", b"nested")
    assert put(conn, "a", b"x")[0] == 400
    delete(conn, "a/b")
    assert put(conn, "a", b"top")[0] == 201
    assert get(conn, "a")[1] == b"top"


def test_delete_does_not_remove_non_regular_files(conn, tmp_path):
    put(conn, "ok", b"1")
    root = tmp_path / "blobs"
    os.mkfifo(root / "fifo")
    (root / "link").symlink_to(root / "ok")
    for key in ("fifo", "link"):
        resp, _ = delete(conn, key)
        assert resp.status == 404, key
    assert (root / "fifo").exists()
    assert (root / "link").is_symlink()
    assert get(conn, "ok")[1] == b"1"


def test_delete_blob_already_on_disk(conn, tmp_path):
    path = tmp_path / "blobs" / "docs" / "external.txt"
    path.parent.mkdir(parents=True)
    path.write_bytes(b"written outside the server")
    assert delete(conn, "docs/external.txt")[0].status == 204
    assert not path.exists()
    assert list_blobs(conn) == []


@pytest.mark.parametrize(
    "key",
    ["0", "...", ".hidden", "a b", "a+b", "a?b", "a#b", "a%b", "a\\b",
     "привет/мир.txt", "\U0001f600", "x" * 255],
)
def test_delete_unusual_keys(conn, key):
    assert put(conn, key, b"data")[0] == 201
    assert delete(conn, key)[0].status == 204
    assert get(conn, key)[0].status == 404
    assert list_blobs(conn) == []


def test_delete_decodes_percent_escapes_and_raw_utf8(server, conn):
    put(conn, "café/naïve", b"accent")
    status, response = raw_request(
        server, "DELETE /blobs/caf%C3%A9/naïve HTTP/1.1\r\n\r\n".encode()
    )
    assert status == 204, response
    assert list_blobs(conn) == []


def test_delete_ignores_query_string(conn):
    put(conn, "k", b"v")
    conn.request("DELETE", "/blobs/k?version=1")
    resp = conn.getresponse()
    resp.read()
    assert resp.status == 204
    assert list_blobs(conn) == []


@pytest.mark.parametrize("path", INVALID_KEY_PATHS)
def test_delete_rejects_invalid_keys_with_400(conn, tmp_path, path):
    put(conn, "a/b", b"keep")
    conn.request("DELETE", path)
    resp = conn.getresponse()
    assert resp.status == 400
    assert "error" in json.loads(resp.read())
    assert [b["key"] for b in list_blobs(conn)] == ["a/b"]
    assert_nothing_escaped(tmp_path)


def test_delete_cannot_reach_outside_the_store(conn, tmp_path):
    # Files beside the store must survive traversal attempts.
    victim = tmp_path / "victim.txt"
    victim.write_bytes(b"precious")
    put(conn, "x", b"1")
    for path in ("/blobs/../victim.txt", "/blobs/%2e%2e/victim.txt",
                 "/blobs/x/../../victim.txt", "/blobs/" + quote(str(victim))):
        conn.request("DELETE", path)
        resp = conn.getresponse()
        resp.read()
        assert resp.status in {400, 404}, path
    assert victim.read_bytes() == b"precious"


def test_keep_alive_across_deletes(conn):
    for i in range(5):
        put(conn, f"k{i}", b"x")
    for i in range(5):
        resp, _ = delete(conn, f"k{i}")
        assert resp.status == 204
        assert not resp.will_close
    resp, _ = delete(conn, "k0")
    assert resp.status == 404
    assert not resp.will_close
    # A body sent with DELETE is drained rather than parsed as the next request.
    put(conn, "k", b"x")
    conn.request("DELETE", "/blobs/k", body=b"GET /nope HTTP/1.1\r\n\r\n" * 10)
    resp = conn.getresponse()
    resp.read()
    assert resp.status == 204
    assert not resp.will_close
    assert list_blobs(conn) == []


def test_concurrent_put_and_delete_in_one_directory(server, tmp_path):
    # Deleting the last blob of "d/" removes the directory; a put into "d/"
    # running at the same time must still succeed, not trip over the removal.
    host, port = server.server_address[:2]
    errors: list[str] = []

    def churn(key: str) -> None:
        connection = http.client.HTTPConnection(host, port, timeout=10)
        try:
            for i in range(200):
                status, body = put(connection, key, str(i).encode())
                if status != 201:
                    errors.append(f"PUT {key}: {status} {body}")
                resp, _ = delete(connection, key)
                if resp.status != 204:
                    errors.append(f"DELETE {key}: {resp.status}")
        except Exception as exc:  # e.g. the server dropped the connection
            errors.append(f"{key}: {exc!r}")
        finally:
            connection.close()

    threads = [threading.Thread(target=churn, args=(key,)) for key in ("d/a", "d/b", "d/e/c")]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert errors == []
    assert list((tmp_path / "blobs").iterdir()) == []
    assert_nothing_escaped(tmp_path)


# --- responses stay within the contract for any key -------------------------


def test_get_and_delete_blob_stay_within_contract(conn):
    put(conn, "k", b"x")
    for method, allowed in (("GET", GET_KEY_STATUSES), ("DELETE", DELETE_KEY_STATUSES)):
        for path in ("/blobs/k", "/blobs/missing", "/blobs/../x", "/blobs/%ff"):
            conn.request(method, path)
            resp = conn.getresponse()
            resp.read()
            assert resp.status in allowed, (method, path)


_FUZZ_ALPHABET = [b"a", b"Z", b"0", b"/", b".", b"..", b"%", b"%2", b"%2e", b"%2F", b"%00",
                  b"\\", b"~", b"-", b"\xff", b"\xc3", b"\xa9", b"\xed\xa0\x80", b"\x01",
                  "й".encode(), "\U0001f600".encode()]


@pytest.mark.parametrize("seed", range(4))
def test_fuzzed_keys_get_contract_responses(server, conn, tmp_path, seed):
    rng = random.Random(seed)
    for _ in range(150):
        raw_key = b"".join(rng.choice(_FUZZ_ALPHABET) for _ in range(rng.randint(0, 12)))
        if rng.random() < 0.3:
            raw_key = b"x" * rng.choice([254, 255, 256, 4096]) + raw_key
        # Percent-encode everything (http.client rejects control bytes), but
        # keep "/" and "%" literal half the time so separators and escapes
        # embedded in the key are exercised too.
        safe = "/%" if rng.random() < 0.5 else ""
        path = "/blobs/" + quote_from_bytes(raw_key, safe=safe)
        # A fresh connection per request keeps the loop fast.
        conn.request("PUT", path, body=b"payload", headers={"Connection": "close"})
        resp = conn.getresponse()
        resp.read()
        assert resp.status in PUT_STATUSES, path
        put_status = resp.status

        conn.request("GET", path, headers={"Connection": "close"})
        resp = conn.getresponse()
        body = resp.read()
        assert resp.status in GET_KEY_STATUSES, path
        if put_status == 201:
            assert (resp.status, body) == (200, b"payload"), path

        if rng.random() < 0.5:
            conn.request("DELETE", path, headers={"Connection": "close"})
            resp = conn.getresponse()
            resp.read()
            assert resp.status in DELETE_KEY_STATUSES, path
            if put_status == 201:
                assert resp.status == 204, path
                conn.request("GET", path, headers={"Connection": "close"})
                resp = conn.getresponse()
                resp.read()
                assert resp.status == 404, path

    blobs = list_blobs(conn)
    for blob in blobs:
        assert blob["key"].encode("utf-8")  # valid Unicode, no lone surrogates
    assert_nothing_escaped(tmp_path)


def test_raw_request_line_bytes_get_contract_responses(server, conn, tmp_path):
    # Bytes that don't break the request line itself (no whitespace / CR / LF).
    rng = random.Random(1)
    alphabet = [bytes([b]) for b in range(0x21, 0x100) if not chr(b).isspace()]
    for _ in range(100):
        raw_key = b"".join(rng.choice(alphabet) for _ in range(rng.randint(1, 16)))
        status, response = raw_request(
            server, b"PUT /blobs/" + raw_key + b" HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
        )
        assert status in PUT_STATUSES, (raw_key, response)
        status, response = raw_request(server, b"GET /blobs/" + raw_key + b" HTTP/1.1\r\n\r\n")
        assert status in GET_KEY_STATUSES, (raw_key, response)
        status, response = raw_request(server, b"DELETE /blobs/" + raw_key + b" HTTP/1.1\r\n\r\n")
        assert status in DELETE_KEY_STATUSES, (raw_key, response)
    list_blobs(conn)
    assert_nothing_escaped(tmp_path)
