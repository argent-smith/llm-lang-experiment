import threading

import pytest
from werkzeug.serving import make_server

from client.pull import PullError, files_to_download, pull
from server.app import create_app


@pytest.fixture
def live_server(tmp_path):
    data_dir = tmp_path / "data"
    data_dir.mkdir()
    app = create_app(str(data_dir))
    httpd = make_server("127.0.0.1", 0, app)
    thread = threading.Thread(target=httpd.serve_forever)
    thread.start()
    try:
        yield f"http://127.0.0.1:{httpd.server_port}", data_dir
    finally:
        httpd.shutdown()
        thread.join()


# --- files_to_download (pure diff logic, no HTTP) ---------------------------


def test_files_to_download_includes_missing_keys():
    remote = {"a.txt": "hash-a"}
    local = {}

    assert files_to_download(remote, local) == ["a.txt"]


def test_files_to_download_includes_changed_keys():
    remote = {"a.txt": "hash-a"}
    local = {"a.txt": "hash-old"}

    assert files_to_download(remote, local) == ["a.txt"]


def test_files_to_download_excludes_identical_keys():
    remote = {"a.txt": "hash-a"}
    local = {"a.txt": "hash-a"}

    assert files_to_download(remote, local) == []


def test_files_to_download_ignores_extra_local_keys():
    remote = {"a.txt": "hash-a"}
    local = {"a.txt": "hash-a", "b.txt": "hash-b"}

    assert files_to_download(remote, local) == []


def test_files_to_download_returns_sorted_keys():
    remote = {"z.txt": "1", "a.txt": "2", "m.txt": "3"}
    local = {}

    assert files_to_download(remote, local) == ["a.txt", "m.txt", "z.txt"]


# --- pull (end-to-end against a real HTTP server) ---------------------------


def test_pull_downloads_missing_file(tmp_path, live_server):
    server_url, data_dir = live_server
    (data_dir / "a.txt").write_bytes(b"hello")
    dest = tmp_path / "dest"
    dest.mkdir()

    result = pull(str(dest), server_url)

    assert result.downloaded == ["a.txt"]
    assert result.skipped == []
    assert (dest / "a.txt").read_bytes() == b"hello"


def test_pull_downloads_nested_key_as_posix_path(tmp_path, live_server):
    server_url, data_dir = live_server
    (data_dir / "docs").mkdir()
    (data_dir / "docs" / "readme.txt").write_bytes(b"nested")
    dest = tmp_path / "dest"
    dest.mkdir()

    result = pull(str(dest), server_url)

    assert result.downloaded == ["docs/readme.txt"]
    assert (dest / "docs" / "readme.txt").read_bytes() == b"nested"


def test_pull_skips_file_identical_to_local(tmp_path, live_server):
    server_url, data_dir = live_server
    (data_dir / "a.txt").write_bytes(b"same content")
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "a.txt").write_bytes(b"same content")

    result = pull(str(dest), server_url)

    assert result.downloaded == []
    assert result.skipped == ["a.txt"]


def test_pull_downloads_file_that_differs_from_local(tmp_path, live_server):
    server_url, data_dir = live_server
    (data_dir / "a.txt").write_bytes(b"new content")
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "a.txt").write_bytes(b"old content")

    result = pull(str(dest), server_url)

    assert result.downloaded == ["a.txt"]
    assert (dest / "a.txt").read_bytes() == b"new content"


def test_pull_only_downloads_changed_files_among_several(tmp_path, live_server):
    server_url, data_dir = live_server
    (data_dir / "unchanged.txt").write_bytes(b"stays the same")
    (data_dir / "changed.txt").write_bytes(b"after")
    (data_dir / "new.txt").write_bytes(b"brand new")
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "unchanged.txt").write_bytes(b"stays the same")
    (dest / "changed.txt").write_bytes(b"before")

    result = pull(str(dest), server_url)

    assert sorted(result.downloaded) == ["changed.txt", "new.txt"]
    assert result.skipped == ["unchanged.txt"]


def test_pull_does_not_delete_local_only_files(tmp_path, live_server):
    server_url, data_dir = live_server
    (data_dir / "a.txt").write_bytes(b"hello")
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "local-only.txt").write_bytes(b"keep me")

    pull(str(dest), server_url)

    assert (dest / "local-only.txt").read_bytes() == b"keep me"


def test_pull_empty_server_downloads_nothing(tmp_path, live_server):
    server_url, _ = live_server
    dest = tmp_path / "dest"
    dest.mkdir()

    result = pull(str(dest), server_url)

    assert result.downloaded == []
    assert result.skipped == []


def test_pull_raises_pullerror_when_directory_missing(tmp_path):
    with pytest.raises(PullError):
        pull(str(tmp_path / "does-not-exist"), "http://127.0.0.1:9")


def test_pull_raises_pullerror_when_server_unreachable(tmp_path):
    dest = tmp_path / "dest"
    dest.mkdir()

    with pytest.raises(PullError):
        pull(str(dest), "http://127.0.0.1:1")
