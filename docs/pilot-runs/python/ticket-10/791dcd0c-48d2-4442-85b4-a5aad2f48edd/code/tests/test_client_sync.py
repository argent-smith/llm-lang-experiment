import os

import pytest
import requests

from syncbox_client.client import SyncError, sync

# Arbitrary fixed epoch (not tied to wall-clock) so tie/ordering tests are
# fully deterministic regardless of when the suite runs.
_BASE_EPOCH = 1_700_000_000


def _set_mtime(path, epoch):
    os.utime(path, (epoch, epoch))


def test_sync_uploads_local_only_file(live_server, tmp_path):
    server_url, data_dir = live_server
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "local.txt").write_bytes(b"only on client")

    result = sync(client_dir, server_url)

    assert result.uploaded == ["local.txt"]
    assert result.downloaded == []
    assert (data_dir / "local.txt").read_bytes() == b"only on client"


def test_sync_downloads_server_only_file(live_server, tmp_path):
    server_url, data_dir = live_server
    (data_dir / "remote.txt").write_bytes(b"only on server")
    client_dir = tmp_path / "client"
    client_dir.mkdir()

    result = sync(client_dir, server_url)

    assert result.downloaded == ["remote.txt"]
    assert result.uploaded == []
    assert (client_dir / "remote.txt").read_bytes() == b"only on server"


def test_sync_creates_subdirs_for_downloaded_files(live_server, tmp_path):
    server_url, data_dir = live_server
    nested = data_dir / "a" / "b"
    nested.mkdir(parents=True)
    (nested / "leaf.bin").write_bytes(b"leaf")
    client_dir = tmp_path / "client"
    client_dir.mkdir()

    result = sync(client_dir, server_url)

    assert result.downloaded == ["a/b/leaf.bin"]
    assert (client_dir / "a" / "b" / "leaf.bin").read_bytes() == b"leaf"


def test_sync_local_change_wins_when_only_local_changed(live_server, tmp_path):
    server_url, data_dir = live_server
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "f.txt").write_bytes(b"shared")
    (data_dir / "f.txt").write_bytes(b"shared")

    baseline = sync(client_dir, server_url)
    assert baseline.unchanged == ["f.txt"]

    (client_dir / "f.txt").write_bytes(b"local edit")

    result = sync(client_dir, server_url)

    assert result.uploaded == ["f.txt"]
    assert result.downloaded == []
    assert (data_dir / "f.txt").read_bytes() == b"local edit"
    assert (client_dir / "f.txt").read_bytes() == b"local edit"


def test_sync_remote_change_pulled_when_only_remote_changed(live_server, tmp_path):
    server_url, data_dir = live_server
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "f.txt").write_bytes(b"shared")
    (data_dir / "f.txt").write_bytes(b"shared")

    baseline = sync(client_dir, server_url)
    assert baseline.unchanged == ["f.txt"]

    (data_dir / "f.txt").write_bytes(b"server edit")

    result = sync(client_dir, server_url)

    assert result.downloaded == ["f.txt"]
    assert result.uploaded == []
    assert (client_dir / "f.txt").read_bytes() == b"server edit"
    assert (data_dir / "f.txt").read_bytes() == b"server edit"


def test_sync_conflict_newer_remote_wins(live_server, tmp_path):
    server_url, data_dir = live_server
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "f.txt").write_bytes(b"shared")
    (data_dir / "f.txt").write_bytes(b"shared")

    baseline = sync(client_dir, server_url)
    assert baseline.unchanged == ["f.txt"]

    (client_dir / "f.txt").write_bytes(b"local edit")
    _set_mtime(client_dir / "f.txt", _BASE_EPOCH)
    (data_dir / "f.txt").write_bytes(b"server edit")
    _set_mtime(data_dir / "f.txt", _BASE_EPOCH + 100)

    result = sync(client_dir, server_url)

    assert result.downloaded == ["f.txt"]
    assert result.uploaded == []
    assert (client_dir / "f.txt").read_bytes() == b"server edit"
    assert (data_dir / "f.txt").read_bytes() == b"server edit"


def test_sync_conflict_newer_local_wins(live_server, tmp_path):
    server_url, data_dir = live_server
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "f.txt").write_bytes(b"shared")
    (data_dir / "f.txt").write_bytes(b"shared")

    baseline = sync(client_dir, server_url)
    assert baseline.unchanged == ["f.txt"]

    (client_dir / "f.txt").write_bytes(b"local edit")
    _set_mtime(client_dir / "f.txt", _BASE_EPOCH + 100)
    (data_dir / "f.txt").write_bytes(b"server edit")
    _set_mtime(data_dir / "f.txt", _BASE_EPOCH)

    result = sync(client_dir, server_url)

    assert result.uploaded == ["f.txt"]
    assert result.downloaded == []
    assert (client_dir / "f.txt").read_bytes() == b"local edit"
    assert (data_dir / "f.txt").read_bytes() == b"local edit"


def test_sync_conflict_equal_mtime_local_wins(live_server, tmp_path):
    server_url, data_dir = live_server
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "f.txt").write_bytes(b"shared")
    (data_dir / "f.txt").write_bytes(b"shared")

    baseline = sync(client_dir, server_url)
    assert baseline.unchanged == ["f.txt"]

    (client_dir / "f.txt").write_bytes(b"local edit")
    _set_mtime(client_dir / "f.txt", _BASE_EPOCH)
    (data_dir / "f.txt").write_bytes(b"server edit")
    _set_mtime(data_dir / "f.txt", _BASE_EPOCH)

    result = sync(client_dir, server_url)

    assert result.uploaded == ["f.txt"]
    assert result.downloaded == []
    assert (client_dir / "f.txt").read_bytes() == b"local edit"
    assert (data_dir / "f.txt").read_bytes() == b"local edit"


def test_sync_does_not_delete_and_resurrects_file_removed_from_server(live_server, tmp_path):
    server_url, data_dir = live_server
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "f.txt").write_bytes(b"shared")
    (data_dir / "f.txt").write_bytes(b"shared")

    baseline = sync(client_dir, server_url)
    assert baseline.unchanged == ["f.txt"]

    (data_dir / "f.txt").unlink()

    result = sync(client_dir, server_url)

    # sync propagates content, never deletions: a file missing on one side
    # that is still present on the other is treated as a fresh upload.
    assert result.uploaded == ["f.txt"]
    assert (client_dir / "f.txt").read_bytes() == b"shared"
    assert (data_dir / "f.txt").read_bytes() == b"shared"


def test_sync_does_not_delete_local_file_absent_on_server(live_server, tmp_path):
    server_url, _data_dir = live_server
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "local-only.txt").write_bytes(b"keep me")

    sync(client_dir, server_url)

    assert (client_dir / "local-only.txt").read_bytes() == b"keep me"


def test_sync_manifest_directory_not_synced_as_a_blob(live_server, tmp_path):
    server_url, data_dir = live_server
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "f.txt").write_bytes(b"content")

    result = sync(client_dir, server_url)

    assert result.uploaded == ["f.txt"]
    response = requests.get(f"{server_url}/blobs")
    keys = {item["key"] for item in response.json()}
    assert all(".syncbox" not in key for key in keys)

    # a second run must not re-upload/re-download the manifest either
    result2 = sync(client_dir, server_url)
    assert result2.uploaded == []
    assert result2.downloaded == []


def test_sync_raises_on_nonexistent_directory(live_server, tmp_path):
    server_url, _data_dir = live_server
    with pytest.raises(SyncError):
        sync(tmp_path / "missing", server_url)


def test_sync_against_unreachable_server_raises():
    with pytest.raises(requests.exceptions.RequestException):
        sync(".", "http://127.0.0.1:1")
