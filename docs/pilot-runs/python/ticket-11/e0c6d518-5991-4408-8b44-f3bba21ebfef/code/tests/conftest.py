import socket
import threading

import pytest
from flask import request
from werkzeug.serving import make_server

from server.app import create_app


@pytest.fixture
def flaky_server(tmp_path):
    """Factory fixture for ticket-11 partial-failure tests.

    Call it as flaky_server(fail_key, methods=("PUT",)) to get a live
    syncbox server whose data dir starts empty and that returns 500 for any
    request to /blobs/<fail_key> using one of `methods`, while behaving like
    a normal server for every other request. Returns (server_url, data_dir).
    """
    data_dir = tmp_path / "data"
    data_dir.mkdir()
    servers = []

    def build(fail_key, methods=("PUT",)):
        app = create_app(str(data_dir))
        fail_path = f"/blobs/{fail_key}"

        @app.before_request
        def _maybe_fail():
            if request.path == fail_path and request.method in methods:
                return "", 500

        httpd = make_server("127.0.0.1", 0, app)
        thread = threading.Thread(target=httpd.serve_forever)
        thread.start()
        servers.append((httpd, thread))
        return f"http://127.0.0.1:{httpd.server_port}", data_dir

    yield build

    for httpd, thread in servers:
        httpd.shutdown()
        thread.join()


@pytest.fixture
def stalling_server():
    """A bare TCP listener that accepts connections but never writes a
    response and never closes them -- simulates a server that accepted the
    connection but is hung, to exercise the client's response timeout
    without needing a real slow endpoint.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    sock.listen(5)
    port = sock.getsockname()[1]
    stop = threading.Event()
    conns = []

    def accept_loop():
        sock.settimeout(0.2)
        while not stop.is_set():
            try:
                conn, _ = sock.accept()
            except socket.timeout:
                continue
            conns.append(conn)

    thread = threading.Thread(target=accept_loop, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{port}"
    finally:
        stop.set()
        thread.join(timeout=2)
        for conn in conns:
            conn.close()
        sock.close()
