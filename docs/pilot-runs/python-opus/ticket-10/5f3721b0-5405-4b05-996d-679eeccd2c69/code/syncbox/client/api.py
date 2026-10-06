"""HTTP access to a Syncbox server (see syncbox-openapi.yaml)."""

from __future__ import annotations

import hashlib
import http.client
import json
import os
import socket
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, BinaryIO, Callable, Iterator
from urllib.parse import quote, urlsplit

from .errors import ClientError

# Seconds to wait for a TCP connection to the server.
CONNECT_TIMEOUT = 10.0
# Seconds of silence on an open connection before giving up. Generous, as
# the server hashes every blob to answer GET /blobs.
READ_TIMEOUT = 120.0
# A keep-alive connection idle for longer than this is replaced rather than
# reused, so a server that has dropped it meanwhile doesn't fail the request.
_MAX_IDLE = 5.0

_CHUNK = 64 * 1024


class ServerError(ClientError):
    """The server could not be reached or gave an unusable answer."""


@dataclass(frozen=True)
class ServerURL:
    host: str
    port: int
    base_path: str  # "" or "/prefix", without a trailing slash
    text: str  # as given by the user, for messages


def parse_server_url(raw: str) -> ServerURL:
    """Parse ``http://host[:port][/prefix]``; raises ValueError if it isn't one."""
    problem = f"invalid server URL {raw!r}: expected http://host[:port]"
    parts = urlsplit(raw)
    scheme = parts.scheme.lower()
    if scheme == "https":
        raise ValueError(f"unsupported server URL {raw!r}: only http:// is supported")
    if scheme != "http":
        raise ValueError(problem)
    try:
        port = parts.port
    except ValueError:
        raise ValueError(f"{problem} (bad port)") from None
    if not parts.hostname or parts.username is not None or parts.query or parts.fragment:
        raise ValueError(problem)
    return ServerURL(
        host=parts.hostname,
        port=port or 80,
        base_path=parts.path.rstrip("/"),
        text=raw,
    )


@dataclass(frozen=True)
class RemoteBlob:
    key: str
    size: int
    sha256: str
    # None if the server didn't send a valid ISO 8601 time; only sync needs it.
    modified_at: datetime | None = None


def _parse_time(value: object) -> datetime | None:
    """An ISO 8601 time as an aware datetime (UTC if it has no offset), or None."""
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None else parsed.replace(tzinfo=timezone.utc)


def _parse_blob_list(body: bytes) -> list[RemoteBlob] | None:
    """The blobs listed in a GET /blobs response body, or None if it is malformed."""
    try:
        payload = json.loads(body)
    except ValueError:
        return None
    if not isinstance(payload, list):
        return None
    blobs = []
    for item in payload:
        if not (
            isinstance(item, dict)
            and isinstance(item.get("key"), str)
            and isinstance(item.get("sha256"), str)
            and isinstance(item.get("size"), int)
        ):
            return None
        blobs.append(RemoteBlob(
            key=item["key"],
            size=item["size"],
            sha256=item["sha256"],
            modified_at=_parse_time(item.get("modified_at")),
        ))
    return blobs


def _error_detail(status: int, reason: str, body: bytes) -> str:
    """``HTTP 400 Bad Request: <the server's error message, if any>``."""
    text = f"HTTP {status} {reason}".rstrip()
    try:
        message = json.loads(body).get("error")
    except (ValueError, AttributeError):
        message = None
    return f"{text}: {message}" if isinstance(message, str) and message else text


def _describe(exc: BaseException) -> str:
    if isinstance(exc, TimeoutError):
        return "timed out"
    if isinstance(exc, socket.gaierror):
        return f"cannot resolve host ({exc.strerror})"
    if isinstance(exc, OSError) and exc.strerror:
        return exc.strerror
    return str(exc) or type(exc).__name__


class _BodyError(Exception):
    """Reading the local file for a request body failed; the message says why."""


def _file_body(f: BinaryIO, size: int, digest: Any) -> Iterator[bytes]:
    """Exactly ``size`` bytes of ``f`` in chunks, fed to ``digest`` as they go.

    Raises _BodyError if the file turns out shorter or longer than ``size``.
    That happens before the last chunk is handed out, so the server never
    receives a complete body and keeps its old blob.
    """
    remaining = size
    try:
        while remaining > 0:
            chunk = f.read(min(_CHUNK, remaining))
            if not chunk:
                raise _BodyError("file shrank while it was being uploaded")
            remaining -= len(chunk)
            if remaining == 0 and f.read(1):
                raise _BodyError("file grew while it was being uploaded")
            digest.update(chunk)
            yield chunk
    except OSError as exc:
        raise _BodyError(_describe(exc)) from None


class _Connection(http.client.HTTPConnection):
    """Connects within CONNECT_TIMEOUT, then waits up to READ_TIMEOUT for data."""

    def connect(self) -> None:
        super().connect()
        self.sock.settimeout(READ_TIMEOUT)


class ServerClient:
    """Requests to one server over a reused (keep-alive) connection."""

    def __init__(self, url: ServerURL) -> None:
        self.url = url
        self._conn = _Connection(url.host, url.port, timeout=CONNECT_TIMEOUT)
        self._last_used = 0.0

    def close(self) -> None:
        self._conn.close()

    def __enter__(self) -> ServerClient:
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()

    def list_blobs(self) -> list[RemoteBlob]:
        status, reason, body = self._request("GET", "/blobs")
        if status != 200:
            raise ServerError(f"listing blobs failed: {_error_detail(status, reason, body)}")
        blobs = _parse_blob_list(body)
        if blobs is None:
            raise ServerError("listing blobs failed: malformed response from server")
        return blobs

    def put_blob(self, key: str, path: Path) -> str:
        """Upload the file at ``path`` as blob ``key``; returns the sha256 of the bytes sent.

        The file is read once, as it is sent, and the upload fails if the
        sha256 the server reports for the stored blob differs from that of
        the bytes sent.
        """
        try:
            # O_NONBLOCK: a file swapped for a FIFO since the scan can't block us.
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except OSError as exc:
            raise ClientError(f"cannot read {key!r}: {_describe(exc)}") from None
        digest = hashlib.sha256()
        with open(fd, "rb") as f:
            size = os.fstat(fd).st_size
            try:
                status, reason, body = self._request(
                    "PUT",
                    "/blobs/" + quote(key, safe="/"),
                    body=_file_body(f, size, digest),
                    headers={
                        "Content-Length": str(size),
                        "Content-Type": "application/octet-stream",
                    },
                )
            except _BodyError as exc:
                raise ClientError(f"cannot upload {key!r}: {exc}") from None
        if status not in (200, 201):
            raise ServerError(f"cannot upload {key!r}: {_error_detail(status, reason, body)}")
        try:
            stored = json.loads(body).get("sha256")
        except (ValueError, AttributeError):
            stored = None
        if stored is not None and stored != digest.hexdigest():
            raise ServerError(
                f"cannot upload {key!r}: server stored sha256 {stored}, sent {digest.hexdigest()}"
            )
        return digest.hexdigest()

    def get_blob(self, key: str, size: int, sink: Callable[[bytes], object]) -> str | None:
        """Download blob ``key``, listed as ``size`` bytes long, handing it to ``sink`` in chunks.

        Returns the sha256 of the bytes received, or None if the server has
        no such blob. Raises ServerError if the server can't be reached,
        answers with an error, or sends other than ``size`` bytes; part of
        the body may have gone to ``sink`` by then. Exceptions raised by
        ``sink`` propagate.
        """
        resp = self._send("GET", "/blobs/" + quote(key, safe="/"))
        digest = hashlib.sha256()
        try:
            if resp.status != 200:
                body = self._read_body(resp, key)
                if resp.status == 404:
                    return None
                raise ServerError(f"cannot download {key!r}: {_error_detail(resp.status, resp.reason, body)}")
            if resp.length is not None and resp.length != size:
                raise ServerError(f"cannot download {key!r}: server sent {resp.length} bytes, listed {size}")
            received = 0
            # Up to one byte more than listed is asked for, to notice a body that is too long.
            while chunk := self._read_body(resp, key, min(_CHUNK, size - received + 1)):
                received += len(chunk)
                if received > size:
                    raise ServerError(f"cannot download {key!r}: server sent more than the {size} bytes listed")
                digest.update(chunk)
                sink(chunk)
            if received != size:
                raise ServerError(f"cannot download {key!r}: body ended after {received} of {size} bytes")
        except BaseException:
            self._conn.close()
            raise
        self._last_used = time.monotonic()
        return digest.hexdigest()

    @staticmethod
    def _read_body(resp: http.client.HTTPResponse, key: str, amount: int | None = None) -> bytes:
        try:
            return resp.read(amount)
        except (OSError, http.client.HTTPException) as exc:
            raise ServerError(f"cannot download {key!r}: {_describe(exc)}") from None

    def _request(
        self,
        method: str,
        path: str,
        body: bytes | Iterator[bytes] | None = None,
        headers: dict[str, str] | None = None,
    ) -> tuple[int, str, bytes]:
        """Send a request; returns (status, reason, response body).

        Raises ServerError if the server can't be reached or the exchange
        breaks off. Exceptions raised by ``body`` propagate. Either way the
        connection is closed; the next request reopens it.
        """
        resp = self._send(method, path, body, headers)
        try:
            data = resp.read()
        except (OSError, http.client.HTTPException) as exc:
            self._conn.close()
            raise ServerError(f"cannot reach server {self.url.text}: {_describe(exc)}") from None
        except BaseException:
            self._conn.close()
            raise
        self._last_used = time.monotonic()
        return resp.status, resp.reason, data

    def _send(
        self,
        method: str,
        path: str,
        body: bytes | Iterator[bytes] | None = None,
        headers: dict[str, str] | None = None,
    ) -> http.client.HTTPResponse:
        """Send a request and read the response head; the caller reads the body.

        Raises as _request() does.
        """
        if time.monotonic() - self._last_used > _MAX_IDLE:
            self._conn.close()
        try:
            self._conn.request(method, self.url.base_path + path, body=body, headers=headers or {})
            return self._conn.getresponse()
        except (OSError, http.client.HTTPException) as exc:
            self._conn.close()
            raise ServerError(f"cannot reach server {self.url.text}: {_describe(exc)}") from None
        except BaseException:
            self._conn.close()
            raise
