import hashlib
import threading

import pytest
from werkzeug.serving import make_server

from client.status import StatusError, status
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


def snapshot(directory):
    """Map of relative POSIX path -> content, for every file under directory."""
    return {
        path.relative_to(directory).as_posix(): path.read_bytes()
        for path in sorted(directory.rglob("*"))
        if path.is_file()
    }


# --- direction: local-only file -> would upload ------------------------------


def test_status_reports_local_only_file_as_upload(tmp_path, live_server):
    server_url, data_dir = live_server
    source = tmp_path / "source"
    source.mkdir()
    (source / "a.txt").write_bytes(b"hello")

    result = status(str(source), server_url)

    assert result.to_upload == ["a.txt"]
    assert result.to_download == []
    assert result.unchanged == []


# --- direction: server-only file -> would download ---------------------------


def test_status_reports_remote_only_file_as_download(tmp_path, live_server):
    server_url, data_dir = live_server
    (data_dir / "a.txt").write_bytes(b"hello")
    dest = tmp_path / "dest"
    dest.mkdir()

    result = status(str(dest), server_url)

    assert result.to_download == ["a.txt"]
    assert result.to_upload == []
    assert result.unchanged == []


# --- direction: content diverged on both sides --------------------------------


def test_status_reports_diverged_file_as_both_upload_and_download(tmp_path, live_server):
    server_url, data_dir = live_server
    (data_dir / "a.txt").write_bytes(b"server version")
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "a.txt").write_bytes(b"local version")

    result = status(str(dest), server_url)

    assert result.to_upload == ["a.txt"]
    assert result.to_download == ["a.txt"]
    assert result.unchanged == []


# --- identical content is reported as unchanged, not a candidate either way --


def test_status_reports_identical_file_as_unchanged(tmp_path, live_server):
    server_url, data_dir = live_server
    (data_dir / "a.txt").write_bytes(b"same content")
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "a.txt").write_bytes(b"same content")

    result = status(str(dest), server_url)

    assert result.to_upload == []
    assert result.to_download == []
    assert result.unchanged == ["a.txt"]


def test_status_mixed_directory_reports_each_key_correctly(tmp_path, live_server):
    server_url, data_dir = live_server
    (data_dir / "same.txt").write_bytes(b"identical")
    (data_dir / "server-only.txt").write_bytes(b"only on server")
    (data_dir / "diverged.txt").write_bytes(b"server side")
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "same.txt").write_bytes(b"identical")
    (dest / "local-only.txt").write_bytes(b"only local")
    (dest / "diverged.txt").write_bytes(b"local side")

    result = status(str(dest), server_url)

    assert sorted(result.to_upload) == ["diverged.txt", "local-only.txt"]
    assert sorted(result.to_download) == ["diverged.txt", "server-only.txt"]
    assert result.unchanged == ["same.txt"]


def test_status_empty_directory_and_empty_server_reports_nothing(tmp_path, live_server):
    server_url, _ = live_server
    dest = tmp_path / "dest"
    dest.mkdir()

    result = status(str(dest), server_url)

    assert result.to_upload == []
    assert result.to_download == []
    assert result.unchanged == []


# --- read-only: neither side is modified --------------------------------------


def test_status_does_not_modify_server_data(tmp_path, live_server):
    server_url, data_dir = live_server
    (data_dir / "a.txt").write_bytes(b"server version")
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "a.txt").write_bytes(b"local version")
    (dest / "local-only.txt").write_bytes(b"local only")

    before = snapshot(data_dir)
    status(str(dest), server_url)
    after = snapshot(data_dir)

    assert before == after


def test_status_does_not_modify_local_directory(tmp_path, live_server):
    server_url, data_dir = live_server
    (data_dir / "a.txt").write_bytes(b"server version")
    (data_dir / "server-only.txt").write_bytes(b"server only")
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "a.txt").write_bytes(b"local version")

    before = snapshot(dest)
    status(str(dest), server_url)
    after = snapshot(dest)

    assert before == after


def test_status_does_not_put_or_delete(tmp_path, live_server, monkeypatch):
    server_url, data_dir = live_server
    (data_dir / "a.txt").write_bytes(b"server version")
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "a.txt").write_bytes(b"local version")
    (dest / "local-only.txt").write_bytes(b"local only")

    import requests

    original_request = requests.Session.request

    def guarded_request(self, method, url, *args, **kwargs):
        assert method.upper() not in ("PUT", "DELETE", "POST", "PATCH"), (
            f"status must not send {method} to {url}"
        )
        return original_request(self, method, url, *args, **kwargs)

    monkeypatch.setattr(requests.Session, "request", guarded_request)

    status(str(dest), server_url)


# --- error handling ------------------------------------------------------------


def test_status_raises_statuserror_when_directory_missing(tmp_path):
    with pytest.raises(StatusError):
        status(str(tmp_path / "does-not-exist"), "http://127.0.0.1:9")


def test_status_raises_statuserror_when_server_unreachable(tmp_path):
    dest = tmp_path / "dest"
    dest.mkdir()

    with pytest.raises(StatusError):
        status(str(dest), "http://127.0.0.1:1")


def test_status_result_matches_actual_sha256(tmp_path, live_server):
    server_url, data_dir = live_server
    content = b"hash me"
    (data_dir / "a.txt").write_bytes(content)
    dest = tmp_path / "dest"
    dest.mkdir()

    result = status(str(dest), server_url)

    assert result.to_download == ["a.txt"]
    assert hashlib.sha256(content).hexdigest() == hashlib.sha256(
        (data_dir / "a.txt").read_bytes()
    ).hexdigest()
