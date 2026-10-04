from __future__ import annotations

import http.client
import socket
import threading
from collections.abc import Iterator

import pytest

from syncbox.server.app import SyncboxServer
from syncbox.server.config import ServerConfig


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@pytest.fixture
def server(tmp_path) -> Iterator[SyncboxServer]:
    """An in-process server on an ephemeral loopback port."""
    srv = SyncboxServer(ServerConfig(data_dir=tmp_path, host="127.0.0.1", port=0))
    thread = threading.Thread(target=srv.serve_forever, daemon=True)
    thread.start()
    try:
        yield srv
    finally:
        srv.shutdown()
        thread.join()
        srv.server_close()


@pytest.fixture
def conn(server) -> Iterator[http.client.HTTPConnection]:
    host, port = server.server_address[:2]
    connection = http.client.HTTPConnection(host, port, timeout=5)
    try:
        yield connection
    finally:
        connection.close()
