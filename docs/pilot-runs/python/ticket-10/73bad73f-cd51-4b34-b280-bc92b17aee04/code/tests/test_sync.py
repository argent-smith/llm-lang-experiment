import os
import threading

import pytest
from werkzeug.serving import make_server

from client.sync import SyncError, resolve_action, sync
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


def set_mtime(path, epoch_seconds):
    os.utime(path, (epoch_seconds, epoch_seconds))


# --- resolve_action (pure conflict-resolution logic, no HTTP) ---------------


def test_resolve_action_local_only_uploads():
    assert resolve_action("sha-a", None, None, None, None) == "upload"


def test_resolve_action_remote_only_downloads():
    assert resolve_action(None, "sha-a", None, None, None) == "download"


def test_resolve_action_identical_is_unchanged():
    assert resolve_action("sha-a", "sha-a", "sha-a", None, None) == "unchanged"


def test_resolve_action_changed_only_locally_uploads_regardless_of_mtime():
    # Local changed relative to base, remote didn't -- local wins even though
    # its mtime is older than the (untouched) remote's.
    action = resolve_action(
        "sha-new", "sha-base", "sha-base", local_dt=100, remote_dt=999
    )
    assert action == "upload"


def test_resolve_action_changed_only_remotely_downloads_regardless_of_mtime():
    action = resolve_action(
        "sha-base", "sha-new", "sha-base", local_dt=999, remote_dt=100
    )
    assert action == "download"


def test_resolve_action_conflict_newer_remote_wins():
    action = resolve_action(
        "sha-local", "sha-remote", "sha-base", local_dt=100, remote_dt=200
    )
    assert action == "download"


def test_resolve_action_conflict_newer_local_wins():
    action = resolve_action(
        "sha-local", "sha-remote", "sha-base", local_dt=200, remote_dt=100
    )
    assert action == "upload"


def test_resolve_action_conflict_equal_mtime_favors_local():
    action = resolve_action(
        "sha-local", "sha-remote", "sha-base", local_dt=150, remote_dt=150
    )
    assert action == "upload"


def test_resolve_action_no_baseline_falls_back_to_mtime():
    action = resolve_action("sha-local", "sha-remote", None, local_dt=100, remote_dt=200)
    assert action == "download"


# --- sync (end-to-end against a real HTTP server) ---------------------------


def test_sync_uploads_local_only_file(tmp_path, live_server):
    server_url, data_dir = live_server
    source = tmp_path / "source"
    source.mkdir()
    (source / "a.txt").write_bytes(b"hello")

    result = sync(str(source), server_url)

    assert result.uploaded == ["a.txt"]
    assert result.downloaded == []
    assert (data_dir / "a.txt").read_bytes() == b"hello"


def test_sync_downloads_remote_only_file(tmp_path, live_server):
    server_url, data_dir = live_server
    (data_dir / "a.txt").write_bytes(b"hello")
    dest = tmp_path / "dest"
    dest.mkdir()

    result = sync(str(dest), server_url)

    assert result.downloaded == ["a.txt"]
    assert result.uploaded == []
    assert (dest / "a.txt").read_bytes() == b"hello"


def test_sync_downloads_nested_key_creating_subdirectories(tmp_path, live_server):
    server_url, data_dir = live_server
    (data_dir / "docs").mkdir()
    (data_dir / "docs" / "readme.txt").write_bytes(b"nested")
    dest = tmp_path / "dest"
    dest.mkdir()

    result = sync(str(dest), server_url)

    assert result.downloaded == ["docs/readme.txt"]
    assert (dest / "docs" / "readme.txt").read_bytes() == b"nested"


def test_sync_skips_identical_file(tmp_path, live_server):
    server_url, data_dir = live_server
    (data_dir / "a.txt").write_bytes(b"same")
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "a.txt").write_bytes(b"same")

    result = sync(str(dest), server_url)

    assert result.uploaded == []
    assert result.downloaded == []
    assert result.unchanged == ["a.txt"]


def test_sync_changed_only_locally_ends_up_on_server(tmp_path, live_server):
    server_url, data_dir = live_server
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "a.txt").write_bytes(b"baseline")
    sync(str(dest), server_url)
    set_mtime(data_dir / "a.txt", 2_000_000)

    # Local changes, but its mtime is set *older* than the untouched
    # server copy -- if the implementation fell back to naive mtime
    # comparison instead of using the baseline, this would pick the
    # server version instead.
    (dest / "a.txt").write_bytes(b"local edit")
    set_mtime(dest / "a.txt", 1_000_000)

    result = sync(str(dest), server_url)

    assert result.uploaded == ["a.txt"]
    assert result.downloaded == []
    assert (data_dir / "a.txt").read_bytes() == b"local edit"
    assert (dest / "a.txt").read_bytes() == b"local edit"


def test_sync_changed_only_on_server_ends_up_locally(tmp_path, live_server):
    server_url, data_dir = live_server
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "a.txt").write_bytes(b"baseline")
    sync(str(dest), server_url)
    set_mtime(dest / "a.txt", 2_000_000)

    # Server changes, but its mtime is set *older* than the untouched
    # local copy -- same reasoning as above, in the other direction.
    (data_dir / "a.txt").write_bytes(b"server edit")
    set_mtime(data_dir / "a.txt", 1_000_000)

    result = sync(str(dest), server_url)

    assert result.downloaded == ["a.txt"]
    assert result.uploaded == []
    assert (dest / "a.txt").read_bytes() == b"server edit"
    assert (data_dir / "a.txt").read_bytes() == b"server edit"


def test_sync_conflict_newer_remote_wins(tmp_path, live_server):
    server_url, data_dir = live_server
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "a.txt").write_bytes(b"baseline")
    sync(str(dest), server_url)

    (dest / "a.txt").write_bytes(b"local edit")
    set_mtime(dest / "a.txt", 1_000_000)
    (data_dir / "a.txt").write_bytes(b"server edit")
    set_mtime(data_dir / "a.txt", 2_000_000)

    result = sync(str(dest), server_url)

    assert result.downloaded == ["a.txt"]
    assert result.uploaded == []
    assert (dest / "a.txt").read_bytes() == b"server edit"
    assert (data_dir / "a.txt").read_bytes() == b"server edit"


def test_sync_conflict_newer_local_wins(tmp_path, live_server):
    server_url, data_dir = live_server
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "a.txt").write_bytes(b"baseline")
    sync(str(dest), server_url)

    (dest / "a.txt").write_bytes(b"local edit")
    set_mtime(dest / "a.txt", 2_000_000)
    (data_dir / "a.txt").write_bytes(b"server edit")
    set_mtime(data_dir / "a.txt", 1_000_000)

    result = sync(str(dest), server_url)

    assert result.uploaded == ["a.txt"]
    assert result.downloaded == []
    assert (data_dir / "a.txt").read_bytes() == b"local edit"
    assert (dest / "a.txt").read_bytes() == b"local edit"


def test_sync_conflict_equal_mtime_favors_local(tmp_path, live_server):
    server_url, data_dir = live_server
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "a.txt").write_bytes(b"baseline")
    sync(str(dest), server_url)

    (dest / "a.txt").write_bytes(b"local edit")
    (data_dir / "a.txt").write_bytes(b"server edit")
    set_mtime(dest / "a.txt", 1_500_000)
    set_mtime(data_dir / "a.txt", 1_500_000)

    result = sync(str(dest), server_url)

    assert result.uploaded == ["a.txt"]
    assert result.downloaded == []
    assert (data_dir / "a.txt").read_bytes() == b"local edit"
    assert (dest / "a.txt").read_bytes() == b"local edit"


def test_sync_does_not_delete_server_file_when_local_copy_removed(tmp_path, live_server):
    server_url, data_dir = live_server
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "a.txt").write_bytes(b"hello")
    sync(str(dest), server_url)

    (dest / "a.txt").unlink()
    result = sync(str(dest), server_url)

    # sync doesn't propagate deletions -- the file just comes back locally.
    assert (data_dir / "a.txt").exists()
    assert (dest / "a.txt").read_bytes() == b"hello"
    assert result.downloaded == ["a.txt"]


def test_sync_does_not_delete_local_file_when_server_copy_removed(tmp_path, live_server):
    server_url, data_dir = live_server
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "a.txt").write_bytes(b"hello")
    sync(str(dest), server_url)

    (data_dir / "a.txt").unlink()
    result = sync(str(dest), server_url)

    assert (dest / "a.txt").exists()
    assert (data_dir / "a.txt").read_bytes() == b"hello"
    assert result.uploaded == ["a.txt"]


def test_sync_first_run_has_no_conflict_for_disjoint_files(tmp_path, live_server):
    server_url, data_dir = live_server
    (data_dir / "server-only.txt").write_bytes(b"from server")
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "local-only.txt").write_bytes(b"from local")

    result = sync(str(dest), server_url)

    assert result.uploaded == ["local-only.txt"]
    assert result.downloaded == ["server-only.txt"]
    assert (data_dir / "local-only.txt").read_bytes() == b"from local"
    assert (dest / "server-only.txt").read_bytes() == b"from server"


def test_sync_manifest_is_not_synced_as_a_blob(tmp_path, live_server):
    server_url, data_dir = live_server
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "a.txt").write_bytes(b"hello")

    sync(str(dest), server_url)
    sync(str(dest), server_url)

    assert not (data_dir / ".syncbox-manifest.json").exists()


def test_sync_raises_syncerror_when_directory_missing(tmp_path):
    with pytest.raises(SyncError):
        sync(str(tmp_path / "does-not-exist"), "http://127.0.0.1:9")


def test_sync_raises_syncerror_when_server_unreachable(tmp_path):
    dest = tmp_path / "dest"
    dest.mkdir()

    with pytest.raises(SyncError):
        sync(str(dest), "http://127.0.0.1:1")
