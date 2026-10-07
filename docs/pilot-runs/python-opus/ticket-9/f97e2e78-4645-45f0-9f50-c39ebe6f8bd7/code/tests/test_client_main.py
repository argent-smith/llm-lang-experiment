"""The ``syncbox`` executable as a real process."""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from .test_blobs import list_blobs, put

REPO = Path(__file__).resolve().parent.parent


def syncbox_command() -> list[str]:
    """``syncbox`` on PATH (as in the Docker image), else the one in bin/."""
    installed = shutil.which("syncbox")
    return [installed] if installed else [sys.executable, str(REPO / "bin" / "syncbox")]


def run(*args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    full_env = {k: v for k, v in os.environ.items() if not k.startswith("SYNCBOX_")}
    full_env["PYTHONPATH"] = str(REPO)
    full_env.update(env or {})
    return subprocess.run(
        [*syncbox_command(), *args],
        env=full_env,
        capture_output=True,
        text=True,
        timeout=30,
    )


def test_push(server, conn, tmp_path_factory):
    local = tmp_path_factory.mktemp("local")
    (local / "docs").mkdir()
    (local / "docs" / "readme.txt").write_bytes(b"hello")
    url = "http://{}:{}".format(*server.server_address[:2])

    proc = run("push", str(local), "--server", url)

    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "added docs/readme.txt\n1 uploaded, 0 already up to date\n"
    assert [(b["key"], b["sha256"]) for b in list_blobs(conn)] == [
        ("docs/readme.txt", hashlib.sha256(b"hello").hexdigest()),
    ]

    proc = run("push", str(local), env={"SYNCBOX_SERVER": url})
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "0 uploaded, 1 already up to date\n"


def test_pull(server, conn, tmp_path_factory):
    put(conn, "docs/readme.txt", b"hello")
    local = tmp_path_factory.mktemp("local")
    url = "http://{}:{}".format(*server.server_address[:2])

    proc = run("pull", str(local), "--server", url)

    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "added docs/readme.txt\n1 downloaded, 0 already up to date\n"
    assert (local / "docs" / "readme.txt").read_bytes() == b"hello"

    proc = run("pull", str(local), env={"SYNCBOX_SERVER": url})
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "0 downloaded, 1 already up to date\n"


def test_status(server, conn, tmp_path_factory):
    put(conn, "remote.txt", b"remote")
    put(conn, "both.txt", b"server version")
    local = tmp_path_factory.mktemp("local")
    (local / "local.txt").write_bytes(b"local")
    (local / "both.txt").write_bytes(b"local version")
    url = "http://{}:{}".format(*server.server_address[:2])

    proc = run("status", str(local), "--server", url)

    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == (
        "upload    changed  both.txt\n"
        "upload    new      local.txt\n"
        "download  changed  both.txt\n"
        "download  new      remote.txt\n"
        "2 to upload, 2 to download, 0 up to date\n"
    )
    assert sorted(b["key"] for b in list_blobs(conn)) == ["both.txt", "remote.txt"]
    assert sorted(p.name for p in local.iterdir()) == ["both.txt", "local.txt"]

    (local / "both.txt").write_bytes(b"server version")
    (local / "local.txt").unlink()
    (local / "remote.txt").write_bytes(b"remote")
    proc = run("status", str(local), env={"SYNCBOX_SERVER": url})
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "nothing to upload or download, 2 up to date\n"


@pytest.mark.parametrize("command", ["push", "pull", "status"])
def test_unreachable_server(tmp_path, command):
    proc = run(command, str(tmp_path), "--server", "http://127.0.0.1:1")
    assert proc.returncode == 1
    assert proc.stderr == "syncbox: error: cannot reach server http://127.0.0.1:1: Connection refused\n"


def test_sync_is_not_implemented_yet(tmp_path):
    proc = run("sync", str(tmp_path), "--server", "http://127.0.0.1:1")
    assert proc.returncode == 1
    assert "'sync' is not implemented yet" in proc.stderr


def test_usage(tmp_path):
    proc = run("push", str(tmp_path))
    assert proc.returncode == 2
    assert "server URL is required" in proc.stderr

    proc = run("--help")
    assert proc.returncode == 0
    assert "push" in proc.stdout and "pull" in proc.stdout
