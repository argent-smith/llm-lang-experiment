"""``syncbox status`` against an in-process server, run through cli.main()."""

from __future__ import annotations

import json
import os
import socket
import time
from pathlib import Path

import pytest

from syncbox.client.cli import main

from .test_blobs import list_blobs
from .test_client_pull import fake_server, seed  # noqa: F401 (fake_server is a fixture)
from .test_client_push import FILES, sha, url_of, write


@pytest.fixture
def local(tmp_path_factory) -> Path:
    """The directory to compare (the server fixture's data dir is tmp_path)."""
    return tmp_path_factory.mktemp("local")


@pytest.fixture
def requests(server, monkeypatch) -> list[tuple[str, str]]:
    """(method, path) of every request the server has received, in order."""
    received: list[tuple[str, str]] = []
    handler = server.RequestHandlerClass
    real_dispatch = handler._dispatch

    def recording_dispatch(self):
        received.append((self.command, self.path))
        real_dispatch(self)

    monkeypatch.setattr(handler, "_dispatch", recording_dispatch)
    return received


def status(local: Path, server_url: str, env: dict[str, str] | None = None) -> int:
    return main(["status", str(local), "--server", server_url], environ=env or {})


def snapshot(root: Path) -> dict[str, tuple]:
    """Everything under ``root`` that a change would show in: type, mode, mtime, content."""
    found: dict[str, tuple] = {}
    for dirpath, dirnames, filenames in os.walk(root):
        for name in [*dirnames, *filenames]:
            path = Path(dirpath, name)
            st = path.lstat()
            content = path.read_bytes() if path.is_file() and not path.is_symlink() else None
            link = os.readlink(path) if path.is_symlink() else None
            found[path.relative_to(root).as_posix()] = (st.st_mode, st.st_mtime_ns, st.st_size, content, link)
    st = root.lstat()
    found["."] = (st.st_mode, st.st_mtime_ns)
    return found


def report(out: str) -> list[str]:
    """The per-file lines of status output, without the summary."""
    return out.splitlines()[:-1]


# --- what status reports ------------------------------------------------------


def test_file_only_present_locally_would_be_uploaded(server, conn, local, capsys):
    write(local, {"docs/new.txt": b"local only"})

    assert status(local, url_of(server)) == 0

    assert capsys.readouterr().out == (
        "upload    new      docs/new.txt\n"
        "1 to upload, 0 to download, 0 up to date\n"
    )


def test_file_only_present_on_the_server_would_be_downloaded(server, conn, local, capsys):
    seed(conn, {"docs/remote.txt": b"server only"})

    assert status(local, url_of(server)) == 0

    assert capsys.readouterr().out == (
        "download  new      docs/remote.txt\n"
        "0 to upload, 1 to download, 0 up to date\n"
    )


def test_file_that_differs_is_listed_in_both_directions(server, conn, local, capsys):
    # push would upload the local version and pull would download the server's.
    seed(conn, {"notes.txt": b"server version"})
    write(local, {"notes.txt": b"local version"})

    assert status(local, url_of(server)) == 0

    assert capsys.readouterr().out == (
        "upload    changed  notes.txt\n"
        "download  changed  notes.txt\n"
        "1 to upload, 1 to download, 0 up to date\n"
    )


def test_identical_files_are_up_to_date(server, conn, local, capsys):
    seed(conn, FILES)
    write(local, FILES)

    assert status(local, url_of(server)) == 0

    assert capsys.readouterr().out == f"nothing to upload or download, {len(FILES)} up to date\n"


def test_empty_directory_and_empty_server(server, local, capsys):
    assert status(local, url_of(server)) == 0
    assert capsys.readouterr().out == "nothing to upload or download, 0 up to date\n"


def test_mixed_tree(server, conn, local, capsys):
    seed(conn, {**FILES, "docs/readme.txt": b"changed on the server", "remote/only": b"r"})
    write(local, {**FILES, "local/only": b"l"})
    (local / "top.txt").unlink()

    assert status(local, url_of(server)) == 0

    out = capsys.readouterr().out
    assert report(out) == [
        "upload    changed  docs/readme.txt",
        "upload    new      local/only",
        "download  changed  docs/readme.txt",
        "download  new      remote/only",
        "download  new      top.txt",
    ]
    assert out.splitlines()[-1] == f"2 to upload, 3 to download, {len(FILES) - 2} up to date"


def test_keys_are_relative_posix_paths(server, conn, local, capsys):
    # The same files on both sides are matched by key, odd names and nesting included.
    seed(conn, FILES)
    write(local, FILES)
    (local / "docs" / "deep" / "nested" / "data.bin").write_bytes(b"different")

    assert status(local, url_of(server)) == 0

    assert report(capsys.readouterr().out) == [
        "upload    changed  docs/deep/nested/data.bin",
        "download  changed  docs/deep/nested/data.bin",
    ]


def test_comparison_is_by_content_not_by_time_or_size(server, conn, local, capsys):
    seed(conn, {"same": b"same content", "same-size": b"server"})
    write(local, {"same": b"same content", "same-size": b"localx"})
    os.utime(local / "same", (1, 1))
    future = time.time() + 3600
    os.utime(local / "same-size", (future, future))

    assert status(local, url_of(server)) == 0

    assert report(capsys.readouterr().out) == [
        "upload    changed  same-size",
        "download  changed  same-size",
    ]


def test_status_agrees_with_what_push_and_pull_then_do(server, conn, local, capsys):
    seed(conn, {"both": b"server", "remote": b"r", "same": b"s"})
    write(local, {"both": b"local", "local": b"l", "same": b"s"})

    assert status(local, url_of(server)) == 0
    lines = report(capsys.readouterr().out)
    would_upload = [line.split()[-1] for line in lines if line.startswith("upload")]
    would_download = [line.split()[-1] for line in lines if line.startswith("download")]

    assert main(["push", str(local), "--server", url_of(server)], environ={}) == 0
    pushed = report(capsys.readouterr().out)
    assert [line.split()[-1] for line in pushed] == would_upload

    # After the push the server has the local version of "both", so set it back to see the pull.
    seed(conn, {"both": b"server"})
    assert main(["pull", str(local), "--server", url_of(server)], environ={}) == 0
    pulled = report(capsys.readouterr().out)
    assert [line.split()[-1] for line in pulled] == would_download


def test_symlinks_and_special_files_are_skipped_with_a_warning(server, conn, local, tmp_path_factory, capsys):
    outside = tmp_path_factory.mktemp("outside")
    write(outside, {"target": b"outside"})
    (local / "link").symlink_to(outside / "target")
    (local / "linked-dir").symlink_to(outside, target_is_directory=True)
    os.mkfifo(local / "fifo")
    write(local, {"real": b"real"})

    assert status(local, url_of(server)) == 0

    captured = capsys.readouterr()
    assert captured.out == "upload    new      real\n1 to upload, 0 to download, 0 up to date\n"
    assert "skipping 'link': symbolic link" in captured.err
    assert "skipping 'linked-dir': symbolic link" in captured.err
    assert "skipping 'fifo': not a regular file" in captured.err


# --- status changes nothing -----------------------------------------------------


def test_status_changes_neither_the_server_nor_the_directory(server, conn, local, tmp_path, requests, capsys):
    seed(conn, {"both": b"server", "remote/only": b"r", "same": b"s"})
    write(local, {"both": b"local", "local/only": b"l", "same": b"s"})
    (local / "empty-dir").mkdir()
    (local / "link").symlink_to("same")
    os.mkfifo(local / "fifo")
    os.utime(local / "both", (1, 1))
    data_dir = tmp_path  # the server fixture's
    local_before, server_before = snapshot(local), snapshot(data_dir)
    blobs_before = list_blobs(conn)
    requests.clear()

    assert status(local, url_of(server)) == 0

    assert requests == [("GET", "/blobs")]
    assert snapshot(local) == local_before
    assert snapshot(data_dir) == server_before
    assert list_blobs(conn) == blobs_before
    assert "upload    new      local/only" in capsys.readouterr().out


def test_repeated_status_reports_the_same(server, conn, local, capsys):
    seed(conn, {"both": b"server", "remote": b"r"})
    write(local, {"both": b"local", "local": b"l"})

    assert status(local, url_of(server)) == 0
    first = capsys.readouterr().out
    assert status(local, url_of(server)) == 0
    assert capsys.readouterr().out == first


def test_invalid_key_on_the_server_is_reported_but_not_listed(fake_server, local, capsys):
    body = json.dumps([
        {"key": "fine", "size": 1, "sha256": sha(b"x"), "modified_at": "2026-01-01T00:00:00Z"},
        {"key": "../escape", "size": 1, "sha256": sha(b"x"), "modified_at": "2026-01-01T00:00:00Z"},
    ]).encode()
    url = fake_server({"/blobs": (200, body, {})})

    assert status(local, url) == 0

    captured = capsys.readouterr()
    assert captured.out == "download  new      fine\n0 to upload, 1 to download, 0 up to date\n"
    assert "server lists an invalid key '../escape'; pull would refuse to download it" in captured.err
    assert list(local.iterdir()) == []


# --- --server and SYNCBOX_SERVER ----------------------------------------------


def test_server_from_environment(server, conn, local, capsys):
    seed(conn, {"a": b"a"})
    assert main(["status", str(local)], environ={"SYNCBOX_SERVER": url_of(server)}) == 0
    assert report(capsys.readouterr().out) == ["download  new      a"]


def test_flag_overrides_environment(server, conn, local, capsys):
    seed(conn, {"a": b"a"})
    assert status(local, url_of(server), env={"SYNCBOX_SERVER": "http://127.0.0.1:1"}) == 0
    assert report(capsys.readouterr().out) == ["download  new      a"]


@pytest.mark.parametrize("env", [{}, {"SYNCBOX_SERVER": ""}])
def test_missing_server_is_a_usage_error(local, env, capsys):
    assert main(["status", str(local)], environ=env) == 2
    assert "server URL is required: pass --server or set SYNCBOX_SERVER" in capsys.readouterr().err


def test_missing_dir(server, tmp_path, capsys):
    assert status(tmp_path / "nope", url_of(server)) == 1
    assert "does not exist" in capsys.readouterr().err
    assert not (tmp_path / "nope").exists()


# --- failures -----------------------------------------------------------------


def test_unreachable_server_fails_quickly(local, capsys):
    write(local, {"a": b"a"})
    before = snapshot(local)
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]  # nothing listens here once closed
    start = time.monotonic()

    assert status(local, f"http://127.0.0.1:{port}") == 1

    assert time.monotonic() - start < 5
    captured = capsys.readouterr()
    assert f"syncbox: error: cannot reach server http://127.0.0.1:{port}: Connection refused" in captured.err
    assert captured.out == ""
    assert snapshot(local) == before


def test_listing_error_fails_the_status(fake_server, local, capsys):
    url = fake_server({"/blobs": (500, b'{"error": "disk on fire"}', {})})
    assert status(local, url) == 1
    assert "listing blobs failed: HTTP 500 Internal Server Error: disk on fire" in capsys.readouterr().err


def test_malformed_listing_fails_the_status(fake_server, local, capsys):
    assert status(local, fake_server({"/blobs": (200, b"[{}]", {})})) == 1
    assert "listing blobs failed: malformed response from server" in capsys.readouterr().err


@pytest.mark.skipif(os.geteuid() == 0, reason="root reads files regardless of permissions")
def test_unreadable_file_fails_the_status(server, conn, local, capsys):
    write(local, {"secret": b"x"})
    (local / "secret").chmod(0)

    assert status(local, url_of(server)) == 1

    assert "cannot read 'secret': Permission denied" in capsys.readouterr().err
    assert list_blobs(conn) == []
