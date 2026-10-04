"""Network errors and partial failures in every client command.

A command that can't get going (server unreachable, timing out, unable to
list its blobs) fails with a message saying why, quickly. Once it has, a
file that fails doesn't stop it: the rest are processed, the failures are
reported on stderr at the end and the exit code is non-zero.
"""

from __future__ import annotations

import json
import os
import re
import socket
import time
from http import HTTPStatus
from pathlib import Path

import pytest

from syncbox.client import api
from syncbox.client.cli import main
from syncbox.client.errors import Failures

from .conftest import running_server
from .test_blobs import get
from .test_client_main import run
from .test_client_pull import fake_server, files_only, seed  # noqa: F401 (fake_server is a fixture)
from .test_client_push import remote_state, sha, url_of, write
from .test_client_sync import remote_files

COMMANDS = ["push", "pull", "sync", "status"]


@pytest.fixture
def local(tmp_path_factory) -> Path:
    """The client's directory (the server fixture's data dir is tmp_path)."""
    return tmp_path_factory.mktemp("local")


@pytest.fixture
def state(tmp_path_factory) -> Path:
    return tmp_path_factory.mktemp("state")


def client(command: str, local: Path, url: str, state: Path) -> int:
    return main([command, str(local), "--server", url], environ={"SYNCBOX_STATE_DIR": str(state)})


@pytest.fixture
def fail_on(server, monkeypatch):
    """Make the server fail requests for given keys: ``fail_on("PUT", "a", "b")``.

    The request gets ``500 {"error": "disk on fire"}``, or, with
    ``hang=<seconds>``, no answer for that long, or, with ``drop=True``,
    the connection closed without an answer.
    """
    handler = server.RequestHandlerClass

    def install(method: str, *keys: str, hang: float = 0, drop: bool = False) -> None:
        name = {"PUT": "handle_put_blob", "GET": "handle_get_blob"}[method]
        real = getattr(handler, name)

        def failing(self, raw_key):
            if raw_key not in keys:
                return real(self, raw_key)
            if hang:
                time.sleep(hang)
                self.close_connection = True
            elif drop:
                self.close_connection = True
            else:
                self.send_error_json(HTTPStatus.INTERNAL_SERVER_ERROR, "disk on fire")

        monkeypatch.setattr(handler, name, failing)

    return install


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]  # nothing listens here once closed


def failure_report(err: str) -> list[str]:
    """The failure report at the end of stderr: its header and the indented lines after it.

    (The in-process server logs its requests to stderr too.)
    """
    lines = err.splitlines()
    [start] = [i for i, line in enumerate(lines) if re.match(r"syncbox: error: \d+ files? failed", line)]
    return [lines[start], *(line for line in lines[start + 1:] if line.startswith("  "))]


# --- server unreachable --------------------------------------------------------


@pytest.mark.parametrize("command", COMMANDS)
def test_refused_connection_fails_quickly_with_a_clear_message(command, local, state, capsys):
    write(local, {"a": b"a"})
    port = free_port()
    start = time.monotonic()

    assert client(command, local, f"http://127.0.0.1:{port}", state) == 1

    assert time.monotonic() - start < 5
    captured = capsys.readouterr()
    assert captured.err == f"syncbox: error: cannot reach server http://127.0.0.1:{port}: Connection refused\n"
    assert captured.out == ""


@pytest.mark.parametrize("command", COMMANDS)
def test_unresolvable_host_fails_with_a_clear_message(command, local, state, capsys):
    start = time.monotonic()

    assert client(command, local, "http://syncbox-no-such-host.invalid:8080", state) == 1

    assert time.monotonic() - start < api.CONNECT_TIMEOUT + 5
    err = capsys.readouterr().err
    assert err.startswith(
        "syncbox: error: cannot reach server http://syncbox-no-such-host.invalid:8080:"
        " cannot resolve host 'syncbox-no-such-host.invalid' ("
    ), err


def test_name_resolution_that_hangs_times_out(local, state, monkeypatch, capsys):
    monkeypatch.setattr(api, "CONNECT_TIMEOUT", 0.3)
    monkeypatch.setattr(api.socket, "getaddrinfo", lambda *args, **kwargs: time.sleep(5))
    start = time.monotonic()

    assert client("push", local, "http://slow-dns.test:8080", state) == 1

    assert time.monotonic() - start < 3
    assert capsys.readouterr().err == (
        "syncbox: error: cannot reach server http://slow-dns.test:8080:"
        " cannot resolve host 'slow-dns.test' (no answer within 0.3 s)\n"
    )


def test_connection_that_hangs_times_out(local, state, monkeypatch, capsys):
    monkeypatch.setattr(api, "CONNECT_TIMEOUT", 0.3)
    waited = []

    class Blackhole(socket.socket):
        """As if the SYN went unanswered: connect() waits out its timeout."""

        def connect(self, address):
            waited.append(self.gettimeout())
            time.sleep(self.gettimeout())
            raise TimeoutError("timed out")

    monkeypatch.setattr(api.socket, "socket", Blackhole)

    assert client("pull", local, "http://127.0.0.1:9", state) == 1

    assert waited and all(0 < timeout <= 0.3 for timeout in waited)
    assert capsys.readouterr().err == (
        "syncbox: error: cannot reach server http://127.0.0.1:9: connection timed out after 0.3 s\n"
    )


@pytest.mark.parametrize("command", COMMANDS)
def test_server_that_never_answers_times_out(command, local, state, monkeypatch, capsys):
    monkeypatch.setattr(api, "READ_TIMEOUT", 0.5)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()  # connections complete (in the backlog), but nobody answers
        port = listener.getsockname()[1]
        start = time.monotonic()

        assert client(command, local, f"http://127.0.0.1:{port}", state) == 1

        assert time.monotonic() - start < 5
    assert capsys.readouterr().err == (
        f"syncbox: error: timed out: no response from server http://127.0.0.1:{port} within 0.5 s\n"
    )


def test_timeouts_are_explicit_and_bounded():
    assert 0 < api.CONNECT_TIMEOUT <= 10
    assert 0 < api.READ_TIMEOUT <= 60


def test_unreachable_server_as_a_process(local):
    port = free_port()
    proc = run("pull", str(local), "--server", f"http://127.0.0.1:{port}")
    assert proc.returncode == 1
    assert proc.stderr == f"syncbox: error: cannot reach server http://127.0.0.1:{port}: Connection refused\n"
    assert proc.stdout == ""


# --- partial failure: push ------------------------------------------------------


def test_push_goes_on_after_a_server_error_and_reports_it(server, conn, local, state, fail_on, capsys):
    write(local, {"a": b"a", "bad.txt": b"bad", "c": b"c"})
    fail_on("PUT", "bad.txt")

    assert client("push", local, url_of(server), state) == 1

    assert remote_files(conn) == {"a": b"a", "c": b"c"}
    captured = capsys.readouterr()
    assert captured.out == "added a\nadded c\n2 uploaded, 0 already up to date, 1 failed\n"
    assert failure_report(captured.err) == [
        "syncbox: error: 1 file failed:",
        "  cannot upload 'bad.txt': HTTP 500 Internal Server Error: disk on fire",
    ]


def test_push_goes_on_after_a_timeout_or_a_dropped_connection(server, conn, local, state, fail_on, monkeypatch,
                                                              capsys):
    monkeypatch.setattr(api, "READ_TIMEOUT", 0.3)
    write(local, {"a": b"a", "dropped": b"d", "slow": b"s", "z": b"z"})
    fail_on("PUT", "slow", hang=1)
    fail_on("PUT", "dropped", drop=True)
    url = url_of(server)

    assert client("push", local, url, state) == 1

    assert remote_files(conn) == {"a": b"a", "z": b"z"}
    captured = capsys.readouterr()
    assert captured.out.splitlines()[-1] == "2 uploaded, 0 already up to date, 2 failed"
    assert failure_report(captured.err) == [
        "syncbox: error: 2 files failed:",
        f"  cannot upload 'dropped': server {url} closed the connection without answering",
        f"  cannot upload 'slow': timed out: no response from server {url} within 0.3 s",
    ]


@pytest.mark.skipif(os.geteuid() == 0, reason="root reads files regardless of permissions")
def test_push_goes_on_after_unreadable_files_and_directories(server, conn, local, state, capsys):
    write(local, {"a": b"a", "secret": b"s", "private/x": b"x", "z/z": b"z"})
    (local / "secret").chmod(0)
    (local / "private").chmod(0)
    try:
        assert client("push", local, url_of(server), state) == 1
    finally:
        (local / "private").chmod(0o755)

    assert remote_files(conn) == {"a": b"a", "z/z": b"z"}
    captured = capsys.readouterr()
    assert captured.out.splitlines()[-1] == "2 uploaded, 0 already up to date, 2 failed"
    assert sorted(failure_report(captured.err)[1:]) == [
        "  cannot read 'secret': Permission denied",
        "  cannot read directory 'private': Permission denied",
    ]


def test_server_going_away_part_way_fails_the_rest_without_waiting(local, state, tmp_path, monkeypatch, capsys):
    write(local, {"a": b"a", "b": b"b", "c": b"c"})
    connects = []
    real_connect = api._Connection.connect

    def counting_connect(self):
        connects.append(1)
        real_connect(self)

    monkeypatch.setattr(api._Connection, "connect", counting_connect)
    with running_server(tmp_path) as srv:
        url = url_of(srv)
        real_list = api.ServerClient.list_blobs

        def list_then_stop(self):
            blobs = real_list(self)
            self.close()
            srv.shutdown()
            srv.server_close()  # from now on, connections are refused
            return blobs

        monkeypatch.setattr(api.ServerClient, "list_blobs", list_then_stop)
        start = time.monotonic()

        assert client("push", local, url, state) == 1

        assert time.monotonic() - start < 5
    assert len(connects) == 2  # the listing, then one try for "a"; none for "b" and "c"
    captured = capsys.readouterr()
    assert captured.out == "0 uploaded, 0 already up to date, 3 failed\n"
    assert failure_report(captured.err) == [
        f"syncbox: error: 3 files failed (cannot reach server {url}: Connection refused;"
        " later transfers were not attempted):",
        f"  cannot upload 'a': cannot reach server {url}: Connection refused",
        "  cannot upload 'b': not attempted, the server is unreachable",
        "  cannot upload 'c': not attempted, the server is unreachable",
    ]


# --- partial failure: pull ------------------------------------------------------


def test_pull_goes_on_after_a_server_error_and_reports_it(server, conn, local, state, fail_on, capsys):
    seed(conn, {"a": b"a", "bad.txt": b"new", "c/c": b"c"})
    write(local, {"bad.txt": b"old"})
    fail_on("GET", "bad.txt")

    assert client("pull", local, url_of(server), state) == 1

    assert files_only(local) == {"a": b"a", "bad.txt": b"old", "c/c": b"c"}
    captured = capsys.readouterr()
    assert captured.out == "added a\nadded c/c\n2 downloaded, 0 already up to date, 1 failed\n"
    assert failure_report(captured.err) == [
        "syncbox: error: 1 file failed:",
        "  cannot download 'bad.txt': HTTP 500 Internal Server Error: disk on fire",
    ]


def test_pull_goes_on_after_a_timeout_and_a_local_write_error(server, conn, local, state, fail_on, monkeypatch,
                                                              capsys):
    monkeypatch.setattr(api, "READ_TIMEOUT", 0.3)
    seed(conn, {"a": b"a", "blocked": b"file", "slow": b"s", "z": b"z"})
    (local / "blocked").mkdir()  # a directory where the file should go
    fail_on("GET", "slow", hang=1)
    url = url_of(server)

    assert client("pull", local, url, state) == 1

    assert files_only(local) == {"a": b"a", "z": b"z"}
    captured = capsys.readouterr()
    assert captured.out.splitlines()[-1] == "2 downloaded, 0 already up to date, 2 failed"
    assert failure_report(captured.err) == [
        "syncbox: error: 2 files failed:",
        "  cannot write 'blocked': a directory is in the way",
        f"  cannot download 'slow': timed out: no response from server {url} within 0.3 s",
    ]


# --- partial failure: sync ------------------------------------------------------


def test_sync_goes_on_after_failed_transfers_both_ways(server, conn, local, state, fail_on, capsys):
    seed(conn, {"from-server": b"s", "bad-down": b"server only"})
    write(local, {"from-local": b"l", "bad-up": b"local only"})
    fail_on("PUT", "bad-up")
    fail_on("GET", "bad-down")

    assert client("sync", local, url_of(server), state) == 1

    # (GET of "bad-down" still fails, so the server side is checked by its listing.)
    assert remote_state(conn) == {"from-server": sha(b"s"), "bad-down": sha(b"server only"), "from-local": sha(b"l")}
    assert files_only(local) == {"from-local": b"l", "bad-up": b"local only", "from-server": b"s"}
    captured = capsys.readouterr()
    assert captured.out == (
        "upload    new       from-local\n"
        "download  new       from-server\n"
        "1 uploaded, 1 downloaded, 0 already up to date, 2 failed\n"
    )
    assert failure_report(captured.err) == [
        "syncbox: error: 2 files failed:",
        "  cannot download 'bad-down': HTTP 500 Internal Server Error: disk on fire",
        "  cannot upload 'bad-up': HTTP 500 Internal Server Error: disk on fire",
    ]
    # Only what made it is recorded as the common state.
    [state_file] = state.iterdir()
    assert json.loads(state_file.read_bytes())["files"] == {"from-local": sha(b"l"), "from-server": sha(b"s")}


def test_sync_after_a_partial_failure_finishes_the_job(server, conn, local, state, fail_on, monkeypatch, capsys):
    seed(conn, {"bad-down": b"server only"})
    write(local, {"bad-up": b"local only"})
    handler = server.RequestHandlerClass
    real_put, real_get = handler.handle_put_blob, handler.handle_get_blob
    fail_on("PUT", "bad-up")
    fail_on("GET", "bad-down")
    assert client("sync", local, url_of(server), state) == 1
    capsys.readouterr()

    monkeypatch.setattr(handler, "handle_put_blob", real_put)
    monkeypatch.setattr(handler, "handle_get_blob", real_get)
    assert client("sync", local, url_of(server), state) == 0

    assert capsys.readouterr().out == (
        "download  new       bad-down\n"
        "upload    new       bad-up\n"
        "1 uploaded, 1 downloaded, 0 already up to date\n"
    )


@pytest.mark.skipif(os.geteuid() == 0, reason="root reads files regardless of permissions")
def test_sync_leaves_alone_what_it_cannot_read_locally(server, conn, local, state, capsys):
    # The server has other versions; an unreadable local file (or directory)
    # must not be mistaken for a missing one and overwritten.
    seed(conn, {"secret": b"server", "private/x": b"server", "fine": b"fine"})
    write(local, {"secret": b"local", "private/x": b"local"})
    (local / "secret").chmod(0)
    (local / "private").chmod(0o300)  # can be entered and written, but not listed
    try:
        assert client("sync", local, url_of(server), state) == 1
    finally:
        (local / "private").chmod(0o755)
        (local / "secret").chmod(0o644)

    assert files_only(local) == {"secret": b"local", "private/x": b"local", "fine": b"fine"}
    assert remote_files(conn) == {"secret": b"server", "private/x": b"server", "fine": b"fine"}
    captured = capsys.readouterr()
    assert captured.out == "download  new       fine\n0 uploaded, 1 downloaded, 0 already up to date, 2 failed\n"
    assert sorted(failure_report(captured.err)[1:]) == [
        "  cannot read 'secret': Permission denied",
        "  cannot read directory 'private': Permission denied",
    ]


def test_sync_invalid_key_from_the_server_is_a_failure(fake_server, local, state, capsys):
    body = json.dumps([
        {"key": "../escape", "size": 1, "sha256": sha(b"x"), "modified_at": "2026-01-01T00:00:00Z"},
        {"key": "fine", "size": 1, "sha256": sha(b"x"), "modified_at": "2026-01-01T00:00:00Z"},
    ]).encode()
    url = fake_server({"/blobs": (200, body, {}), "/blobs/fine": (200, b"x", {})})

    assert client("sync", local, url, state) == 1

    assert files_only(local) == {"fine": b"x"}
    captured = capsys.readouterr()
    assert captured.out.splitlines()[-1] == "0 uploaded, 1 downloaded, 0 already up to date, 1 failed"
    assert failure_report(captured.err) == [
        "syncbox: error: 1 file failed:",
        "  server listed an invalid key '../escape'; not synced",
    ]


# --- partial failure: status ----------------------------------------------------


@pytest.mark.skipif(os.geteuid() == 0, reason="root reads files regardless of permissions")
def test_status_goes_on_after_an_unreadable_file(server, conn, local, state, capsys):
    seed(conn, {"secret": b"server", "remote": b"r"})
    write(local, {"secret": b"local", "new": b"n"})
    (local / "secret").chmod(0)

    assert client("status", local, url_of(server), state) == 1

    captured = capsys.readouterr()
    # "secret" is neither "upload new" nor "download new": its local side is unknown.
    assert captured.out == (
        "upload    new      new\n"
        "download  new      remote\n"
        "1 to upload, 1 to download, 0 up to date, 1 failed\n"
    )
    assert failure_report(captured.err) == ["syncbox: error: 1 file failed:", "  cannot read 'secret': Permission denied"]


# --- as a process ---------------------------------------------------------------


@pytest.mark.parametrize("command", ["push", "sync"])
def test_partial_failure_as_a_process(command, server, conn, local, state, fail_on):
    write(local, {"a": b"a", "bad.txt": b"bad", "c": b"c"})
    fail_on("PUT", "bad.txt")

    proc = run(command, str(local), "--server", url_of(server), env={"SYNCBOX_STATE_DIR": str(state)})

    assert proc.returncode == 1
    assert remote_files(conn) == {"a": b"a", "c": b"c"}
    assert proc.stdout.splitlines()[-1].endswith(", 1 failed")
    assert proc.stderr.endswith(
        "syncbox: error: 1 file failed:\n"
        "  cannot upload 'bad.txt': HTTP 500 Internal Server Error: disk on fire\n"
    )


def test_pull_partial_failure_as_a_process(server, conn, local, fail_on):
    seed(conn, {"a": b"a", "bad.txt": b"bad"})
    fail_on("GET", "bad.txt")

    proc = run("pull", str(local), "--server", url_of(server))

    assert proc.returncode == 1
    assert files_only(local) == {"a": b"a"}
    assert proc.stdout == "added a\n1 downloaded, 0 already up to date, 1 failed\n"
    assert proc.stderr.endswith(
        "syncbox: error: 1 file failed:\n"
        "  cannot download 'bad.txt': HTTP 500 Internal Server Error: disk on fire\n"
    )
    assert get(conn, "a")[1] == b"a"


# --- Failures ---------------------------------------------------------------------


def test_failures_cover_keys_and_directories():
    reported = []
    failures = Failures(reported.append)
    failures.add("file", "cannot read 'file'")
    failures.add("dir/sub", "cannot read directory 'dir/sub'", directory=True)

    assert reported == ["cannot read 'file'", "cannot read directory 'dir/sub'"]
    assert len(failures) == 2
    assert failures.covers("file")
    assert failures.covers("dir/sub/x")
    assert failures.covers("dir/sub/deeper/x")
    assert not failures.covers("file/x")
    assert not failures.covers("dir/sub")
    assert not failures.covers("dir/subx/y")
    assert not failures.covers("dir/x")
