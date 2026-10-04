from __future__ import annotations

import http.client
import socket
import threading
from collections.abc import Callable, Iterator
from contextlib import ExitStack, contextmanager
from pathlib import Path

import pytest

from syncbox.server.app import SyncboxServer
from syncbox.server.config import ServerConfig


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@contextmanager
def running_server(data_dir: Path) -> Iterator[SyncboxServer]:
    """An in-process server on an ephemeral loopback port."""
    srv = SyncboxServer(ServerConfig(data_dir=data_dir, host="127.0.0.1", port=0))
    thread = threading.Thread(target=srv.serve_forever, daemon=True)
    thread.start()
    try:
        yield srv
    finally:
        srv.shutdown()
        thread.join()
        srv.server_close()


@contextmanager
def connection_to(srv: SyncboxServer) -> Iterator[http.client.HTTPConnection]:
    host, port = srv.server_address[:2]
    connection = http.client.HTTPConnection(host, port, timeout=5)
    try:
        yield connection
    finally:
        connection.close()


@pytest.fixture
def server(tmp_path) -> Iterator[SyncboxServer]:
    with running_server(tmp_path) as srv:
        yield srv


@pytest.fixture
def conn(server) -> Iterator[http.client.HTTPConnection]:
    with connection_to(server) as connection:
        yield connection


@pytest.fixture
def server_factory() -> Iterator[Callable[[Path], http.client.HTTPConnection]]:
    """Start an in-process server on a given data dir; returns a connection to it."""
    with ExitStack() as stack:
        def start(data_dir: Path) -> http.client.HTTPConnection:
            return stack.enter_context(connection_to(stack.enter_context(running_server(data_dir))))
        yield start
