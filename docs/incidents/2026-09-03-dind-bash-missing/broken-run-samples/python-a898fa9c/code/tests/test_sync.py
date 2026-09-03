import os
import threading

import pytest
from werkzeug.serving import make_server

from client.sync import STATE_FILENAME, SyncError, plan_sync, sync
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


def set_mtime(path, epoch):
    os.utime(path, (epoch, epoch))


# --- plan_sync (pure decision logic, no HTTP) --------------------------------


def test_plan_sync_uploads_local_only_key():
    to_upload, to_download, entries = plan_sync(
        {"a.txt": "sha-a"}, {"a.txt": 100}, {}, {}
    )

    assert to_upload == ["a.txt"]
    assert to_download == []
    assert entries == {"a.txt": "sha-a"}


def test_plan_sync_downloads_remote_only_key():
    remote = {"a.txt": {"sha256": "sha-a", "modified_at": "2024-01-01T00:00:00Z"}}

    to_upload, to_download, entries = plan_sync({}, {}, remote, {})

    assert to_download == ["a.txt"]
    assert to_upload == []
    assert entries == {"a.txt": "sha-a"}


def test_plan_sync_leaves_identical_key_alone():
    remote = {"a.txt": {"sha256": "sha-a", "modified_at": "2024-01-01T00:00:00Z"}}

    to_upload, to_download, entries = plan_sync(
        {"a.txt": "sha-a"}, {"a.txt": 100}, remote, {}
    )

    assert to_upload == []
    assert to_download == []
    assert entries == {"a.txt": "sha-a"}


def test_plan_sync_no_baseline_divergence_uploads_local_without_mtime():
    # Both sides already have the key with different content and no known
    # common state -- not a conflict per SYNCBOX-SPEC.md, resolved as a
    # plain upload regardless of mtime (remote mtime is far newer here).
    remote = {"a.txt": {"sha256": "sha-remote", "modified_at": "2099-01-01T00:00:00Z"}}

    to_upload, to_download, entries = plan_sync(
        {"a.txt": "sha-local"}, {"a.txt": 1}, remote, {}
    )

    assert to_upload == ["a.txt"]
    assert to_download == []
    assert entries == {"a.txt": "sha-local"}


def test_plan_sync_uploads_when_only_local_changed_since_baseline():
    remote = {"a.txt": {"sha256": "sha-base", "modified_at": "2024-01-01T00:00:00Z"}}
    base = {"a.txt": "sha-base"}

    to_upload, to_download, entries = plan_sync(
        {"a.txt": "sha-local"}, {"a.txt": 100}, remote, base
    )

    assert to_upload == ["a.txt"]
    assert to_download == []
    assert entries == {"a.txt": "sha-local"}


def test_plan_sync_downloads_when_only_remote_changed_since_baseline():
    remote = {"a.txt": {"sha256": "sha-remote", "modified_at": "2024-01-01T00:00:00Z"}}
    base = {"a.txt": "sha-base"}

    to_upload, to_download, entries = plan_sync(
        {"a.txt": "sha-base"}, {"a.txt": 100}, remote, base
    )

    assert to_download == ["a.txt"]
    assert to_upload == []
    assert entries == {"a.txt": "sha-remote"}


def test_plan_sync_conflict_prefers_fresher_remote():
    remote = {"a.txt": {"sha256": "sha-remote", "modified_at": "2024-01-01T00:00:10Z"}}
    base = {"a.txt": "sha-base"}

    to_upload, to_download, entries = plan_sync(
        {"a.txt": "sha-local"}, {"a.txt": 0}, remote, base
    )

    assert to_download == ["a.txt"]
    assert to_upload == []
    assert entries == {"a.txt": "sha-remote"}


def test_plan_sync_conflict_prefers_fresher_local():
    remote = {"a.txt": {"sha256": "sha-remote", "modified_at": "2024-01-01T00:00:00Z"}}
    base = {"a.txt": "sha-base"}

    to_upload, to_download, entries = plan_sync(
        {"a.txt": "sha-local"}, {"a.txt": 1_800_000_000}, remote, base
    )

    assert to_upload == ["a.txt"]
    assert to_download == []
    assert entries == {"a.txt": "sha-local"}


def test_plan_sync_conflict_with_equal_mtime_prefers_local():
    remote = {"a.txt": {"sha256": "sha-remote", "modified_at": "2024-01-01T00:00:00Z"}}
    base = {"a.txt": "sha-base"}

    to_upload, to_download, entries = plan_sync(
        {"a.txt": "sha-local"}, {"a.txt": 1704067200}, remote, base
    )

    assert to_upload == ["a.txt"]
    assert to_download == []
    assert entries == {"a.txt": "sha-local"}


# --- sync (end-to-end against a real HTTP server) ----------------------------


def test_sync_uploads_local_only_file(tmp_path, live_server):
    server_url, data_dir = live_server
    local = tmp_path / "local"
    local.mkdir()
    (local / "a.txt").write_bytes(b"local only")

    result = sync(str(local), server_url)

    assert result.uploaded == ["a.txt"]
    assert result.downloaded == []
    assert (data_dir / "a.txt").read_bytes() == b"local only"


def test_sync_downloads_remote_only_file(tmp_path, live_server):
    server_url, data_dir = live_server
    (data_dir / "a.txt").write_bytes(b"remote only")
    local = tmp_path / "local"
    local.mkdir()

    result = sync(str(local), server_url)

    assert result.downloaded == ["a.txt"]
    assert result.uploaded == []
    assert (local / "a.txt").read_bytes() == b"remote only"


def test_sync_downloads_nested_key_creating_subdirectories(tmp_path, live_server):
    server_url, data_dir = live_server
    (data_dir / "docs").mkdir()
    (data_dir / "docs" / "readme.txt").write_bytes(b"nested")
    local = tmp_path / "local"
    local.mkdir()

    result = sync(str(local), server_url)

    assert result.downloaded == ["docs/readme.txt"]
    assert (local / "docs" / "readme.txt").read_bytes() == b"nested"


def test_sync_does_not_sync_its_own_state_file(tmp_path, live_server):
    server_url, data_dir = live_server
    local = tmp_path / "local"
    local.mkdir()
    (local / "a.txt").write_bytes(b"hello")

    sync(str(local), server_url)

    assert (local / STATE_FILENAME).is_file()
    assert STATE_FILENAME not in {entry["key"] for entry in _list_blobs(server_url)}


def _list_blobs(server_url):
    import requests

    return requests.get(f"{server_url}/blobs").json()


def test_sync_pushes_locally_modified_file_after_baseline(tmp_path, live_server):
    server_url, data_dir = live_server
    local = tmp_path / "local"
    local.mkdir()
    (local / "a.txt").write_bytes(b"shared")

    sync(str(local), server_url)  # establish a common baseline

    (local / "a.txt").write_bytes(b"local edit")

    result = sync(str(local), server_url)

    assert result.uploaded == ["a.txt"]
    assert result.downloaded == []
    assert (data_dir / "a.txt").read_bytes() == b"local edit"


def test_sync_pulls_remotely_modified_file_after_baseline(tmp_path, live_server):
    server_url, data_dir = live_server
    local = tmp_path / "local"
    local.mkdir()
    (local / "a.txt").write_bytes(b"shared")

    sync(str(local), server_url)  # establish a common baseline

    (data_dir / "a.txt").write_bytes(b"server edit")

    result = sync(str(local), server_url)

    assert result.downloaded == ["a.txt"]
    assert result.uploaded == []
    assert (local / "a.txt").read_bytes() == b"server edit"


def test_sync_conflict_prefers_fresher_local_version(tmp_path, live_server):
    server_url, data_dir = live_server
    local = tmp_path / "local"
    local.mkdir()
    (local / "a.txt").write_bytes(b"shared")

    sync(str(local), server_url)  # establish a common baseline

    (data_dir / "a.txt").write_bytes(b"server edit")
    set_mtime(data_dir / "a.txt", 1_700_000_000)
    (local / "a.txt").write_bytes(b"local edit")
    set_mtime(local / "a.txt", 1_700_000_100)  # newer than the server copy

    result = sync(str(local), server_url)

    assert result.uploaded == ["a.txt"]
    assert result.downloaded == []
    assert (data_dir / "a.txt").read_bytes() == b"local edit"
    assert (local / "a.txt").read_bytes() == b"local edit"


def test_sync_conflict_prefers_fresher_remote_version(tmp_path, live_server):
    server_url, data_dir = live_server
    local = tmp_path / "local"
    local.mkdir()
    (local / "a.txt").write_bytes(b"shared")

    sync(str(local), server_url)  # establish a common baseline

    (local / "a.txt").write_bytes(b"local edit")
    set_mtime(local / "a.txt", 1_700_000_000)
    (data_dir / "a.txt").write_bytes(b"server edit")
    set_mtime(data_dir / "a.txt", 1_700_000_100)  # newer than the local copy

    result = sync(str(local), server_url)

    assert result.downloaded == ["a.txt"]
    assert result.uploaded == []
    assert (local / "a.txt").read_bytes() == b"server edit"
    assert (data_dir / "a.txt").read_bytes() == b"server edit"


def test_sync_conflict_with_equal_mtime_prefers_local(tmp_path, live_server):
    server_url, data_dir = live_server
    local = tmp_path / "local"
    local.mkdir()
    (local / "a.txt").write_bytes(b"shared")

    sync(str(local), server_url)  # establish a common baseline

    (local / "a.txt").write_bytes(b"local edit")
    (data_dir / "a.txt").write_bytes(b"server edit")
    set_mtime(local / "a.txt", 1_700_000_000)
    set_mtime(data_dir / "a.txt", 1_700_000_000)

    result = sync(str(local), server_url)

    assert result.uploaded == ["a.txt"]
    assert result.downloaded == []
    assert (data_dir / "a.txt").read_bytes() == b"local edit"
    assert (local / "a.txt").read_bytes() == b"local edit"


def test_sync_never_sends_delete_requests(tmp_path, live_server, monkeypatch):
    import requests

    server_url, data_dir = live_server
    local = tmp_path / "local"
    local.mkdir()
    (local / "local-only.txt").write_bytes(b"local only")
    (data_dir / "remote-only.txt").write_bytes(b"remote only")

    original_request = requests.Session.request

    def guarded_request(self, method, url, *args, **kwargs):
        assert method.upper() != "DELETE", f"sync must not send DELETE to {url}"
        return original_request(self, method, url, *args, **kwargs)

    monkeypatch.setattr(requests.Session, "request", guarded_request)

    sync(str(local), server_url)


def test_sync_does_not_delete_local_only_file_missing_on_server(tmp_path, live_server):
    server_url, data_dir = live_server
    local = tmp_path / "local"
    local.mkdir()
    (local / "a.txt").write_bytes(b"shared")
    (local / "local-only.txt").write_bytes(b"keep me")

    sync(str(local), server_url)

    assert (local / "local-only.txt").read_bytes() == b"keep me"
    assert (data_dir / "local-only.txt").read_bytes() == b"keep me"


def test_sync_raises_syncerror_when_directory_missing(tmp_path):
    with pytest.raises(SyncError):
        sync(str(tmp_path / "does-not-exist"), "http://127.0.0.1:9")


def test_sync_raises_syncerror_when_server_unreachable(tmp_path):
    local = tmp_path / "local"
    local.mkdir()

    with pytest.raises(SyncError):
        sync(str(local), "http://127.0.0.1:1")
