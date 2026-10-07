"""``syncbox pull`` against an in-process server, run through cli.main()."""

from __future__ import annotations

import json
import os
import socket
import stat
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from syncbox.client import api
from syncbox.client.cli import main
from syncbox.client.pull import is_safe_key

from .test_blobs import put
from .test_client_push import FILES, sha, url_of, write


@pytest.fixture
def local(tmp_path_factory) -> Path:
    """The directory to pull into (the server fixture's data dir is tmp_path)."""
    return tmp_path_factory.mktemp("local")


@pytest.fixture
def downloads(server, monkeypatch) -> list[str]:
    """Keys the server has served with GET /blobs/{key}, in order."""
    served: list[str] = []
    real_open = server.store.open

    def counting_open(key):
        served.append(key)
        return real_open(key)

    monkeypatch.setattr(server.store, "open", counting_open)
    return served


def pull(local: Path, server_url: str, *extra: str, env: dict[str, str] | None = None) -> int:
    return main(["pull", str(local), "--server", server_url, *extra], environ=env or {})


def seed(conn, files: dict[str, bytes]) -> None:
    for key, data in files.items():
        assert put(conn, key, data)[0] == 201


def tree(root: Path) -> dict[str, bytes]:
    """Every regular file under ``root`` by key, plus ``<dir>/`` for every directory."""
    found: dict[str, bytes] = {}
    for dirpath, dirnames, filenames in os.walk(root):
        rel = Path(dirpath).relative_to(root).as_posix()
        prefix = "" if rel == "." else rel + "/"
        for name in dirnames:
            found[prefix + name + "/"] = b""
        for name in filenames:
            path = Path(dirpath, name)
            if path.is_symlink():
                found[prefix + name] = b"<symlink>"
            elif not path.is_file():
                found[prefix + name] = b"<special>"  # e.g. a FIFO, which reading would block on
            else:
                found[prefix + name] = path.read_bytes()
    return found


def files_only(root: Path) -> dict[str, bytes]:
    return {key: data for key, data in tree(root).items() if not key.endswith("/")}


def assert_no_temp_files(root: Path) -> None:
    leftovers = [key for key in tree(root) if ".syncbox-" in key]
    assert leftovers == []


# --- what gets downloaded -----------------------------------------------------


def test_pull_downloads_every_blob_to_its_relative_posix_path(server, conn, local, downloads, capsys):
    seed(conn, FILES)

    assert pull(local, url_of(server)) == 0

    assert files_only(local) == FILES
    assert sorted(downloads) == sorted(FILES)
    out = capsys.readouterr().out.splitlines()
    assert out[:-1] == [f"added {key}" for key in sorted(FILES)]
    assert out[-1] == f"{len(FILES)} downloaded, 0 already up to date"
    assert_no_temp_files(local)


def test_large_blob_is_downloaded_intact(server, conn, local):
    data = os.urandom(3 * 1024 * 1024 + 17)
    seed(conn, {"big/blob.bin": data})

    assert pull(local, url_of(server)) == 0

    assert sha((local / "big" / "blob.bin").read_bytes()) == sha(data)


def test_second_pull_downloads_nothing(server, conn, local, downloads, capsys):
    seed(conn, FILES)
    assert pull(local, url_of(server)) == 0
    downloads.clear()
    capsys.readouterr()

    assert pull(local, url_of(server)) == 0

    assert downloads == []
    assert capsys.readouterr().out == f"0 downloaded, {len(FILES)} already up to date\n"


def test_only_missing_and_changed_files_are_downloaded(server, conn, local, downloads, capsys):
    seed(conn, FILES)
    assert pull(local, url_of(server)) == 0
    downloads.clear()
    capsys.readouterr()

    seed(conn, {"docs/readme.txt": b"changed on the server", "new/file": b"new"})
    (local / "top.txt").unlink()
    assert pull(local, url_of(server)) == 0

    assert sorted(downloads) == ["docs/readme.txt", "new/file", "top.txt"]
    assert files_only(local) == {**FILES, "docs/readme.txt": b"changed on the server", "new/file": b"new"}
    assert capsys.readouterr().out.splitlines() == [
        "updated docs/readme.txt",
        "added new/file",
        "added top.txt",
        f"3 downloaded, {len(FILES) - 2} already up to date",
    ]


def test_comparison_is_by_content_not_by_time_or_size(server, conn, local, downloads):
    seed(conn, {"same": b"same content", "newer": b"server version", "same-size": b"server"})
    # Identical bytes with an old mtime are left alone ...
    write(local, {"same": b"same content", "newer": b"local version", "same-size": b"localx"})
    os.utime(local / "same", (1, 1))
    # ... and a different version is replaced even if it is newer, or the same size.
    future = time.time() + 3600
    os.utime(local / "newer", (future, future))
    os.utime(local / "same-size", (future, future))

    assert pull(local, url_of(server)) == 0

    assert sorted(downloads) == ["newer", "same-size"]
    assert files_only(local) == {"same": b"same content", "newer": b"server version", "same-size": b"server"}


def test_local_files_missing_on_the_server_are_kept(server, conn, local):
    seed(conn, {"docs/remote": b"remote"})
    write(local, {"local-only": b"keep me", "docs/local-only": b"me too"})
    (local / "empty-dir").mkdir()

    assert pull(local, url_of(server)) == 0

    assert tree(local) == {
        "docs/": b"",
        "empty-dir/": b"",
        "local-only": b"keep me",
        "docs/local-only": b"me too",
        "docs/remote": b"remote",
    }


def test_empty_server_downloads_nothing(server, local, capsys):
    write(local, {"a": b"a"})
    assert pull(local, url_of(server)) == 0
    assert files_only(local) == {"a": b"a"}
    assert capsys.readouterr().out == "0 downloaded, 0 already up to date\n"


def test_updated_file_keeps_its_permissions(server, conn, local):
    seed(conn, {"script": b"#!/bin/sh\necho new\n", "new": b"new"})
    write(local, {"script": b"#!/bin/sh\necho old\n"})
    (local / "script").chmod(0o750)

    assert pull(local, url_of(server)) == 0

    assert (local / "script").read_bytes() == b"#!/bin/sh\necho new\n"
    assert stat.S_IMODE((local / "script").stat().st_mode) == 0o750
    umask = os.umask(0)
    os.umask(umask)
    assert stat.S_IMODE((local / "new").stat().st_mode) == 0o666 & ~umask


def test_replacing_a_file_does_not_write_through_a_hard_link(server, conn, local, tmp_path_factory):
    # The file is renamed over, not rewritten: another name for the old file keeps the old bytes.
    other = tmp_path_factory.mktemp("other") / "linked"
    write(local, {"f": b"old"})
    os.link(local / "f", other)
    seed(conn, {"f": b"new"})

    assert pull(local, url_of(server)) == 0

    assert (local / "f").read_bytes() == b"new"
    assert other.read_bytes() == b"old"


def test_pull_then_push_round_trip(server, conn, local, tmp_path_factory):
    source = tmp_path_factory.mktemp("source")
    write(source, FILES)
    assert main(["push", str(source), "--server", url_of(server)], environ={}) == 0

    assert pull(local, url_of(server)) == 0

    assert files_only(local) == files_only(source)


def test_dir_given_as_symlink_is_followed(server, conn, local, tmp_path_factory):
    seed(conn, {"sub/a": b"a"})
    link = tmp_path_factory.mktemp("links") / "link"
    link.symlink_to(local, target_is_directory=True)

    assert pull(link, url_of(server)) == 0
    assert files_only(local) == {"sub/a": b"a"}


def test_relative_dir(server, conn, local, monkeypatch):
    seed(conn, {"sub/a": b"a"})
    monkeypatch.chdir(local.parent)

    assert main(["pull", local.name, "--server", url_of(server)], environ={}) == 0
    assert files_only(local) == {"sub/a": b"a"}


# --- symlinks and other things in the way ------------------------------------------


def test_symlink_at_a_key_is_skipped_with_a_warning(server, conn, local, tmp_path_factory, capsys):
    outside = tmp_path_factory.mktemp("outside")
    write(outside, {"target": b"outside the pulled directory"})
    (local / "link").symlink_to(outside / "target")
    (local / "dangling").symlink_to(outside / "missing")
    seed(conn, {"link": b"from the server", "dangling": b"from the server", "other": b"other"})

    assert pull(local, url_of(server)) == 0

    assert (outside / "target").read_bytes() == b"outside the pulled directory"
    assert not (outside / "missing").exists()
    assert (local / "link").is_symlink() and (local / "dangling").is_symlink()
    assert (local / "other").read_bytes() == b"other"
    captured = capsys.readouterr()
    assert "skipping 'link': symbolic link" in captured.err
    assert "skipping 'dangling': symbolic link" in captured.err
    assert captured.out.splitlines()[-1] == "1 downloaded, 0 already up to date"


def test_symlinked_directory_in_a_key_is_not_followed(server, conn, local, tmp_path_factory, capsys):
    outside = tmp_path_factory.mktemp("outside")
    (local / "docs").symlink_to(outside, target_is_directory=True)
    (local / "real").mkdir()
    (local / "real" / "deeper").symlink_to(outside, target_is_directory=True)
    seed(conn, {"docs/escape": b"x", "real/deeper/escape": b"y", "real/fine": b"z"})

    assert pull(local, url_of(server)) == 0

    assert list(outside.iterdir()) == []
    assert (local / "real" / "fine").read_bytes() == b"z"
    err = capsys.readouterr().err
    assert "skipping 'docs/escape': 'docs' is a symbolic link" in err
    assert "skipping 'real/deeper/escape': 'real/deeper' is a symbolic link" in err


def test_special_file_at_a_key_is_skipped_with_a_warning(server, conn, local, capsys):
    os.mkfifo(local / "fifo")
    seed(conn, {"fifo": b"data"})

    assert pull(local, url_of(server)) == 0

    assert stat.S_ISFIFO(os.lstat(local / "fifo").st_mode)
    assert "skipping 'fifo': not a regular file" in capsys.readouterr().err


def test_directory_at_a_key_fails_the_pull(server, conn, local, capsys):
    (local / "a").mkdir()
    (local / "a" / "inside").write_bytes(b"keep")
    seed(conn, {"a": b"file"})

    assert pull(local, url_of(server)) == 1

    assert "syncbox: error: cannot write 'a': a directory is in the way" in capsys.readouterr().err
    assert tree(local) == {"a/": b"", "a/inside": b"keep"}


def test_file_in_place_of_a_directory_fails_the_pull(server, conn, local, capsys):
    write(local, {"a": b"a file"})
    seed(conn, {"a/b/c": b"nested"})

    assert pull(local, url_of(server)) == 1

    assert "syncbox: error: cannot write 'a/b/c': 'a' is not a directory" in capsys.readouterr().err
    assert tree(local) == {"a": b"a file"}


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes files regardless of permissions")
def test_unwritable_directory_fails_the_pull(server, conn, local, capsys):
    (local / "ro").mkdir()
    seed(conn, {"ro/file": b"x"})
    (local / "ro").chmod(0o555)
    try:
        assert pull(local, url_of(server)) == 1
    finally:
        (local / "ro").chmod(0o755)
    assert "syncbox: error: cannot write 'ro/file': Permission denied" in capsys.readouterr().err


# --- --server and SYNCBOX_SERVER ----------------------------------------------


def test_server_from_environment(server, conn, local):
    seed(conn, {"a": b"a"})
    assert main(["pull", str(local)], environ={"SYNCBOX_SERVER": url_of(server)}) == 0
    assert files_only(local) == {"a": b"a"}


def test_flag_overrides_environment(server, conn, local):
    seed(conn, {"a": b"a"})
    assert pull(local, url_of(server), env={"SYNCBOX_SERVER": "http://127.0.0.1:1"}) == 0
    assert files_only(local) == {"a": b"a"}


@pytest.mark.parametrize("env", [{}, {"SYNCBOX_SERVER": ""}])
def test_missing_server_is_a_usage_error(local, env, capsys):
    assert main(["pull", str(local)], environ=env) == 2
    assert "server URL is required: pass --server or set SYNCBOX_SERVER" in capsys.readouterr().err


def test_invalid_server_url_is_a_usage_error(local, capsys):
    assert pull(local, "ftp://127.0.0.1:8080") == 2
    assert "'ftp://127.0.0.1:8080'" in capsys.readouterr().err


def test_missing_dir(server, tmp_path, capsys):
    assert pull(tmp_path / "nope", url_of(server)) == 1
    assert "does not exist" in capsys.readouterr().err
    assert not (tmp_path / "nope").exists()


def test_dir_is_a_file(server, tmp_path, capsys):
    (tmp_path / "file").write_bytes(b"x")
    assert pull(tmp_path / "file", url_of(server)) == 1
    assert "is not a directory" in capsys.readouterr().err


# --- failures -----------------------------------------------------------------


def test_unreachable_server_fails_quickly(local, capsys):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]  # nothing listens here once closed
    start = time.monotonic()

    assert pull(local, f"http://127.0.0.1:{port}") == 1

    assert time.monotonic() - start < 5
    err = capsys.readouterr().err
    assert f"syncbox: error: cannot reach server http://127.0.0.1:{port}: Connection refused" in err
    assert tree(local) == {}


def test_silent_server_times_out(local, monkeypatch, capsys):
    monkeypatch.setattr(api, "READ_TIMEOUT", 0.5)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()  # accepts connections (in the backlog) but never answers
        port = listener.getsockname()[1]
        assert pull(local, f"http://127.0.0.1:{port}") == 1
    assert "timed out" in capsys.readouterr().err


def test_blob_deleted_after_listing_is_skipped_with_a_warning(server, conn, local, monkeypatch, capsys):
    seed(conn, {"gone": b"gone", "kept": b"kept"})
    real_open = server.store.open
    monkeypatch.setattr(server.store, "open", lambda key: None if key == "gone" else real_open(key))

    assert pull(local, url_of(server)) == 0

    assert tree(local) == {"kept": b"kept"}
    captured = capsys.readouterr()
    assert "skipping 'gone': no longer on the server" in captured.err
    assert captured.out.splitlines() == ["added kept", "1 downloaded, 0 already up to date"]


def test_interrupted_download_leaves_the_old_file(server, conn, local, monkeypatch, capsys):
    seed(conn, {"f": b"new" * 100_000})
    write(local, {"f": b"old"})
    real_get_blob = api.ServerClient.get_blob

    def interrupted(self, key, size, sink):
        def failing_sink(chunk):
            sink(chunk)
            raise KeyboardInterrupt

        return real_get_blob(self, key, size, failing_sink)

    monkeypatch.setattr(api.ServerClient, "get_blob", interrupted)

    assert pull(local, url_of(server)) == 130

    assert tree(local) == {"f": b"old"}
    assert "syncbox: error: interrupted" in capsys.readouterr().err


# --- responses from a misbehaving server ---------------------------------------


class _FakeHandler(BaseHTTPRequestHandler):
    """Answers GET requests from ``routes``: path -> (status, body, headers)."""

    protocol_version = "HTTP/1.1"
    routes: dict[str, tuple[int, bytes, dict[str, str]]] = {}

    def do_GET(self):
        status, body, headers = self.routes.get(self.path, (404, b'{"error": "not found"}', {}))
        self.send_response(status)
        headers = {"Content-Length": str(len(body)), **headers}
        for name, value in headers.items():
            if value is not None:  # None drops a default header
                self.send_header(name, value)
        self.end_headers()
        if headers.get("Transfer-Encoding") == "chunked":
            self.wfile.write(b"%x\r\n%s\r\n0\r\n\r\n" % (len(body), body))
        else:
            self.wfile.write(body)

    def log_message(self, *args):
        pass


@pytest.fixture
def fake_server():
    """Start a server answering GET requests from a routing table; returns its URL."""
    servers = []

    def start(routes: dict[str, tuple[int, bytes, dict[str, str]]]) -> str:
        handler = type("Handler", (_FakeHandler,), {"routes": routes})
        srv = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        servers.append(srv)
        return f"http://127.0.0.1:{srv.server_address[1]}"

    yield start
    for srv in servers:
        srv.shutdown()
        srv.server_close()


def listing(**blobs: bytes) -> tuple[int, bytes, dict[str, str]]:
    return 200, json.dumps([
        {"key": key, "size": len(data), "sha256": sha(data), "modified_at": "2026-01-01T00:00:00Z"}
        for key, data in blobs.items()
    ]).encode(), {"Content-Type": "application/json"}


@pytest.mark.parametrize("key", [
    "../escape",
    "a/../../escape",
    "/etc/passwd",
    "./a",
    "a//b",
    "a/",
    "",
    "nul\0byte",
    "lone\ud800surrogate",
])
def test_unsafe_key_in_listing_is_a_failure_and_not_downloaded(fake_server, local, key, capsys):
    body = json.dumps([
        {"key": key, "size": 1, "sha256": sha(b"x"), "modified_at": "2026-01-01T00:00:00Z"},
        {"key": "fine", "size": 1, "sha256": sha(b"x"), "modified_at": "2026-01-01T00:00:00Z"},
    ]).encode()
    url = fake_server({"/blobs": (200, body, {}), "/blobs/fine": (200, b"x", {})})

    assert pull(local, url) == 1

    captured = capsys.readouterr()
    assert f"server listed an invalid key {key!r}; not downloaded" in captured.err
    assert captured.out.splitlines()[-1] == "1 downloaded, 0 already up to date, 1 failed"
    # Nothing is written for the bad key, the other blob is downloaded all the same.
    assert tree(local) == {"fine": b"x"}


def test_is_safe_key():
    assert is_safe_key("a")
    assert is_safe_key("docs/deep/file.txt")
    assert is_safe_key("...")
    assert is_safe_key(".hidden/..x/x..")
    assert is_safe_key("back\\slash")
    for key in ["", "/", "/a", "a/", "a//b", ".", "..", "a/./b", "a/..", "\0", "a\ud800"]:
        assert not is_safe_key(key), key


def test_malformed_listing_fails_the_pull(fake_server, local, capsys):
    assert pull(local, fake_server({"/blobs": (200, b"[{}]", {})})) == 1
    assert "listing blobs failed: malformed response from server" in capsys.readouterr().err


def test_download_error_fails_the_pull_and_keeps_the_old_file(fake_server, local, capsys):
    write(local, {"a": b"old"})
    url = fake_server({
        "/blobs": listing(a=b"new"),
        "/blobs/a": (500, b'{"error": "disk on fire"}', {}),
    })

    assert pull(local, url) == 1

    assert "syncbox: error: cannot download 'a': HTTP 500 Internal Server Error: disk on fire" in capsys.readouterr().err
    assert tree(local) == {"a": b"old"}


CHUNKED = {"Transfer-Encoding": "chunked", "Content-Length": None}


@pytest.mark.parametrize("served, headers, message", [
    (b"other", {}, f"received sha256 {sha(b'other')}, listed {sha(b'right')}"),
    (b"longer body", {}, "server sent 11 bytes, listed 5"),
    (b"righ", {}, "server sent 4 bytes, listed 5"),
    (b"right and more", CHUNKED, "server sent more than the 5 bytes listed"),
    (b"righ", CHUNKED, "body ended after 4 of 5 bytes"),
])
def test_body_not_matching_the_listing_fails_the_pull(fake_server, local, served, headers, message, capsys):
    write(local, {"a": b"old"})
    url = fake_server({"/blobs": listing(a=b"right"), "/blobs/a": (200, served, headers)})

    assert pull(local, url) == 1

    assert f"syncbox: error: cannot download 'a': {message}" in capsys.readouterr().err
    assert tree(local) == {"a": b"old"}


def test_truncated_body_fails_the_pull(local, capsys):
    # Promises 5 bytes, sends 3 and closes the connection.
    listing_body = listing(a=b"right")[1]
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        port = listener.getsockname()[1]

        def serve():
            for _ in range(2):
                sock, _addr = listener.accept()
                with sock:
                    request = sock.recv(65536)
                    if request.startswith(b"GET /blobs "):
                        sock.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
                                     % (len(listing_body), listing_body))
                    else:
                        sock.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nrig")

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        assert pull(local, f"http://127.0.0.1:{port}") == 1
        thread.join(5)

    err = capsys.readouterr().err
    assert "syncbox: error: cannot download 'a': " in err
    assert tree(local) == {}
