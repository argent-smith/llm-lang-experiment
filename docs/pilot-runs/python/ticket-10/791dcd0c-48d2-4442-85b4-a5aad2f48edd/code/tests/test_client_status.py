import pytest
import requests

from syncbox_client.client import StatusError, status


class NoWriteSession(requests.Session):
    """A Session that fails the test if status() ever tries to mutate the server."""

    def put(self, *args, **kwargs):
        raise AssertionError("status must never send PUT requests")

    def delete(self, *args, **kwargs):
        raise AssertionError("status must never send DELETE requests")


def test_status_flags_locally_new_file_for_upload(live_server, tmp_path):
    server_url, _data_dir = live_server
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "new.txt").write_bytes(b"only on client")

    result = status(client_dir, server_url, session=NoWriteSession())

    assert result.to_upload == ["new.txt"]
    assert result.to_download == []
    assert result.unchanged == []


def test_status_flags_server_only_file_for_download(live_server, tmp_path):
    server_url, data_dir = live_server
    (data_dir / "new.txt").write_bytes(b"only on server")
    client_dir = tmp_path / "client"
    client_dir.mkdir()

    result = status(client_dir, server_url, session=NoWriteSession())

    assert result.to_download == ["new.txt"]
    assert result.to_upload == []
    assert result.unchanged == []


def test_status_flags_diverged_file_for_both_directions(live_server, tmp_path):
    server_url, data_dir = live_server
    (data_dir / "diverged.txt").write_bytes(b"server version")
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "diverged.txt").write_bytes(b"client version")

    result = status(client_dir, server_url, session=NoWriteSession())

    assert result.to_upload == ["diverged.txt"]
    assert result.to_download == ["diverged.txt"]
    assert result.unchanged == []


def test_status_reports_identical_files_as_unchanged(live_server, tmp_path):
    server_url, data_dir = live_server
    (data_dir / "same.txt").write_bytes(b"identical")
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "same.txt").write_bytes(b"identical")

    result = status(client_dir, server_url, session=NoWriteSession())

    assert result.to_upload == []
    assert result.to_download == []
    assert result.unchanged == ["same.txt"]


def test_status_mixed_case_reports_each_file_under_its_own_direction(live_server, tmp_path):
    server_url, data_dir = live_server
    (data_dir / "same.txt").write_bytes(b"identical")
    (data_dir / "server-only.txt").write_bytes(b"from server")
    (data_dir / "diverged.txt").write_bytes(b"server version")

    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "same.txt").write_bytes(b"identical")
    (client_dir / "local-only.txt").write_bytes(b"from client")
    (client_dir / "diverged.txt").write_bytes(b"client version")

    result = status(client_dir, server_url, session=NoWriteSession())

    assert set(result.to_upload) == {"local-only.txt", "diverged.txt"}
    assert set(result.to_download) == {"server-only.txt", "diverged.txt"}
    assert result.unchanged == ["same.txt"]


def test_status_does_not_modify_local_filesystem(live_server, tmp_path):
    server_url, data_dir = live_server
    (data_dir / "server-only.txt").write_bytes(b"from server")
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "local-only.txt").write_bytes(b"from client")

    status(client_dir, server_url, session=NoWriteSession())

    assert [p.name for p in client_dir.iterdir()] == ["local-only.txt"]
    assert (client_dir / "local-only.txt").read_bytes() == b"from client"


def test_status_does_not_modify_server(live_server, tmp_path):
    server_url, data_dir = live_server
    (data_dir / "server-only.txt").write_bytes(b"from server")
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "local-only.txt").write_bytes(b"from client")

    # NoWriteSession asserts on any PUT/DELETE; a plain successful run is proof enough,
    # but also double check server-side file listing is untouched.
    status(client_dir, server_url, session=NoWriteSession())

    assert [p.name for p in data_dir.iterdir()] == ["server-only.txt"]
    assert (data_dir / "server-only.txt").read_bytes() == b"from server"


def test_status_raises_on_nonexistent_directory(live_server, tmp_path):
    server_url, _data_dir = live_server
    with pytest.raises(StatusError):
        status(tmp_path / "missing", server_url)


def test_status_against_unreachable_server_raises():
    with pytest.raises(requests.exceptions.RequestException):
        status(".", "http://127.0.0.1:1")
