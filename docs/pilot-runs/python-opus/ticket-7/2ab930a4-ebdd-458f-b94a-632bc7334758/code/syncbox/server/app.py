"""HTTP layer: request routing and the threaded server."""

from __future__ import annotations

import json
from dataclasses import asdict
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable, Iterator
from urllib.parse import unquote_to_bytes

from .. import __version__
from .config import ServerConfig
from .storage import BlobStore, InvalidKey, parse_key

# Unread request bodies up to this size are drained so the keep-alive
# connection stays usable; anything larger closes the connection instead.
_MAX_DISCARD_BYTES = 1 << 20

_READ_CHUNK = 64 * 1024
# Longest chunk-size or trailer line accepted in a chunked request body.
_MAX_CHUNK_LINE = 64 * 1024


class BadRequest(Exception):
    """The request body is malformed; the connection can't be reused."""


class SyncboxServer(ThreadingHTTPServer):
    daemon_threads = True
    # listen() backlog. The stdlib default of 5 drops connections when a
    # burst of clients (e.g. parallel uploads) connects at once.
    request_queue_size = 128

    def __init__(self, config: ServerConfig) -> None:
        self.config = config
        self.store = BlobStore(config.data_dir)
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
        "/blobs": {"GET": "handle_list_blobs"},
    }
    # /blobs/{key}: method -> handler method name, called with the raw key.
    # Other methods fall through to 404.
    BLOB_PREFIX = "/blobs/"
    BLOB_ROUTES: dict[str, str] = {
        "GET": "handle_get_blob",
        "HEAD": "handle_get_blob",
        "PUT": "handle_put_blob",
        "DELETE": "handle_delete_blob",
    }

    # --- handlers -------------------------------------------------------

    def handle_healthz(self) -> None:
        self.send_json(HTTPStatus.OK, {"status": "ok"})

    def handle_list_blobs(self) -> None:
        self.send_json(HTTPStatus.OK, [asdict(meta) for meta in self.server.store.list()])

    def handle_get_blob(self, raw_key: str) -> None:
        try:
            key = self._parse_blob_key(raw_key)
            opened = self.server.store.open(key)
        except InvalidKey as exc:
            self.send_error_json(HTTPStatus.BAD_REQUEST, str(exc))
            return
        if opened is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, "blob not found")
            return
        blob, size = opened
        with blob:
            self.send_headers(HTTPStatus.OK, size, "application/octet-stream")
            if self.command == "HEAD":
                return
            remaining = size
            while remaining > 0:
                chunk = blob.read(min(remaining, _READ_CHUNK))
                if not chunk:
                    # The file shrank after the headers went out: the response
                    # can't be completed, so don't let the client wait for it.
                    self.close_connection = True
                    return
                self.wfile.write(chunk)
                remaining -= len(chunk)

    def handle_put_blob(self, raw_key: str) -> None:
        try:
            key = self._parse_blob_key(raw_key)
            result = self.server.store.put(key, self._read_body())
        except InvalidKey as exc:
            self.send_error_json(HTTPStatus.BAD_REQUEST, str(exc))
            return
        except BadRequest as exc:
            self.close_connection = True
            self.send_error_json(HTTPStatus.BAD_REQUEST, str(exc))
            return
        self.send_json(HTTPStatus.CREATED, asdict(result))

    def handle_delete_blob(self, raw_key: str) -> None:
        try:
            key = self._parse_blob_key(raw_key)
            deleted = self.server.store.delete(key)
        except InvalidKey as exc:
            self.send_error_json(HTTPStatus.BAD_REQUEST, str(exc))
            return
        if not deleted:
            self.send_error_json(HTTPStatus.NOT_FOUND, "blob not found")
            return
        self.send_headers(HTTPStatus.NO_CONTENT, None)

    @staticmethod
    def _parse_blob_key(raw_key: str) -> str:
        # The request line was decoded as Latin-1, so this recovers its raw
        # bytes; percent-escapes and raw UTF-8 then decode alike.
        return parse_key(unquote_to_bytes(raw_key.encode("latin-1")))

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

        if path.startswith(self.BLOB_PREFIX) and self.command in self.BLOB_ROUTES:
            blob_handler: Callable[[str], None] = getattr(self, self.BLOB_ROUTES[self.command])
            blob_handler(path[len(self.BLOB_PREFIX):])
            return

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

    # --- request body ---------------------------------------------------

    def _read_body(self) -> Iterator[bytes]:
        """Yield the request body in chunks; raise BadRequest if it is malformed."""
        self._body_consumed = True
        transfer_encoding = self.headers.get_all("Transfer-Encoding")
        if transfer_encoding:
            codings = [c.strip().lower() for v in transfer_encoding for c in v.split(",")]
            if codings != ["chunked"]:
                raise BadRequest("unsupported Transfer-Encoding")
            if "Content-Length" in self.headers:
                # Ambiguous framing (RFC 9112 6.1): honour chunked, then close.
                self.close_connection = True
            yield from self._read_chunked_body()
            return

        raw_lengths = self.headers.get_all("Content-Length", [])
        lengths = {v.strip() for raw in raw_lengths for v in raw.split(",")}
        if not lengths:
            return  # no framing headers: the body is empty
        length = lengths.pop()
        if lengths or not (length.isascii() and length.isdigit()):
            raise BadRequest("invalid Content-Length")
        yield from self._read_exactly(int(length))

    def _read_exactly(self, remaining: int) -> Iterator[bytes]:
        while remaining > 0:
            chunk = self.rfile.read(min(remaining, _READ_CHUNK))
            if not chunk:
                raise BadRequest("request body is shorter than declared")
            remaining -= len(chunk)
            yield chunk

    def _read_chunked_line(self) -> bytes:
        line = self.rfile.readline(_MAX_CHUNK_LINE + 1)
        if len(line) > _MAX_CHUNK_LINE or not line.endswith(b"\n"):
            raise BadRequest("malformed chunked body")
        return line.rstrip(b"\r\n")

    def _read_chunked_body(self) -> Iterator[bytes]:
        while True:
            size_field = self._read_chunked_line().split(b";", 1)[0].strip()
            # int(..., 16) alone would also take "0x", "+", "_" and spaces.
            if not size_field or size_field.strip(b"0123456789abcdefABCDEF"):
                raise BadRequest("malformed chunked body")
            size = int(size_field, 16)
            if size == 0:
                break
            yield from self._read_exactly(size)
            if self._read_chunked_line():
                raise BadRequest("malformed chunked body")
        while self._read_chunked_line():  # skip trailer fields
            pass

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

    def send_error(self, code: int, message: str | None = None, explain: str | None = None) -> None:
        # The stdlib answers request lines over 64 KiB with 414, which the API
        # contract doesn't list. Such a URL can only carry an unusable key
        # (far beyond PATH_MAX), so report it as a bad request instead.
        if code == HTTPStatus.REQUEST_URI_TOO_LONG:
            code, message = HTTPStatus.BAD_REQUEST, "Request line too long"
        super().send_error(code, message, explain)

    def send_body(
        self,
        status: HTTPStatus,
        body: bytes = b"",
        content_type: str | None = None,
        headers: dict[str, str] | None = None,
    ) -> None:
        self.send_headers(status, len(body), content_type, headers)
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_headers(
        self,
        status: HTTPStatus,
        content_length: int | None,
        content_type: str | None = None,
        headers: dict[str, str] | None = None,
    ) -> None:
        """Send the status line and headers; the caller writes the body.

        ``content_length`` is None for responses that have no body by
        definition (204), which must not carry Content-Length.
        """
        self._discard_unread_body()
        self.send_response(status)
        if content_type is not None:
            self.send_header("Content-Type", content_type)
        if content_length is not None:
            self.send_header("Content-Length", str(content_length))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        if self.close_connection:
            self.send_header("Connection", "close")
        self.end_headers()

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
