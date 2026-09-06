import pytest
import requests

from syncbox_client.client import PullError, pull


def test_pull_downloads_missing_files(live_server, tmp_path):
    server_url, data_dir = live_server
    (data_dir / "docs").mkdir()
    (data_dir / "docs" / "a.txt").write_bytes(b"hello")
    (data_dir / "b.txt").write_bytes(b"world")

    client_dir = tmp_path / "client"
    client_dir.mkdir()

    result = pull(client_dir, server_url)

    assert set(result.downloaded) == {"docs/a.txt", "b.txt"}
    assert result.unchanged == []
    assert (client_dir / "docs" / "a.txt").read_bytes() == b"hello"
    assert (client_dir / "b.txt").read_bytes() == b"world"


def test_pull_skips_files_already_identical_locally(live_server, tmp_path):
    server_url, data_dir = live_server
    (data_dir / "same.txt").write_bytes(b"identical")

    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "same.txt").write_bytes(b"identical")

    result = pull(client_dir, server_url)

    assert result.downloaded == []
    assert result.unchanged == ["same.txt"]


def test_pull_redownloads_files_that_changed_on_server(live_server, tmp_path):
    server_url, data_dir = live_server
    target = data_dir / "changed.txt"
    target.write_bytes(b"version-1")

    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "changed.txt").write_bytes(b"version-1")

    target.write_bytes(b"version-2")

    result = pull(client_dir, server_url)

    assert result.downloaded == ["changed.txt"]
    assert (client_dir / "changed.txt").read_bytes() == b"version-2"


def test_pull_uses_posix_relative_path_as_key_and_creates_subdirs(live_server, tmp_path):
    server_url, data_dir = live_server
    nested = data_dir / "a" / "b" / "c"
    nested.mkdir(parents=True)
    (nested / "leaf.bin").write_bytes(b"leaf")

    client_dir = tmp_path / "client"
    client_dir.mkdir()

    result = pull(client_dir, server_url)

    assert result.downloaded == ["a/b/c/leaf.bin"]
    assert (client_dir / "a" / "b" / "c" / "leaf.bin").read_bytes() == b"leaf"


def test_pull_does_not_touch_local_files_absent_on_server(live_server, tmp_path):
    server_url, _data_dir = live_server
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "local-only.txt").write_bytes(b"keep me")

    result = pull(client_dir, server_url)

    assert result.downloaded == []
    assert (client_dir / "local-only.txt").read_bytes() == b"keep me"


def test_pull_raises_on_nonexistent_directory(live_server, tmp_path):
    server_url, _data_dir = live_server
    with pytest.raises(PullError):
        pull(tmp_path / "missing", server_url)


def test_pull_against_unreachable_server_raises():
    with pytest.raises(requests.exceptions.RequestException):
        pull(".", "http://127.0.0.1:1")
