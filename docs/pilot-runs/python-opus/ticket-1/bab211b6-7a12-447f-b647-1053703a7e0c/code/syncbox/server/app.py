"""HTTP layer: request routing and the threaded server."""

from __future__ import annotations

import json
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable

from .. import __version__
from .config import ServerConfig

# Unread request bodies up to this size are drained so the keep-alive
# connection stays usable; anything larger closes the connection instead.
_MAX_DISCARD_BYTES = 1 << 20


class SyncboxServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, config: ServerConfig) -> None:
        self.config = config
        super().__init__((config.host, config.port), RequestHandler)


class RequestHandler(BaseHTTPRequestHandler):
    server: SyncboxServer
    server_version = f"syncbox/{__version__}"
    protocol_version = "HTTP/1.1"
    # Seconds of socket inactivity before an (idle keep-alive) connection is dropped.
    timeout = 60

    # path -> {method -> handler method name}
    ROUTES: dict[str, dict[str, str]] = {
        "/healthz": {"GET": "handle_healthz"},
    }

    # --- handlers -------------------------------------------------------

    def handle_healthz(self) -> None:
        self.send_json(HTTPStatus.OK, {"status": "ok"})

    # --- dispatch -------------------------------------------------------

    def do_GET(self) -> None:
        self._dispatch()

    def do_HEAD(self) -> None:
        self._dispatch()

    def do_PUT(self) -> None:
        self._dispatch()

    def do_POST(self) -> None:
        self._dispatch()

    def do_DELETE(self) -> None:
        self._dispatch()

    def do_PATCH(self) -> None:
        self._dispatch()

    def do_OPTIONS(self) -> None:
        self._dispatch()

    def _dispatch(self) -> None:
        self._body_consumed = False
        path = self.path.split("?", 1)[0].split("#", 1)[0]

        methods = self.ROUTES.get(path)
        if methods is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, "not found")
            return

        method = self.command
        if method == "HEAD" and "HEAD" not in methods and "GET" in methods:
            method = "GET"
        handler_name = methods.get(method)
        if handler_name is None:
            allowed = sorted({*methods, "HEAD"} if "GET" in methods else methods)
            self.send_error_json(
                HTTPStatus.METHOD_NOT_ALLOWED,
                "method not allowed",
                headers={"Allow": ", ".join(allowed)},
            )
            return

        handler: Callable[[], None] = getattr(self, handler_name)
        handler()

    # --- responses ------------------------------------------------------

    def send_json(
        self,
        status: HTTPStatus,
        payload: Any,
        headers: dict[str, str] | None = None,
    ) -> None:
        body = json.dumps(payload).encode()
        self.send_body(status, body, "application/json", headers)

    def send_error_json(
        self,
        status: HTTPStatus,
        message: str,
        headers: dict[str, str] | None = None,
    ) -> None:
        self.send_json(status, {"error": message}, headers)

    def send_body(
        self,
        status: HTTPStatus,
        body: bytes = b"",
        content_type: str | None = None,
        headers: dict[str, str] | None = None,
    ) -> None:
        self._discard_unread_body()
        self.send_response(status)
        if content_type is not None:
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        if self.close_connection:
            self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _discard_unread_body(self) -> None:
        """Drain a request body no handler read, keeping the connection in sync."""
        if self._body_consumed:
            return
        self._body_consumed = True
        if "Transfer-Encoding" in self.headers:
            # Chunked bodies are not supported; don't try to resync.
            self.close_connection = True
            return
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            return
        try:
            remaining = int(raw_length)
        except ValueError:
            remaining = -1
        if not 0 <= remaining <= _MAX_DISCARD_BYTES:
            self.close_connection = True
            return
        while remaining > 0:
            chunk = self.rfile.read(min(remaining, 64 * 1024))
            if not chunk:
                self.close_connection = True
                return
            remaining -= len(chunk)
