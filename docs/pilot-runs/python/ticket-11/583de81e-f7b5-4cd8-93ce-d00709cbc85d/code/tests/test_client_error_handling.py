import socket
import threading
import time

import pytest
import requests
from werkzeug.serving import make_server

import syncbox_client.client as client_module
from syncbox_client.client import describe_network_error, pull, push, status, sync
from syncbox_client.main import main
from syncbox_server.app import create_app
from syncbox_server.config import Config

# Deliberately unassigned/unlikely-to-be-listening port: connecting here fails
# fast with "connection refused" rather than hanging - the same convention the
# push/pull/sync/status suites already rely on for "server unreachable" cases.
UNREACHABLE_SERVER = "http://127.0.0.1:1"

# Generous upper bound for "did not hang" assertions: real failures here
# resolve in well under a second, this just guards against a regression to
# an unbounded wait without making the suite flaky under CI/Docker overhead.
NO_HANG_BUDGET_SECONDS = 5


@pytest.fixture
def hanging_server():
    """A raw TCP listener that accepts the connection but never writes a
    response, to exercise the client's read-timeout handling without
    depending on an external unreliable service."""
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    listener.listen(5)
    port = listener.getsockname()[1]
    stop = threading.Event()
    accepted = []

    def accept_loop():
        listener.settimeout(0.2)
        while not stop.is_set():
            try:
                conn, _ = listener.accept()
            except socket.timeout:
                continue
            accepted.append(conn)

    thread = threading.Thread(target=accept_loop, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{port}"
    finally:
        stop.set()
        thread.join(timeout=2)
        listener.close()
        for conn in accepted:
            conn.close()


@pytest.fixture
def failing_server_factory(tmp_path):
    """Starts a real syncbox server, wrapped so specific (method, path)
    requests fail with a chosen status/body while everything else behaves
    exactly like the real server - simulates "server returns 5xx for one
    particular key" without having to fake the whole HTTP API.
    """
    started = []

    def start(failures):
        data_dir = tmp_path / f"server-data-{len(started)}"
        data_dir.mkdir()
        app = create_app(Config(data_dir=str(data_dir), port=0))

        def wsgi_app(environ, start_response):
            marker = (environ.get("REQUEST_METHOD"), environ.get("PATH_INFO"))
            if marker in failures:
                status_line, body = failures[marker]
                body_bytes = body.encode()
                start_response(
                    status_line,
                    [
                        ("Content-Type", "text/plain"),
                        ("Content-Length", str(len(body_bytes))),
                    ],
                )
                return [body_bytes]
            return app(environ, start_response)

        httpd = make_server("127.0.0.1", 0, wsgi_app)
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        started.append((httpd, thread))
        return f"http://127.0.0.1:{httpd.server_port}", data_dir

    yield start

    for httpd, thread in started:
        httpd.shutdown()
        thread.join()


# --- server unreachable: connection refused -----------------------------------


def test_describe_network_error_labels_connection_refused():
    with pytest.raises(requests.exceptions.ConnectionError) as excinfo:
        requests.get(UNREACHABLE_SERVER, timeout=2)

    assert describe_network_error(excinfo.value) == "connection refused"


@pytest.mark.parametrize("command", ["push", "pull", "sync", "status"])
def test_unreachable_server_reports_reason_nonzero_exit_without_hanging(
    command, tmp_path, capsys
):
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "f.txt").write_bytes(b"content")

    started = time.monotonic()
    exit_code = main([command, str(client_dir), "--server", UNREACHABLE_SERVER])
    elapsed = time.monotonic() - started
    captured = capsys.readouterr()

    assert exit_code != 0
    assert "connection refused" in captured.err.lower()
    assert elapsed < NO_HANG_BUDGET_SECONDS


# --- server unreachable: timeout ------------------------------------------------


@pytest.mark.parametrize("command", ["push", "pull", "sync", "status"])
def test_hanging_server_times_out_reports_reason_without_hanging_forever(
    command, hanging_server, tmp_path, capsys, monkeypatch
):
    monkeypatch.setattr(client_module, "DEFAULT_TIMEOUT", 0.5)

    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "f.txt").write_bytes(b"content")

    started = time.monotonic()
    exit_code = main([command, str(client_dir), "--server", hanging_server])
    elapsed = time.monotonic() - started
    captured = capsys.readouterr()

    assert exit_code != 0
    assert "timed out" in captured.err.lower()
    assert elapsed < NO_HANG_BUDGET_SECONDS


# --- partial failure: push ------------------------------------------------------


def test_push_partial_failure_uploads_other_files_and_reports_failed_one(
    failing_server_factory, tmp_path, capsys
):
    server_url, data_dir = failing_server_factory(
        {("PUT", "/blobs/bad.txt"): ("500 Internal Server Error", "boom")}
    )
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "good1.txt").write_bytes(b"one")
    (client_dir / "good2.txt").write_bytes(b"two")
    (client_dir / "bad.txt").write_bytes(b"boom-data")

    exit_code = main(["push", str(client_dir), "--server", server_url])
    captured = capsys.readouterr()

    assert exit_code != 0
    assert (data_dir / "good1.txt").read_bytes() == b"one"
    assert (data_dir / "good2.txt").read_bytes() == b"two"
    assert not (data_dir / "bad.txt").exists()
    assert "bad.txt" in captured.err
    assert "500" in captured.err


def test_push_client_result_lists_failed_file_with_reason(failing_server_factory, tmp_path):
    server_url, _data_dir = failing_server_factory(
        {("PUT", "/blobs/bad.txt"): ("500 Internal Server Error", "boom")}
    )
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "good.txt").write_bytes(b"fine")
    (client_dir / "bad.txt").write_bytes(b"boom-data")

    result = push(client_dir, server_url)

    assert result.uploaded == ["good.txt"]
    assert [f.key for f in result.failed] == ["bad.txt"]
    assert "500" in result.failed[0].reason


def test_push_partial_failure_when_local_file_becomes_unreadable(
    monkeypatch, live_server, tmp_path
):
    server_url, data_dir = live_server
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "good.txt").write_bytes(b"fine")
    bad_path = client_dir / "bad.txt"
    bad_path.write_bytes(b"unreadable")

    real_sha256_file = client_module.sha256_file

    def flaky_sha256_file(path):
        if str(path) == str(bad_path):
            raise OSError("permission denied (simulated)")
        return real_sha256_file(path)

    monkeypatch.setattr(client_module, "sha256_file", flaky_sha256_file)

    result = push(client_dir, server_url)

    assert result.uploaded == ["good.txt"]
    assert [f.key for f in result.failed] == ["bad.txt"]
    assert (data_dir / "good.txt").read_bytes() == b"fine"
    assert not (data_dir / "bad.txt").exists()


# --- partial failure: pull -------------------------------------------------------


def test_pull_partial_failure_downloads_other_files_and_reports_failed_one(
    failing_server_factory, tmp_path, capsys
):
    server_url, data_dir = failing_server_factory(
        {("GET", "/blobs/bad.txt"): ("500 Internal Server Error", "boom")}
    )
    (data_dir / "good1.txt").write_bytes(b"one")
    (data_dir / "good2.txt").write_bytes(b"two")
    (data_dir / "bad.txt").write_bytes(b"boom-data")

    client_dir = tmp_path / "client"
    client_dir.mkdir()

    exit_code = main(["pull", str(client_dir), "--server", server_url])
    captured = capsys.readouterr()

    assert exit_code != 0
    assert (client_dir / "good1.txt").read_bytes() == b"one"
    assert (client_dir / "good2.txt").read_bytes() == b"two"
    assert not (client_dir / "bad.txt").exists()
    assert "bad.txt" in captured.err
    assert "500" in captured.err


def test_pull_client_result_lists_failed_file_with_reason(failing_server_factory, tmp_path):
    server_url, data_dir = failing_server_factory(
        {("GET", "/blobs/bad.txt"): ("500 Internal Server Error", "boom")}
    )
    (data_dir / "good.txt").write_bytes(b"fine")
    (data_dir / "bad.txt").write_bytes(b"boom-data")

    client_dir = tmp_path / "client"
    client_dir.mkdir()

    result = pull(client_dir, server_url)

    assert result.downloaded == ["good.txt"]
    assert [f.key for f in result.failed] == ["bad.txt"]
    assert "500" in result.failed[0].reason


# --- partial failure: sync -------------------------------------------------------


def test_sync_partial_failure_processes_other_files_and_reports_failed_one(
    failing_server_factory, tmp_path, capsys
):
    server_url, data_dir = failing_server_factory(
        {("PUT", "/blobs/bad.txt"): ("500 Internal Server Error", "boom")}
    )
    (data_dir / "remote-only.txt").write_bytes(b"from server")

    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "local-only.txt").write_bytes(b"from client")
    (client_dir / "bad.txt").write_bytes(b"boom-data")

    exit_code = main(["sync", str(client_dir), "--server", server_url])
    captured = capsys.readouterr()

    assert exit_code != 0
    assert (data_dir / "local-only.txt").read_bytes() == b"from client"
    assert (client_dir / "remote-only.txt").read_bytes() == b"from server"
    assert not (data_dir / "bad.txt").exists()
    assert "bad.txt" in captured.err
    assert "500" in captured.err


def test_sync_client_result_lists_failed_file_with_reason(failing_server_factory, tmp_path):
    server_url, data_dir = failing_server_factory(
        {("PUT", "/blobs/bad.txt"): ("500 Internal Server Error", "boom")}
    )
    (data_dir / "remote-only.txt").write_bytes(b"from server")

    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "local-only.txt").write_bytes(b"from client")
    (client_dir / "bad.txt").write_bytes(b"boom-data")

    result = sync(client_dir, server_url)

    assert result.uploaded == ["local-only.txt"]
    assert result.downloaded == ["remote-only.txt"]
    assert [f.key for f in result.failed] == ["bad.txt"]
    assert "500" in result.failed[0].reason


# --- partial failure: status (local file unreadable) ----------------------------


def test_status_partial_failure_when_local_file_becomes_unreadable(
    monkeypatch, live_server, tmp_path
):
    server_url, _data_dir = live_server
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "good.txt").write_bytes(b"fine")
    bad_path = client_dir / "bad.txt"
    bad_path.write_bytes(b"unreadable")

    real_sha256_file = client_module.sha256_file

    def flaky_sha256_file(path):
        if str(path) == str(bad_path):
            raise OSError("permission denied (simulated)")
        return real_sha256_file(path)

    monkeypatch.setattr(client_module, "sha256_file", flaky_sha256_file)

    result = status(client_dir, server_url)

    assert result.to_upload == ["good.txt"]
    assert [f.key for f in result.failed] == ["bad.txt"]
