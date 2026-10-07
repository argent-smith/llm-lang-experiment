"""``syncbox push`` against an in-process server, run through cli.main()."""

from __future__ import annotations

import hashlib
import io
import os
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from syncbox.client import api
from syncbox.client.api import ServerClient, parse_server_url
from syncbox.client.cli import main
from syncbox.client.errors import ClientError
from syncbox.server.storage import PutResult

from .test_blobs import get, list_blobs, put


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def url_of(server) -> str:
    host, port = server.server_address[:2]
    return f"http://{host}:{port}"


def write(root: Path, files: dict[str, bytes]) -> None:
    for key, data in files.items():
        path = root.joinpath(*key.split("/"))
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


@pytest.fixture
def local(tmp_path_factory) -> Path:
    """The directory to push (the server fixture's data dir is tmp_path)."""
    return tmp_path_factory.mktemp("local")


@pytest.fixture
def uploads(server, monkeypatch) -> list[str]:
    """Keys the server has stored, in order."""
    stored: list[str] = []
    real_put = server.store.put

    def counting_put(key, chunks):
        result = real_put(key, chunks)
        stored.append(key)
        return result

    monkeypatch.setattr(server.store, "put", counting_put)
    return stored


def push(local: Path, server_url: str, *extra: str, env: dict[str, str] | None = None) -> int:
    return main(["push", str(local), "--server", server_url, *extra], environ=env or {})


def remote_state(conn) -> dict[str, str]:
    return {blob["key"]: blob["sha256"] for blob in list_blobs(conn)}


FILES = {
    "docs/readme.txt": b"hello",
    "docs/deep/nested/data.bin": bytes(range(256)) * 1000,
    "empty": b"",
    "top.txt": b"top",
    "with space/ünïcödé ?#%+&;=.txt": b"odd name",
    "back\\slash": b"backslash is an ordinary character",
    ".hidden": b"dotfile",
}


# --- what gets uploaded -------------------------------------------------------


def test_push_uploads_every_file_under_its_relative_posix_path(server, conn, local, uploads, capsys):
    write(local, FILES)
    (local / "empty-dir").mkdir()

    assert push(local, url_of(server)) == 0

    assert remote_state(conn) == {key: sha(data) for key, data in FILES.items()}
    for key, data in FILES.items():
        resp, body = get(conn, key)
        assert (resp.status, body) == (200, data)
    assert sorted(uploads) == sorted(FILES)
    out = capsys.readouterr().out.splitlines()
    assert sorted(out[:-1]) == sorted(f"added {key}" for key in FILES)
    assert out[-1] == f"{len(FILES)} uploaded, 0 already up to date"


def test_large_file_is_uploaded_intact(server, conn, local):
    data = os.urandom(3 * 1024 * 1024 + 17)
    write(local, {"big.bin": data})

    assert push(local, url_of(server)) == 0

    resp, body = get(conn, "big.bin")
    assert resp.status == 200 and sha(body) == sha(data)


def test_second_push_uploads_nothing(server, conn, local, uploads, capsys):
    write(local, FILES)
    assert push(local, url_of(server)) == 0
    uploads.clear()
    capsys.readouterr()

    assert push(local, url_of(server)) == 0

    assert uploads == []
    assert capsys.readouterr().out == f"0 uploaded, {len(FILES)} already up to date\n"


def test_only_changed_and_new_files_are_uploaded(server, conn, local, uploads, capsys):
    write(local, FILES)
    assert push(local, url_of(server)) == 0
    uploads.clear()
    capsys.readouterr()

    write(local, {"docs/readme.txt": b"changed", "new/file": b"new"})
    assert push(local, url_of(server)) == 0

    assert sorted(uploads) == ["docs/readme.txt", "new/file"]
    assert get(conn, "docs/readme.txt")[1] == b"changed"
    assert capsys.readouterr().out.splitlines() == [
        "updated docs/readme.txt",
        "added new/file",
        f"2 uploaded, {len(FILES) - 1} already up to date",
    ]


def test_comparison_is_by_content_not_by_time(server, conn, local, uploads):
    # The server already has the same bytes (put there some other way) ...
    put(conn, "same", b"same content")
    # ... and a different version of another file, with a newer mtime.
    write(local, {"same": b"same content", "differs": b"local version"})
    os.utime(local / "differs", (1, 1))
    put(conn, "differs", b"server version")
    uploads.clear()

    assert push(local, url_of(server)) == 0

    assert uploads == ["differs"]
    assert get(conn, "differs")[1] == b"local version"


def test_blobs_missing_locally_are_left_on_the_server(server, conn, local):
    put(conn, "server-only/file", b"keep me")
    write(local, {"local": b"x"})

    assert push(local, url_of(server)) == 0

    assert remote_state(conn) == {"server-only/file": sha(b"keep me"), "local": sha(b"x")}


def test_empty_directory_uploads_nothing(server, conn, local, capsys):
    assert push(local, url_of(server)) == 0
    assert list_blobs(conn) == []
    assert capsys.readouterr().out == "0 uploaded, 0 already up to date\n"


def test_symlinks_and_special_files_are_skipped_with_a_warning(server, conn, local, tmp_path_factory, capsys):
    outside = tmp_path_factory.mktemp("outside")
    write(outside, {"secret": b"outside the pushed directory"})
    write(local, {"real.txt": b"real"})
    (local / "file-link").symlink_to("real.txt")
    (local / "dir-link").symlink_to(outside, target_is_directory=True)
    os.mkfifo(local / "fifo")

    assert push(local, url_of(server)) == 0

    assert remote_state(conn) == {"real.txt": sha(b"real")}
    err = capsys.readouterr().err
    assert "skipping 'file-link': symbolic link" in err
    assert "skipping 'dir-link': symbolic link" in err
    assert "skipping 'fifo': not a regular file" in err


def test_dir_given_as_symlink_is_followed(server, conn, local, tmp_path_factory):
    write(local, {"a": b"a"})
    link = tmp_path_factory.mktemp("links") / "link"
    link.symlink_to(local, target_is_directory=True)

    assert push(link, url_of(server)) == 0
    assert remote_state(conn) == {"a": sha(b"a")}


def test_relative_dir(server, conn, local, monkeypatch):
    write(local, {"sub/a": b"a"})
    monkeypatch.chdir(local.parent)

    assert main(["push", local.name, "--server", url_of(server)], environ={}) == 0
    assert remote_state(conn) == {"sub/a": sha(b"a")}


# --- --server and SYNCBOX_SERVER ----------------------------------------------


def test_server_from_environment(server, conn, local):
    write(local, {"a": b"a"})
    assert main(["push", str(local)], environ={"SYNCBOX_SERVER": url_of(server)}) == 0
    assert remote_state(conn) == {"a": sha(b"a")}


def test_flag_overrides_environment(server, conn, local):
    write(local, {"a": b"a"})
    env = {"SYNCBOX_SERVER": "http://127.0.0.1:1"}
    assert push(local, url_of(server), env=env) == 0
    assert remote_state(conn) == {"a": sha(b"a")}


def test_trailing_slash_in_server_url(server, conn, local):
    write(local, {"a": b"a"})
    assert push(local, url_of(server) + "/") == 0
    assert remote_state(conn) == {"a": sha(b"a")}


@pytest.mark.parametrize("env", [{}, {"SYNCBOX_SERVER": ""}])
def test_missing_server_is_a_usage_error(local, env, capsys):
    assert main(["push", str(local)], environ=env) == 2
    assert "server URL is required: pass --server or set SYNCBOX_SERVER" in capsys.readouterr().err


@pytest.mark.parametrize("url", [
    "127.0.0.1:8080",
    "localhost",
    "ftp://127.0.0.1:8080",
    "https://127.0.0.1:8080",
    "http://",
    "http://127.0.0.1:99999",
    "http://127.0.0.1:port",
    "http://user:pw@127.0.0.1:8080",
    "http://127.0.0.1:8080/?q=1",
])
def test_invalid_server_url_is_a_usage_error(local, url, capsys):
    assert push(local, url) == 2
    assert repr(url) in capsys.readouterr().err


def test_parse_server_url():
    assert parse_server_url("http://example.com") == api.ServerURL("example.com", 80, "", "http://example.com")
    assert parse_server_url("HTTP://[::1]:8080/sync/") == api.ServerURL("::1", 8080, "/sync", "HTTP://[::1]:8080/sync/")


def test_path_prefix_in_server_url_is_kept(server, local, capsys):
    # The server has no /prefix, so the request must have gone there.
    write(local, {"a": b"a"})
    assert push(local, url_of(server) + "/prefix") == 1
    assert "listing blobs failed: HTTP 404 Not Found: not found" in capsys.readouterr().err


# --- arguments and other commands -------------------------------------------


@pytest.mark.parametrize("command", ["pull", "sync", "status"])
def test_other_commands_are_not_implemented_yet(server, conn, local, command, capsys):
    write(local, {"a": b"a"})
    put(conn, "b", b"b")

    assert main([command, str(local), "--server", url_of(server)], environ={}) == 1

    assert f"'{command}' is not implemented yet" in capsys.readouterr().err
    assert remote_state(conn) == {"b": sha(b"b")}
    assert sorted(p.name for p in local.iterdir()) == ["a"]


@pytest.mark.parametrize("argv", [[], ["push"], ["bogus", "dir"], ["push", "a", "b"], ["push", "dir", "--bogus"]])
def test_bad_arguments_are_usage_errors(argv, capsys):
    with pytest.raises(SystemExit) as exc:
        main([*argv, "--server", "http://127.0.0.1:1"], environ={})
    assert exc.value.code == 2
    assert "usage: syncbox" in capsys.readouterr().err


def test_missing_dir(server, tmp_path, capsys):
    assert push(tmp_path / "nope", url_of(server)) == 1
    assert "does not exist" in capsys.readouterr().err


def test_dir_is_a_file(server, tmp_path, capsys):
    (tmp_path / "file").write_bytes(b"x")
    assert push(tmp_path / "file", url_of(server)) == 1
    assert "is not a directory" in capsys.readouterr().err


# --- failures -----------------------------------------------------------------


def test_unreachable_server_fails_quickly(local, capsys):
    write(local, {"a": b"a"})
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]  # nothing listens here once closed
    start = time.monotonic()

    assert push(local, f"http://127.0.0.1:{port}") == 1

    assert time.monotonic() - start < 5
    err = capsys.readouterr().err
    assert f"syncbox: error: cannot reach server http://127.0.0.1:{port}: Connection refused" in err


def test_silent_server_times_out(local, monkeypatch, capsys):
    monkeypatch.setattr(api, "READ_TIMEOUT", 0.5)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()  # accepts connections (in the backlog) but never answers
        port = listener.getsockname()[1]
        assert push(local, f"http://127.0.0.1:{port}") == 1
    assert "timed out" in capsys.readouterr().err


def test_rejected_upload_fails_the_push(server, conn, local, capsys):
    # A blob "a" leaves no room for "a/b" on the server, which answers 400.
    put(conn, "a", b"file")
    write(local, {"a/b": b"under a"})

    assert push(local, url_of(server)) == 1

    err = capsys.readouterr().err
    assert "syncbox: error: cannot upload 'a/b': HTTP 400 Bad Request: key cannot be stored" in err


def test_non_utf8_file_name_fails_the_push(server, conn, local, capsys):
    os.mkdir(os.path.join(os.fsencode(local), b"bad-\xff"))
    with open(os.path.join(os.fsencode(local), b"bad-\xff", b"file"), "wb") as f:
        f.write(b"x")

    assert push(local, url_of(server)) == 1

    assert r"cannot sync 'bad-\xff/file': file name is not valid UTF-8" in capsys.readouterr().err
    assert list_blobs(conn) == []


@pytest.mark.skipif(os.geteuid() == 0, reason="root reads files regardless of permissions")
def test_unreadable_file_fails_the_push(server, conn, local, capsys):
    write(local, {"secret": b"x"})
    (local / "secret").chmod(0)

    assert push(local, url_of(server)) == 1

    assert "cannot read 'secret': Permission denied" in capsys.readouterr().err
    assert list_blobs(conn) == []


def test_server_storing_other_bytes_fails_the_push(server, local, monkeypatch, capsys):
    def lying_put(key, chunks):
        for _ in chunks:
            pass
        return PutResult(key=key, sha256=sha(b"something else"), size=0)

    monkeypatch.setattr(server.store, "put", lying_put)
    write(local, {"a": b"a"})

    assert push(local, url_of(server)) == 1
    assert f"server stored sha256 {sha(b'something else')}, sent {sha(b'a')}" in capsys.readouterr().err


# --- uploads of files that change while being read -----------------------------


def test_file_body_yields_exactly_the_declared_size():
    digest = hashlib.sha256()
    data = os.urandom(200_000)
    assert b"".join(api._file_body(io.BytesIO(data), len(data), digest)) == data
    assert digest.hexdigest() == sha(data)


@pytest.mark.parametrize("actual", [b"x" * 99_999, b"x" * 100_001])
def test_file_body_never_completes_if_the_size_changed(actual):
    sent = []
    with pytest.raises(api._BodyError):
        for chunk in api._file_body(io.BytesIO(actual), 100_000, hashlib.sha256()):
            sent.append(chunk)
    assert sum(map(len, sent)) < 100_000


def test_upload_of_a_shrinking_file_keeps_the_old_blob(server, conn, local, monkeypatch):
    put(conn, "f", b"old")
    write(local, {"f": b"new content"})
    real_fstat = os.fstat

    class Grown:
        def __init__(self, st):
            self.st_size = st.st_size + 100_000

    # As if the file had been 100 kB longer when the upload started.
    monkeypatch.setattr(api.os, "fstat", lambda fd: Grown(real_fstat(fd)))
    with ServerClient(parse_server_url(url_of(server))) as client:
        with pytest.raises(ClientError, match="'f': file shrank while it was being uploaded"):
            client.put_blob("f", local / "f")
        monkeypatch.setattr(api.os, "fstat", real_fstat)
        # The client is still usable afterwards.
        client.put_blob("g", local / "f")

    assert get(conn, "f")[1] == b"old"
    assert get(conn, "g")[1] == b"new content"


# --- responses from a misbehaving server ---------------------------------------


class _FakeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    status = 200
    body = b""

    def do_GET(self):
        self.send_response(self.status)
        self.send_header("Content-Length", str(len(self.body)))
        self.end_headers()
        self.wfile.write(self.body)

    def log_message(self, *args):
        pass


@pytest.fixture
def fake_server():
    """Start a server answering every GET with a fixed status and body; returns its URL."""
    servers = []

    def start(status: int, body: bytes) -> str:
        handler = type("Handler", (_FakeHandler,), {"status": status, "body": body})
        srv = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        servers.append(srv)
        return f"http://127.0.0.1:{srv.server_address[1]}"

    yield start
    for srv in servers:
        srv.shutdown()
        srv.server_close()


@pytest.mark.parametrize("body", [
    b"not json",
    b'{"key": "a"}',
    b'[{"key": "a", "size": 1}]',
    b'[{"key": 1, "size": 1, "sha256": "x"}]',
    b"[null]",
])
def test_malformed_listing_fails_the_push(fake_server, local, body, capsys):
    assert push(local, fake_server(200, body)) == 1
    assert "listing blobs failed: malformed response from server" in capsys.readouterr().err


def test_listing_error_fails_the_push(fake_server, local, capsys):
    url = fake_server(500, b'{"error": "disk on fire"}')
    assert push(local, url) == 1
    assert "listing blobs failed: HTTP 500 Internal Server Error: disk on fire" in capsys.readouterr().err
