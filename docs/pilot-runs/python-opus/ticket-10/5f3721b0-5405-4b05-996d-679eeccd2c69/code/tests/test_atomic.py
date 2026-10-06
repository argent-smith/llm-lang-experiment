"""Atomic blob writes: readers never see a partial blob, uploads never leak temp files.

A PUT writes the body to a temporary file in ``tmp/`` and renames it over
the blob only once the body is complete, so the old blob stays in place
until then and a failed upload leaves it untouched.
"""

from __future__ import annotations

import errno
import hashlib
import http.client
import os
import socket
import threading
import time
from contextlib import contextmanager
from pathlib import Path

import pytest

from syncbox.server import storage
from syncbox.server.app import SyncboxServer
from syncbox.server.config import ServerConfig
from syncbox.server.storage import BlobStore, StoreError

from .test_blobs import assert_nothing_escaped, get, list_blobs, put

OLD = b"old" * 100_000
NEW = b"new" * 100_000


def wait_until(condition, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while not condition():
        if time.monotonic() > deadline:
            pytest.fail("condition not met in time")
        time.sleep(0.01)


def uploads_in_progress(tmp_path: Path) -> list[Path]:
    return list((tmp_path / "tmp").iterdir())


@contextmanager
def stalled_put(server, tmp_path: Path, key: str, sent: bytes, declared: int):
    """A PUT of ``key`` that has sent ``sent`` of ``declared`` body bytes and waits.

    Yields the socket once the server has written the bytes it got into a
    temporary file.
    """
    with socket.create_connection(server.server_address[:2], timeout=5) as sock:
        sock.sendall(
            f"PUT /blobs/{key} HTTP/1.1\r\nHost: test\r\nContent-Length: {declared}\r\n\r\n".encode()
            + sent
        )
        wait_until(lambda: any(p.stat().st_size > 0 for p in uploads_in_progress(tmp_path)))
        yield sock


def test_readers_see_old_blob_until_upload_completes(server, conn, tmp_path):
    put(conn, "docs/k", OLD)
    with stalled_put(server, tmp_path, "docs/k", NEW[: len(NEW) // 2], len(NEW)) as sock:
        # The partial upload sits in tmp/, outside the store.
        assert len(uploads_in_progress(tmp_path)) == 1
        assert [p.name for p in (tmp_path / "blobs" / "docs").iterdir()] == ["k"]
        resp, body = get(conn, "docs/k")
        assert (resp.status, body) == (200, OLD)
        assert [(b["key"], b["size"], b["sha256"]) for b in list_blobs(conn)] == [
            ("docs/k", len(OLD), hashlib.sha256(OLD).hexdigest()),
        ]

        sock.sendall(NEW[len(NEW) // 2:])
        response = sock.recv(65536)
        assert response.startswith(b"HTTP/1.1 201 ")

    resp, body = get(conn, "docs/k")
    assert (resp.status, body) == (200, NEW)
    assert_nothing_escaped(tmp_path)


def test_new_blob_is_absent_until_upload_completes(server, conn, tmp_path):
    with stalled_put(server, tmp_path, "fresh", NEW[:70_000], len(NEW)):
        resp, _ = get(conn, "fresh")
        assert resp.status == 404
        assert list_blobs(conn) == []


def test_upload_in_progress_is_not_reachable_by_key(server, conn, tmp_path):
    with stalled_put(server, tmp_path, "k", NEW[:70_000], len(NEW)):
        [upload] = uploads_in_progress(tmp_path)
        for key in (f"tmp/{upload.name}", upload.name):
            resp, _ = get(conn, key)
            assert resp.status == 404, key
        conn.request("GET", f"/blobs/../tmp/{upload.name}")
        resp = conn.getresponse()
        resp.read()
        assert resp.status == 400
        assert list_blobs(conn) == []


def test_aborted_upload_keeps_old_blob_and_leaves_no_temp_file(server, conn, tmp_path):
    put(conn, "k", OLD)
    with stalled_put(server, tmp_path, "k", NEW[:70_000], len(NEW)):
        pass  # the client goes away mid-body
    wait_until(lambda: not uploads_in_progress(tmp_path))

    resp, body = get(conn, "k")
    assert (resp.status, body) == (200, OLD)
    assert [b["key"] for b in list_blobs(conn)] == ["k"]
    assert_nothing_escaped(tmp_path)


def test_malformed_upload_keeps_old_blob_and_leaves_no_temp_file(server, conn, tmp_path):
    put(conn, "k", OLD)
    with socket.create_connection(server.server_address[:2], timeout=5) as sock:
        sock.sendall(
            b"PUT /blobs/k HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n"
            b"5\r\nhello\r\nnot-hex\r\n"
        )
        assert sock.recv(65536).startswith(b"HTTP/1.1 400 ")

    resp, body = get(conn, "k")
    assert (resp.status, body) == (200, OLD)
    assert_nothing_escaped(tmp_path)


def test_concurrent_puts_of_one_key_never_expose_a_partial_blob(server, conn, tmp_path):
    host, port = server.server_address[:2]
    # Distinct, large enough to take many writes each.
    payloads = [bytes([i]) * 300_000 + bytes([i + 100]) * 300_000 for i in range(6)]
    put(conn, "shared/key", payloads[0])
    errors: list[str] = []
    writing = threading.Event()
    writing.set()

    def writer(data: bytes) -> None:
        connection = http.client.HTTPConnection(host, port, timeout=30)
        try:
            for _ in range(5):
                status, body = put(connection, "shared/key", data)
                if status != 201 or body["sha256"] != hashlib.sha256(data).hexdigest():
                    errors.append(f"PUT: {status} {body}")
        except Exception as exc:
            errors.append(f"PUT: {exc!r}")
        finally:
            connection.close()

    def reader() -> None:
        connection = http.client.HTTPConnection(host, port, timeout=30)
        reads = 0
        try:
            # Keep reading while writers run, and at least a few times.
            while writing.is_set() or reads < 3:
                resp, body = get(connection, "shared/key")
                reads += 1
                if resp.status != 200 or body not in payloads:
                    errors.append(f"GET: {resp.status}, {len(body)} bytes, not a whole payload")
                for blob in list_blobs(connection):
                    if blob["sha256"] not in {hashlib.sha256(p).hexdigest() for p in payloads}:
                        errors.append(f"GET /blobs: unexpected {blob}")
        except Exception as exc:
            errors.append(f"GET: {exc!r}")
        finally:
            connection.close()

    writers = [threading.Thread(target=writer, args=(data,)) for data in payloads]
    readers = [threading.Thread(target=reader) for _ in range(3)]
    for thread in readers + writers:
        thread.start()
    for thread in writers:
        thread.join()
    writing.clear()
    for thread in readers:
        thread.join()

    assert errors == []
    resp, body = get(conn, "shared/key")
    assert body in payloads
    assert [(b["key"], b["sha256"]) for b in list_blobs(conn)] == [
        ("shared/key", hashlib.sha256(body).hexdigest()),
    ]
    assert_nothing_escaped(tmp_path)


def test_concurrent_puts_of_different_keys_do_not_interfere(server, conn, tmp_path):
    host, port = server.server_address[:2]
    keys = [f"dir{i % 3}/sub{i % 2}/file{i}" for i in range(12)] + [f"top{i}" for i in range(4)]
    contents = {key: key.encode() * 20_000 for key in keys}
    errors: list[str] = []
    start = threading.Barrier(len(keys))

    def writer(key: str) -> None:
        connection = http.client.HTTPConnection(host, port, timeout=30)
        try:
            start.wait()
            for _ in range(3):
                status, body = put(connection, key, contents[key])
                if status != 201 or body["size"] != len(contents[key]):
                    errors.append(f"PUT {key}: {status} {body}")
        except Exception as exc:
            errors.append(f"PUT {key}: {exc!r}")
        finally:
            connection.close()

    threads = [threading.Thread(target=writer, args=(key,)) for key in keys]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert errors == []
    for key, data in contents.items():
        resp, body = get(conn, key)
        assert (resp.status, body) == (200, data), key
    assert [(b["key"], b["sha256"]) for b in list_blobs(conn)] == sorted(
        (key, hashlib.sha256(data).hexdigest()) for key, data in contents.items()
    )
    assert_nothing_escaped(tmp_path)


# --- BlobStore ---------------------------------------------------------------


def test_store_failure_mid_write_keeps_old_blob_and_leaves_no_temp_file(tmp_path):
    store = BlobStore(tmp_path)
    store.put("k", [OLD])

    def failing_body():
        yield NEW[:1000]
        assert len(os.listdir(store.tmp_dir)) == 1  # being written in tmp/
        raise ConnectionResetError

    with pytest.raises(ConnectionResetError):
        store.put("k", failing_body())
    assert (tmp_path / "blobs" / "k").read_bytes() == OLD
    assert_nothing_escaped(tmp_path)


def test_store_failure_to_rename_leaves_no_temp_file(tmp_path, monkeypatch):
    store = BlobStore(tmp_path)

    def failing_replace(src, dst):
        raise OSError(errno.EIO, "I/O error")

    monkeypatch.setattr(storage.os, "replace", failing_replace)
    with pytest.raises(OSError):
        store.put("k", [NEW])
    assert list(store.root.iterdir()) == []
    assert_nothing_escaped(tmp_path)


def test_store_removes_leftover_uploads_on_start(tmp_path):
    (tmp_path / "tmp").mkdir()
    (tmp_path / "tmp" / "upload-crashed").write_bytes(b"partial")
    (tmp_path / "blobs").mkdir()
    (tmp_path / "blobs" / "kept").write_bytes(b"blob")

    store = BlobStore(tmp_path)
    assert uploads_in_progress(tmp_path) == []
    assert [meta.key for meta in store.list()] == ["kept"]
    assert_nothing_escaped(tmp_path)


def test_store_refuses_tmp_dir_on_another_filesystem(tmp_path, monkeypatch):
    def cross_device_replace(src, dst):
        raise OSError(errno.EXDEV, "Invalid cross-device link")

    monkeypatch.setattr(storage.os, "replace", cross_device_replace)
    with pytest.raises(StoreError, match="cross-device"):
        BlobStore(tmp_path)
    # The probe cleans up after itself.
    assert list((tmp_path / "blobs").iterdir()) == []
    assert_nothing_escaped(tmp_path)


def test_store_start_leaves_existing_blobs_alone(tmp_path):
    (tmp_path / "blobs").mkdir()
    for name in ("probe-x", "probe"):
        (tmp_path / "blobs" / name).write_bytes(b"blob")
    BlobStore(tmp_path)
    assert sorted(p.name for p in (tmp_path / "blobs").iterdir()) == ["probe", "probe-x"]
    assert_nothing_escaped(tmp_path)


def test_burst_of_parallel_uploads_is_not_dropped(tmp_path):
    # Connections that arrive while the server is busy wait in the listen
    # backlog; with the stdlib default of 5 most of these would be refused.
    srv = SyncboxServer(ServerConfig(data_dir=tmp_path, host="127.0.0.1", port=0))
    clients = []
    thread = None
    try:
        for i in range(64):
            sock = socket.create_connection(srv.server_address[:2], timeout=5)
            clients.append(sock)
            body = f"blob {i}".encode()
            sock.sendall(
                f"PUT /blobs/burst/{i} HTTP/1.1\r\nHost: test\r\nConnection: close\r\n"
                f"Content-Length: {len(body)}\r\n\r\n".encode() + body
            )
        thread = threading.Thread(target=srv.serve_forever, daemon=True)
        thread.start()
        for sock in clients:
            assert sock.recv(65536).startswith(b"HTTP/1.1 201 ")
    finally:
        for sock in clients:
            sock.close()
        if thread is not None:
            srv.shutdown()
        srv.server_close()
    store = BlobStore(tmp_path)
    assert sorted(meta.key for meta in store.list()) == sorted(f"burst/{i}" for i in range(64))
    assert_nothing_escaped(tmp_path)
