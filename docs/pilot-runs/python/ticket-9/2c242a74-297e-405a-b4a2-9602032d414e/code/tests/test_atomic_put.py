import io
import sys
import threading

import pytest

from syncbox_server import app as app_module
from syncbox_server.app import create_app
from syncbox_server.config import Config


@pytest.fixture
def app(tmp_path):
    return create_app(Config(data_dir=str(tmp_path), port=8080))


def _leftover_tmp_files(tmp_path):
    return list(tmp_path.rglob(f"{app_module._TMP_PREFIX}*"))


def test_concurrent_put_same_key_never_yields_torn_or_partial_content(app, tmp_path):
    # Two writers hammer the same key with distinct, same-sized large payloads
    # while a reader polls concurrently. Every response the reader observes
    # must be byte-for-byte one of the two payloads in full - a torn/partial
    # read (mixed bytes, wrong length) means the write wasn't atomic.
    key = "contended.bin"
    payload_a = b"A" * (512 * 1024)
    payload_b = b"B" * (512 * 1024)
    valid_bodies = {payload_a, payload_b}

    errors = []
    observed = []
    stop = threading.Event()

    def writer(payload, iterations):
        client = app.test_client()
        for _ in range(iterations):
            response = client.put(f"/blobs/{key}", data=payload)
            if response.status_code != 201:
                errors.append(("put", response.status_code))

    def reader():
        client = app.test_client()
        while not stop.is_set():
            response = client.get(f"/blobs/{key}")
            if response.status_code == 200:
                observed.append(response.data)
            elif response.status_code != 404:
                errors.append(("get", response.status_code))

    reader_thread = threading.Thread(target=reader)
    writer_threads = [
        threading.Thread(target=writer, args=(payload_a, 25)),
        threading.Thread(target=writer, args=(payload_b, 25)),
    ]

    reader_thread.start()
    for t in writer_threads:
        t.start()
    for t in writer_threads:
        t.join()
    stop.set()
    reader_thread.join()

    assert errors == []
    assert observed, "reader never observed a successful GET during the race"
    for body in observed:
        assert body in valid_bodies, f"torn read: got {len(body)} corrupted bytes"

    final = app.test_client().get(f"/blobs/{key}")
    assert final.status_code == 200
    assert final.data in valid_bodies

    assert _leftover_tmp_files(tmp_path) == []


def test_concurrent_put_different_keys_do_not_interfere(app, tmp_path):
    key_count = 8
    iterations = 20

    errors = []

    def worker(index):
        client = app.test_client()
        payload = bytes([index]) * 4096
        for _ in range(iterations):
            response = client.put(f"/blobs/key-{index}.bin", data=payload)
            if response.status_code != 201:
                errors.append((index, response.status_code))

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(key_count)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert errors == []

    client = app.test_client()
    for i in range(key_count):
        response = client.get(f"/blobs/key-{i}.bin")
        assert response.status_code == 200
        assert response.data == bytes([i]) * 4096

    assert _leftover_tmp_files(tmp_path) == []


def test_tmp_file_is_invisible_in_list_while_put_is_in_flight(app, tmp_path, monkeypatch):
    # Freeze the write right after the temp file is created (before the
    # rename) and confirm that a concurrent GET /blobs neither lists it nor
    # is fooled into treating it as the requested key's content.
    real_replace = app_module.os.replace
    tmp_created = threading.Event()
    release = threading.Event()

    def blocking_replace(src, dst):
        tmp_created.set()
        release.wait(timeout=5)
        return real_replace(src, dst)

    monkeypatch.setattr(app_module.os, "replace", blocking_replace)

    put_result = {}

    def do_put():
        client = app.test_client()
        put_result["response"] = client.put("/blobs/inflight.bin", data=b"new-content")

    put_thread = threading.Thread(target=do_put)
    put_thread.start()
    assert tmp_created.wait(timeout=5)

    try:
        list_response = app.test_client().get("/blobs")
        assert list_response.status_code == 200
        keys = [item["key"] for item in list_response.get_json()]
        assert "inflight.bin" not in keys
        assert all(app_module._TMP_PREFIX not in k for k in keys)

        get_response = app.test_client().get("/blobs/inflight.bin")
        assert get_response.status_code == 404
    finally:
        release.set()
        put_thread.join()

    assert put_result["response"].status_code == 201
    final = app.test_client().get("/blobs/inflight.bin")
    assert final.status_code == 200
    assert final.data == b"new-content"
    assert _leftover_tmp_files(tmp_path) == []


def test_put_failure_after_tempfile_creation_does_not_leak_tmp_file(
    app, tmp_path, monkeypatch
):
    def failing_replace(src, dst):
        raise OSError("simulated failure during rename")

    monkeypatch.setattr(app_module.os, "replace", failing_replace)

    client = app.test_client()
    response = client.put("/blobs/willfail.bin", data=b"data")

    assert response.status_code == 400
    assert not (tmp_path / "willfail.bin").exists()
    assert _leftover_tmp_files(tmp_path) == []


def test_client_disconnect_during_body_read_leaves_no_tmp_file(app, tmp_path):
    class DisconnectingStream:
        def read(self, size=-1):
            raise ConnectionResetError("simulated client disconnect")

        def readline(self, size=-1):
            raise ConnectionResetError("simulated client disconnect")

    environ = {
        "REQUEST_METHOD": "PUT",
        "SCRIPT_NAME": "",
        "PATH_INFO": "/blobs/dropped.bin",
        "QUERY_STRING": "",
        "SERVER_NAME": "127.0.0.1",
        "SERVER_PORT": "80",
        "SERVER_PROTOCOL": "HTTP/1.1",
        "wsgi.version": (1, 0),
        "wsgi.url_scheme": "http",
        "wsgi.input": DisconnectingStream(),
        "wsgi.errors": sys.stderr,
        "wsgi.multithread": False,
        "wsgi.multiprocess": False,
        "wsgi.run_once": False,
        "CONTENT_LENGTH": "1024",
    }

    def start_response(status, headers):
        pass

    try:
        result = app.wsgi_app(environ, start_response)
        b"".join(result)
    except Exception:
        pass

    assert not (tmp_path / "dropped.bin").exists()
    assert _leftover_tmp_files(tmp_path) == []
