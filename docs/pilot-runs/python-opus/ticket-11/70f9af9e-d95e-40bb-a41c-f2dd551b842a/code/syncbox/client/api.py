"""HTTP access to a Syncbox server (see syncbox-openapi.yaml)."""

from __future__ import annotations

import hashlib
import http.client
import json
import os
import socket
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, BinaryIO, Callable, Iterator
from urllib.parse import quote, urlsplit

from .errors import ClientError

# Seconds to resolve the server's name and open a TCP connection to it.
CONNECT_TIMEOUT = 10.0
# Seconds of silence on an open connection before giving up. Generous, as
# the server hashes every blob to answer GET /blobs.
READ_TIMEOUT = 60.0
# A keep-alive connection idle for longer than this is replaced rather than
# reused, so a server that has dropped it meanwhile doesn't fail the request.
_MAX_IDLE = 5.0

_CHUNK = 64 * 1024


class ServerError(ClientError):
    """The server could not be reached or gave an unusable answer."""


class ServerUnreachable(ServerError):
    """No connection to the server could be opened.

    Once that has happened, a ServerClient fails every further request
    straight away with this too, rather than waiting out the same failure
    once per file.
    """


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
    if isinstance(exc, OSError) and exc.strerror:
        return exc.strerror
    return str(exc) or type(exc).__name__


class _ResolveTimeout(TimeoutError):
    """Resolving the server's name took longer than CONNECT_TIMEOUT."""


def _resolve(host: str, port: int, timeout: float) -> list[tuple[Any, ...]]:
    """getaddrinfo() for a TCP connection, giving up after ``timeout`` seconds.

    getaddrinfo() itself has no timeout, so it runs in a daemon thread,
    which is left behind (and can't keep the process alive) if it hangs.
    """
    outcome: list[Any] = []
    done = threading.Event()

    def run() -> None:
        try:
            outcome.append(socket.getaddrinfo(host, port, type=socket.SOCK_STREAM))
        except BaseException as exc:  # handed over to the caller
            outcome.append(exc)
        done.set()

    threading.Thread(target=run, name="syncbox-resolve", daemon=True).start()
    if not done.wait(timeout):
        raise _ResolveTimeout()
    if isinstance(outcome[0], BaseException):
        raise outcome[0]
    return outcome[0]


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
    """Resolves and connects within CONNECT_TIMEOUT, then waits up to READ_TIMEOUT for data."""

    def connect(self) -> None:
        deadline = time.monotonic() + CONNECT_TIMEOUT
        error: OSError | None = None
        for family, kind, proto, _name, address in _resolve(self.host, self.port, CONNECT_TIMEOUT):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("timed out")
            sock = socket.socket(family, kind, proto)
            try:
                sock.settimeout(remaining)
                sock.connect(address)
            except OSError as exc:
                sock.close()
                error = exc
                continue
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            sock.settimeout(READ_TIMEOUT)
            self.sock = sock
            return
        raise error if error is not None else OSError(f"no address found for {self.host!r}")


class ServerClient:
    """Requests to one server over a reused (keep-alive) connection."""

    def __init__(self, url: ServerURL) -> None:
        self.url = url
        self._conn = _Connection(url.host, url.port, timeout=CONNECT_TIMEOUT)
        self._last_used = 0.0
        # Why no connection could be opened, once that has happened.
        self.unreachable: str | None = None

    def close(self) -> None:
        self._conn.close()

    def __enter__(self) -> ServerClient:
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()

    def list_blobs(self) -> list[RemoteBlob]:
        status, reason, body = self._request("GET", "/blobs", what="")
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
                    what=f"cannot upload {key!r}: ",
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
        what = f"cannot download {key!r}: "
        resp = self._send("GET", "/blobs/" + quote(key, safe="/"), what)
        digest = hashlib.sha256()
        try:
            if resp.status != 200:
                body = self._read_body(resp, what)
                if resp.status == 404:
                    return None
                raise ServerError(f"cannot download {key!r}: {_error_detail(resp.status, resp.reason, body)}")
            if resp.length is not None and resp.length != size:
                raise ServerError(f"cannot download {key!r}: server sent {resp.length} bytes, listed {size}")
            received = 0
            # Up to one byte more than listed is asked for, to notice a body that is too long.
            while chunk := self._read_body(resp, what, min(_CHUNK, size - received + 1)):
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

    def _read_body(self, resp: http.client.HTTPResponse, what: str, amount: int | None = None) -> bytes:
        try:
            return resp.read(amount)
        except (OSError, http.client.HTTPException) as exc:
            raise ServerError(what + self._broken(exc)) from None

    def _request(
        self,
        method: str,
        path: str,
        what: str,
        body: bytes | Iterator[bytes] | None = None,
        headers: dict[str, str] | None = None,
    ) -> tuple[int, str, bytes]:
        """Send a request; returns (status, reason, response body).

        ``what`` starts the message of a failure (e.g. "cannot upload 'a': ").
        Raises ServerUnreachable if no connection to the server can be
        opened, ServerError if the exchange breaks off or times out.
        Exceptions raised by ``body`` propagate. Either way the connection
        is closed; the next request reopens it.
        """
        resp = self._send(method, path, what, body, headers)
        try:
            data = resp.read()
        except (OSError, http.client.HTTPException) as exc:
            self._conn.close()
            raise ServerError(what + self._broken(exc)) from None
        except BaseException:
            self._conn.close()
            raise
        self._last_used = time.monotonic()
        return resp.status, resp.reason, data

    def _send(
        self,
        method: str,
        path: str,
        what: str,
        body: bytes | Iterator[bytes] | None = None,
        headers: dict[str, str] | None = None,
    ) -> http.client.HTTPResponse:
        """Send a request and read the response head; the caller reads the body.

        Raises as _request() does.
        """
        if self.unreachable is not None:
            raise ServerUnreachable(f"{what}not attempted, the server is unreachable")
        if time.monotonic() - self._last_used > _MAX_IDLE:
            self._conn.close()
        if self._conn.sock is None:
            try:
                self._conn.connect()
            except OSError as exc:
                self._conn.close()
                self.unreachable = self._unreachable(exc)
                raise ServerUnreachable(what + self.unreachable) from None
            except BaseException:
                self._conn.close()
                raise
        try:
            self._conn.request(method, self.url.base_path + path, body=body, headers=headers or {})
            return self._conn.getresponse()
        except (OSError, http.client.HTTPException) as exc:
            self._conn.close()
            raise ServerError(what + self._broken(exc)) from None
        except BaseException:
            self._conn.close()
            raise

    def _unreachable(self, exc: OSError) -> str:
        """Why opening a connection failed."""
        if isinstance(exc, _ResolveTimeout):
            problem = f"cannot resolve host {self.url.host!r} (no answer within {CONNECT_TIMEOUT:g} s)"
        elif isinstance(exc, socket.gaierror):
            problem = f"cannot resolve host {self.url.host!r} ({_describe(exc)})"
        elif isinstance(exc, TimeoutError):
            problem = f"connection timed out after {CONNECT_TIMEOUT:g} s"
        else:
            problem = _describe(exc)
        return f"cannot reach server {self.url.text}: {problem}"

    def _broken(self, exc: OSError | http.client.HTTPException) -> str:
        """Why an exchange on an open connection failed."""
        if isinstance(exc, TimeoutError):
            return f"timed out: no response from server {self.url.text} within {READ_TIMEOUT:g} s"
        if isinstance(exc, http.client.RemoteDisconnected):
            return f"server {self.url.text} closed the connection without answering"
        if isinstance(exc, http.client.IncompleteRead):
            return f"connection to server {self.url.text} broke off: response incomplete"
        return f"connection to server {self.url.text} failed: {_describe(exc)}"
