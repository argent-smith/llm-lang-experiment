"""End-to-end tests of ``python -m syncbox.server`` as a real process."""

from __future__ import annotations

import hashlib
import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

import pytest

from .conftest import free_port


def start(*args: str, env: dict[str, str] | None = None) -> subprocess.Popen:
    full_env = {k: v for k, v in os.environ.items() if not k.startswith("SYNCBOX_")}
    full_env.update(env or {})
    return subprocess.Popen(
        [sys.executable, "-m", "syncbox.server", *args],
        env=full_env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def wait_healthy(proc: subprocess.Popen, port: int, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            pytest.fail(f"server exited early with {proc.returncode}: {proc.stderr.read()}")
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=1) as resp:
                assert resp.status == 200
                return
        except (urllib.error.URLError, ConnectionError):
            time.sleep(0.05)
    pytest.fail("server did not become healthy in time")


def stop(proc: subprocess.Popen, sig: int = signal.SIGTERM) -> int:
    proc.send_signal(sig)
    try:
        return proc.wait(timeout=10)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()


@pytest.fixture
def procs():
    started: list[subprocess.Popen] = []
    yield started
    for proc in started:
        if proc.poll() is None:
            proc.kill()
        proc.communicate()


@pytest.mark.parametrize("sig", [signal.SIGTERM, signal.SIGINT])
def test_serves_healthz_and_stops_cleanly(tmp_path, procs, sig):
    port = free_port()
    data_dir = tmp_path / "data"
    proc = start("--data-dir", str(data_dir), "--port", str(port))
    procs.append(proc)

    wait_healthy(proc, port)
    assert data_dir.is_dir()

    assert stop(proc, sig) == 0
    assert "listening on" in proc.stderr.read()


def test_configured_via_environment(tmp_path, procs):
    port = free_port()
    proc = start(env={"SYNCBOX_DATA_DIR": str(tmp_path), "SYNCBOX_PORT": str(port)})
    procs.append(proc)

    wait_healthy(proc, port)
    assert stop(proc) == 0


def test_put_then_get_blob(tmp_path, procs):
    port = free_port()
    data_dir = tmp_path / "data"
    proc = start("--data-dir", str(data_dir), "--port", str(port))
    procs.append(proc)
    wait_healthy(proc, port)

    url = f"http://127.0.0.1:{port}/blobs/docs/readme.txt"
    put = urllib.request.Request(url, data=b"hello", method="PUT")
    with urllib.request.urlopen(put, timeout=5) as resp:
        assert resp.status == 201
        assert json.loads(resp.read()) == {
            "key": "docs/readme.txt",
            "sha256": hashlib.sha256(b"hello").hexdigest(),
            "size": 5,
        }
    with urllib.request.urlopen(url, timeout=5) as resp:
        assert resp.status == 200
        assert resp.read() == b"hello"
    with pytest.raises(urllib.error.HTTPError) as exc:
        urllib.request.urlopen(f"http://127.0.0.1:{port}/blobs/missing", timeout=5)
    assert exc.value.code == 404
    exc.value.close()

    assert stop(proc) == 0


def test_list_blobs(tmp_path, procs):
    port = free_port()
    data_dir = tmp_path / "data"
    proc = start("--data-dir", str(data_dir), "--port", str(port))
    procs.append(proc)
    wait_healthy(proc, port)

    base = f"http://127.0.0.1:{port}/blobs"
    with urllib.request.urlopen(base, timeout=5) as resp:
        assert resp.status == 200
        assert json.loads(resp.read()) == []

    for key, data in [("docs/readme.txt", b"hello"), ("top", b"")]:
        put = urllib.request.Request(f"{base}/{key}", data=data, method="PUT")
        with urllib.request.urlopen(put, timeout=5) as resp:
            assert resp.status == 201
    with urllib.request.urlopen(base, timeout=5) as resp:
        assert resp.status == 200
        assert resp.headers["Content-Type"] == "application/json"
        blobs = json.loads(resp.read())
    assert [(b["key"], b["size"], b["sha256"]) for b in blobs] == [
        ("docs/readme.txt", 5, hashlib.sha256(b"hello").hexdigest()),
        ("top", 0, hashlib.sha256(b"").hexdigest()),
    ]
    for blob in blobs:
        assert blob["modified_at"].endswith("Z")

    assert stop(proc) == 0


def test_missing_data_dir_is_a_usage_error(procs):
    proc = start("--port", str(free_port()))
    procs.append(proc)
    _, stderr = proc.communicate(timeout=10)
    assert proc.returncode == 2
    assert "data directory is required" in stderr


def test_invalid_port_is_a_usage_error(tmp_path, procs):
    proc = start("--data-dir", str(tmp_path), "--port", "99999")
    procs.append(proc)
    _, stderr = proc.communicate(timeout=10)
    assert proc.returncode == 2
    assert "invalid port" in stderr


def test_unusable_data_dir_fails_startup(tmp_path, procs):
    not_a_dir = tmp_path / "file"
    not_a_dir.write_text("x")
    proc = start("--data-dir", str(not_a_dir), "--port", str(free_port()))
    procs.append(proc)
    _, stderr = proc.communicate(timeout=10)
    assert proc.returncode == 1
    assert "not a directory" in stderr


def test_port_in_use_fails_startup(tmp_path, procs):
    with socket.socket() as busy:
        busy.bind(("0.0.0.0", 0))
        busy.listen()
        port = busy.getsockname()[1]
        proc = start("--data-dir", str(tmp_path), "--port", str(port))
        procs.append(proc)
        _, stderr = proc.communicate(timeout=10)
    assert proc.returncode == 1
    assert "cannot listen" in stderr
