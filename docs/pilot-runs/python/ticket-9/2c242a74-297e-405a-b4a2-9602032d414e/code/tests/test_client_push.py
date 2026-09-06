import pytest
import requests

from syncbox_client.client import PushError, push


def test_push_uploads_new_files(live_server, tmp_path):
    server_url, data_dir = live_server
    client_dir = tmp_path / "client"
    (client_dir / "docs").mkdir(parents=True)
    (client_dir / "docs" / "a.txt").write_bytes(b"hello")
    (client_dir / "b.txt").write_bytes(b"world")

    result = push(client_dir, server_url)

    assert set(result.uploaded) == {"docs/a.txt", "b.txt"}
    assert result.unchanged == []
    assert (data_dir / "docs" / "a.txt").read_bytes() == b"hello"
    assert (data_dir / "b.txt").read_bytes() == b"world"


def test_push_skips_files_already_identical_on_server(live_server, tmp_path):
    server_url, _data_dir = live_server
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "same.txt").write_bytes(b"identical")

    first = push(client_dir, server_url)
    assert first.uploaded == ["same.txt"]

    second = push(client_dir, server_url)
    assert second.uploaded == []
    assert second.unchanged == ["same.txt"]


def test_push_reuploads_files_that_changed_since_last_push(live_server, tmp_path):
    server_url, data_dir = live_server
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    target = client_dir / "changed.txt"
    target.write_bytes(b"version-1")

    push(client_dir, server_url)
    target.write_bytes(b"version-2")

    result = push(client_dir, server_url)

    assert result.uploaded == ["changed.txt"]
    assert (data_dir / "changed.txt").read_bytes() == b"version-2"


def test_push_uses_posix_relative_path_as_key(live_server, tmp_path):
    server_url, _data_dir = live_server
    client_dir = tmp_path / "client"
    nested = client_dir / "a" / "b" / "c"
    nested.mkdir(parents=True)
    (nested / "leaf.bin").write_bytes(b"leaf")

    result = push(client_dir, server_url)

    assert result.uploaded == ["a/b/c/leaf.bin"]


def test_push_does_not_reupload_files_preexisting_on_server(live_server, tmp_path):
    server_url, data_dir = live_server
    (data_dir / "preexisting.txt").write_bytes(b"already here")

    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "preexisting.txt").write_bytes(b"already here")
    (client_dir / "new.txt").write_bytes(b"new")

    result = push(client_dir, server_url)

    assert result.uploaded == ["new.txt"]
    assert result.unchanged == ["preexisting.txt"]


def test_push_raises_on_nonexistent_directory(live_server, tmp_path):
    server_url, _data_dir = live_server
    with pytest.raises(PushError):
        push(tmp_path / "missing", server_url)


def test_push_against_unreachable_server_raises():
    with pytest.raises(requests.exceptions.RequestException):
        push(".", "http://127.0.0.1:1")
