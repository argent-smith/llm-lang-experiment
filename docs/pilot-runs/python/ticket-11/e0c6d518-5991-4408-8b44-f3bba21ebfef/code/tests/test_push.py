import threading
import time

import pytest
from werkzeug.serving import make_server

import client.push as push_module
from client.push import PushError, files_to_upload, push
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


# --- files_to_upload (pure diff logic, no HTTP) -----------------------------


def test_files_to_upload_includes_missing_keys():
    local = {"a.txt": "hash-a"}
    remote = {}

    assert files_to_upload(local, remote) == ["a.txt"]


def test_files_to_upload_includes_changed_keys():
    local = {"a.txt": "hash-a"}
    remote = {"a.txt": "hash-old"}

    assert files_to_upload(local, remote) == ["a.txt"]


def test_files_to_upload_excludes_identical_keys():
    local = {"a.txt": "hash-a"}
    remote = {"a.txt": "hash-a"}

    assert files_to_upload(local, remote) == []


def test_files_to_upload_ignores_extra_remote_keys():
    local = {"a.txt": "hash-a"}
    remote = {"a.txt": "hash-a", "b.txt": "hash-b"}

    assert files_to_upload(local, remote) == []


def test_files_to_upload_returns_sorted_keys():
    local = {"z.txt": "1", "a.txt": "2", "m.txt": "3"}
    remote = {}

    assert files_to_upload(local, remote) == ["a.txt", "m.txt", "z.txt"]


# --- push (end-to-end against a real HTTP server) ---------------------------


def test_push_uploads_new_file(tmp_path, live_server):
    server_url, data_dir = live_server
    source = tmp_path / "source"
    source.mkdir()
    (source / "a.txt").write_bytes(b"hello")

    result = push(str(source), server_url)

    assert result.uploaded == ["a.txt"]
    assert result.skipped == []
    assert (data_dir / "a.txt").read_bytes() == b"hello"


def test_push_uploads_nested_file_as_posix_key(tmp_path, live_server):
    server_url, data_dir = live_server
    source = tmp_path / "source"
    (source / "docs").mkdir(parents=True)
    (source / "docs" / "readme.txt").write_bytes(b"nested")

    result = push(str(source), server_url)

    assert result.uploaded == ["docs/readme.txt"]
    assert (data_dir / "docs" / "readme.txt").read_bytes() == b"nested"


def test_push_skips_file_identical_to_server(tmp_path, live_server):
    server_url, data_dir = live_server
    source = tmp_path / "source"
    source.mkdir()
    (source / "a.txt").write_bytes(b"same content")
    push(str(source), server_url)

    result = push(str(source), server_url)

    assert result.uploaded == []
    assert result.skipped == ["a.txt"]


def test_push_uploads_file_that_differs_from_server(tmp_path, live_server):
    server_url, data_dir = live_server
    source = tmp_path / "source"
    source.mkdir()
    (source / "a.txt").write_bytes(b"old content")
    push(str(source), server_url)

    (source / "a.txt").write_bytes(b"new content")
    result = push(str(source), server_url)

    assert result.uploaded == ["a.txt"]
    assert (data_dir / "a.txt").read_bytes() == b"new content"


def test_push_only_uploads_changed_files_among_several(tmp_path, live_server):
    server_url, data_dir = live_server
    source = tmp_path / "source"
    source.mkdir()
    (source / "unchanged.txt").write_bytes(b"stays the same")
    (source / "changed.txt").write_bytes(b"before")
    push(str(source), server_url)

    (source / "changed.txt").write_bytes(b"after")
    (source / "new.txt").write_bytes(b"brand new")
    result = push(str(source), server_url)

    assert sorted(result.uploaded) == ["changed.txt", "new.txt"]
    assert result.skipped == ["unchanged.txt"]


def test_push_empty_directory_uploads_nothing(tmp_path, live_server):
    server_url, _ = live_server
    source = tmp_path / "source"
    source.mkdir()

    result = push(str(source), server_url)

    assert result.uploaded == []
    assert result.skipped == []


def test_push_raises_pusherror_when_directory_missing(tmp_path):
    with pytest.raises(PushError):
        push(str(tmp_path / "does-not-exist"), "http://127.0.0.1:9")


def test_push_raises_pusherror_when_server_unreachable(tmp_path):
    source = tmp_path / "source"
    source.mkdir()
    (source / "a.txt").write_bytes(b"x")

    start = time.monotonic()
    with pytest.raises(PushError):
        push(str(source), "http://127.0.0.1:1")
    assert time.monotonic() - start < 5


def test_push_raises_pusherror_on_response_timeout_without_hanging(tmp_path, stalling_server):
    # stalling_server accepts the TCP connection but never replies -- push
    # must give up after its own timeout rather than waiting forever.
    source = tmp_path / "source"
    source.mkdir()
    (source / "a.txt").write_bytes(b"x")

    start = time.monotonic()
    with pytest.raises(PushError):
        push(str(source), stalling_server, timeout=1)
    elapsed = time.monotonic() - start

    assert elapsed < 5


# --- partial failure: some files fail, the rest still get processed --------


def test_push_partial_failure_uploads_the_rest_and_reports_the_failed_key(
    tmp_path, flaky_server
):
    server_url, data_dir = flaky_server("b.txt", methods=("PUT",))
    source = tmp_path / "source"
    source.mkdir()
    (source / "a.txt").write_bytes(b"aaa")
    (source / "b.txt").write_bytes(b"bbb")
    (source / "c.txt").write_bytes(b"ccc")

    result = push(str(source), server_url)

    assert result.uploaded == ["a.txt", "c.txt"]
    assert [failure.key for failure in result.failed] == ["b.txt"]
    assert (data_dir / "a.txt").read_bytes() == b"aaa"
    assert (data_dir / "c.txt").read_bytes() == b"ccc"
    assert not (data_dir / "b.txt").exists()


def test_push_continues_past_unreadable_local_file(tmp_path, live_server, monkeypatch):
    server_url, data_dir = live_server
    source = tmp_path / "source"
    source.mkdir()
    (source / "a.txt").write_bytes(b"aaa")
    (source / "bad.txt").write_bytes(b"unreadable")

    original_sha256_file = push_module.sha256_file

    def flaky_sha256_file(path, *args, **kwargs):
        if path.name == "bad.txt":
            raise OSError("permission denied")
        return original_sha256_file(path, *args, **kwargs)

    monkeypatch.setattr(push_module, "sha256_file", flaky_sha256_file)

    result = push(str(source), server_url)

    assert result.uploaded == ["a.txt"]
    assert [failure.key for failure in result.failed] == ["bad.txt"]
    assert (data_dir / "a.txt").read_bytes() == b"aaa"
    assert not (data_dir / "bad.txt").exists()
