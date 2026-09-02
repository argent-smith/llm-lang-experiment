import os
import threading

import pytest
from werkzeug.serving import make_server

from client.sync import SyncError, sync
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


# --- direction: local-only file -> pushed to the server ----------------------


def test_sync_uploads_local_only_file(tmp_path, live_server):
    server_url, data_dir = live_server
    local = tmp_path / "local"
    local.mkdir()
    (local / "a.txt").write_bytes(b"local only")

    result = sync(str(local), server_url)

    assert result.uploaded == ["a.txt"]
    assert result.downloaded == []
    assert (data_dir / "a.txt").read_bytes() == b"local only"


def test_sync_uploads_nested_local_file_creating_dirs_on_server(tmp_path, live_server):
    server_url, data_dir = live_server
    local = tmp_path / "local"
    (local / "docs").mkdir(parents=True)
    (local / "docs" / "readme.txt").write_bytes(b"nested")

    result = sync(str(local), server_url)

    assert result.uploaded == ["docs/readme.txt"]
    assert (data_dir / "docs" / "readme.txt").read_bytes() == b"nested"


# --- direction: remote-only file -> pulled to the local directory ------------


def test_sync_downloads_remote_only_file(tmp_path, live_server):
    server_url, data_dir = live_server
    (data_dir / "a.txt").write_bytes(b"remote only")
    local = tmp_path / "local"
    local.mkdir()

    result = sync(str(local), server_url)

    assert result.downloaded == ["a.txt"]
    assert result.uploaded == []
    assert (local / "a.txt").read_bytes() == b"remote only"


def test_sync_downloads_nested_remote_file_creating_dirs_locally(tmp_path, live_server):
    server_url, data_dir = live_server
    (data_dir / "docs").mkdir()
    (data_dir / "docs" / "readme.txt").write_bytes(b"nested")
    local = tmp_path / "local"
    local.mkdir()

    result = sync(str(local), server_url)

    assert result.downloaded == ["docs/readme.txt"]
    assert (local / "docs" / "readme.txt").read_bytes() == b"nested"


# --- changed on one side only relative to the last sync -----------------------


def test_sync_local_only_change_is_pushed(tmp_path, live_server):
    server_url, data_dir = live_server
    local = tmp_path / "local"
    local.mkdir()
    (local / "a.txt").write_bytes(b"original")
    sync(str(local), server_url)  # establishes the common-state baseline

    (local / "a.txt").write_bytes(b"local edit")
    result = sync(str(local), server_url)

    assert result.uploaded == ["a.txt"]
    assert result.downloaded == []
    assert (data_dir / "a.txt").read_bytes() == b"local edit"


def test_sync_remote_only_change_is_pulled(tmp_path, live_server):
    server_url, data_dir = live_server
    local = tmp_path / "local"
    local.mkdir()
    (local / "a.txt").write_bytes(b"original")
    sync(str(local), server_url)  # establishes the common-state baseline

    (data_dir / "a.txt").write_bytes(b"remote edit")
    result = sync(str(local), server_url)

    assert result.downloaded == ["a.txt"]
    assert result.uploaded == []
    assert (local / "a.txt").read_bytes() == b"remote edit"


# --- conflict: changed on both sides since the last sync ----------------------


def test_sync_conflict_prefers_more_recent_mtime_local_wins(tmp_path, live_server):
    server_url, data_dir = live_server
    local = tmp_path / "local"
    local.mkdir()
    (local / "a.txt").write_bytes(b"original")
    sync(str(local), server_url)

    (data_dir / "a.txt").write_bytes(b"remote edit")
    os.utime(data_dir / "a.txt", (1_700_000_000, 1_700_000_000))
    (local / "a.txt").write_bytes(b"local edit")
    os.utime(local / "a.txt", (1_700_000_100, 1_700_000_100))

    result = sync(str(local), server_url)

    assert result.uploaded == ["a.txt"]
    assert result.downloaded == []
    assert (data_dir / "a.txt").read_bytes() == b"local edit"
    assert (local / "a.txt").read_bytes() == b"local edit"


def test_sync_conflict_prefers_more_recent_mtime_remote_wins(tmp_path, live_server):
    server_url, data_dir = live_server
    local = tmp_path / "local"
    local.mkdir()
    (local / "a.txt").write_bytes(b"original")
    sync(str(local), server_url)

    (local / "a.txt").write_bytes(b"local edit")
    os.utime(local / "a.txt", (1_700_000_000, 1_700_000_000))
    (data_dir / "a.txt").write_bytes(b"remote edit")
    os.utime(data_dir / "a.txt", (1_700_000_100, 1_700_000_100))

    result = sync(str(local), server_url)

    assert result.downloaded == ["a.txt"]
    assert result.uploaded == []
    assert (data_dir / "a.txt").read_bytes() == b"remote edit"
    assert (local / "a.txt").read_bytes() == b"remote edit"


def test_sync_conflict_with_equal_mtime_prefers_local(tmp_path, live_server):
    server_url, data_dir = live_server
    local = tmp_path / "local"
    local.mkdir()
    (local / "a.txt").write_bytes(b"original")
    sync(str(local), server_url)

    same_ts = 1_700_000_000
    (local / "a.txt").write_bytes(b"local edit")
    os.utime(local / "a.txt", (same_ts, same_ts))
    (data_dir / "a.txt").write_bytes(b"remote edit")
    os.utime(data_dir / "a.txt", (same_ts, same_ts))

    result = sync(str(local), server_url)

    assert result.uploaded == ["a.txt"]
    assert result.downloaded == []
    assert (data_dir / "a.txt").read_bytes() == b"local edit"
    assert (local / "a.txt").read_bytes() == b"local edit"


# --- sync never deletes -------------------------------------------------------


def test_sync_never_sends_delete(tmp_path, live_server, monkeypatch):
    server_url, data_dir = live_server
    (data_dir / "remote-only.txt").write_bytes(b"remote")
    local = tmp_path / "local"
    local.mkdir()
    (local / "local-only.txt").write_bytes(b"local")

    import requests

    original_request = requests.Session.request

    def guarded_request(self, method, url, *args, **kwargs):
        assert method.upper() != "DELETE", f"sync must not send DELETE to {url}"
        return original_request(self, method, url, *args, **kwargs)

    monkeypatch.setattr(requests.Session, "request", guarded_request)

    sync(str(local), server_url)

    assert (data_dir / "remote-only.txt").read_bytes() == b"remote"
    assert (local / "local-only.txt").read_bytes() == b"local"
    assert (local / "remote-only.txt").read_bytes() == b"remote"
    assert (data_dir / "local-only.txt").read_bytes() == b"local"


# --- error handling ------------------------------------------------------------


def test_sync_raises_syncerror_when_directory_missing(tmp_path):
    with pytest.raises(SyncError):
        sync(str(tmp_path / "does-not-exist"), "http://127.0.0.1:9")


def test_sync_raises_syncerror_when_server_unreachable(tmp_path):
    local = tmp_path / "local"
    local.mkdir()

    with pytest.raises(SyncError):
        sync(str(local), "http://127.0.0.1:1")
