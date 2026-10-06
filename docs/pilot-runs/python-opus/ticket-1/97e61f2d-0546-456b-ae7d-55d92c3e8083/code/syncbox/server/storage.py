"""Blob storage on the local filesystem.

Layout under the data directory:

- ``blobs/<key>`` — blob contents; the ``/``-separated components of the key
  map to nested directories.
- ``tmp/`` — uploads in progress. A blob is written here in full and then
  renamed into ``blobs/``, so readers never see a partially written blob.
"""

from __future__ import annotations

import errno
import hashlib
import os
import stat
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

# Longest file name component Linux filesystems accept (NAME_MAX), in bytes.
_MAX_COMPONENT_BYTES = 255
# Longest path the kernel accepts (PATH_MAX, including the trailing NUL).
_MAX_PATH_BYTES = 4096

# errno values from creating a blob that mean its key cannot be stored as a
# file here: the name is too long or not representable on this filesystem,
# or the key collides with an existing blob or directory ("a" vs "a/b").
_KEY_ERRNOS = frozenset({
    errno.EEXIST,
    errno.EILSEQ,
    errno.EINVAL,
    errno.EISDIR,
    errno.ENAMETOOLONG,
    errno.ENOTDIR,
    errno.ENOTEMPTY,
})


class InvalidKey(Exception):
    """The key is not a valid blob key or cannot be stored on this server."""


def validate_key(key: str) -> None:
    """Raise InvalidKey unless ``key`` is a relative POSIX path of plain names."""
    if not key:
        raise InvalidKey("key is empty")
    try:
        encoded = key.encode("utf-8")
    except UnicodeEncodeError:
        raise InvalidKey("key is not valid Unicode") from None
    if b"\0" in encoded:
        raise InvalidKey("key contains a NUL character")
    if key.startswith("/"):
        raise InvalidKey("key must be a relative path")
    for part in key.split("/"):
        if part in ("", ".", ".."):
            raise InvalidKey(f"key contains an invalid path component {part!r}")
        if len(part.encode("utf-8")) > _MAX_COMPONENT_BYTES:
            raise InvalidKey("key contains a path component that is too long")


def parse_key(raw: bytes) -> str:
    """Decode a key taken (already percent-decoded) from a URL and validate it."""
    try:
        key = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise InvalidKey("key is not valid UTF-8") from None
    validate_key(key)
    return key


@dataclass(frozen=True)
class PutResult:
    key: str
    sha256: str
    size: int


@dataclass(frozen=True)
class BlobMeta:
    key: str
    size: int
    sha256: str
    modified_at: str


def _format_mtime(mtime: float) -> str:
    return datetime.fromtimestamp(mtime, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


class BlobStore:
    def __init__(self, data_dir: Path) -> None:
        self.root = data_dir / "blobs"
        self.tmp_dir = data_dir / "tmp"

    def _path(self, key: str) -> Path:
        return self.root.joinpath(*key.split("/"))

    def put(self, key: str, chunks: Iterable[bytes]) -> PutResult:
        """Store the concatenated ``chunks`` under ``key``, replacing any old blob.

        ``key`` must have passed validate_key. Raises InvalidKey if the key
        cannot be stored as a file; exceptions raised by ``chunks`` propagate.
        """
        target = self._path(key)
        # Checked up front: mkdir(parents=True) would otherwise create part of
        # the directory chain before failing.
        if len(os.fsencode(target)) >= _MAX_PATH_BYTES:
            raise InvalidKey("key is too long")
        self.tmp_dir.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(dir=self.tmp_dir, prefix="upload-")
        try:
            digest = hashlib.sha256()
            size = 0
            with os.fdopen(fd, "wb") as tmp:
                for chunk in chunks:
                    tmp.write(chunk)
                    digest.update(chunk)
                    size += len(chunk)
                tmp.flush()
                os.fsync(tmp.fileno())
            try:
                target.parent.mkdir(parents=True, exist_ok=True)
                os.replace(tmp_name, target)
            except OSError as exc:
                if exc.errno in _KEY_ERRNOS:
                    raise InvalidKey(f"key cannot be stored: {exc.strerror}") from None
                raise
        finally:
            Path(tmp_name).unlink(missing_ok=True)
        return PutResult(key=key, sha256=digest.hexdigest(), size=size)

    def list(self) -> list[BlobMeta]:
        """Metadata of all stored blobs, sorted by key."""
        blobs = []
        for dirpath, _dirnames, filenames in os.walk(self.root):
            rel_dir = Path(dirpath).relative_to(self.root).as_posix()
            for name in filenames:
                key = name if rel_dir == "." else f"{rel_dir}/{name}"
                try:
                    validate_key(key)
                except InvalidKey:
                    continue  # not something PUT could have created
                meta = self._describe(key, os.path.join(dirpath, name))
                if meta is not None:
                    blobs.append(meta)
        blobs.sort(key=lambda meta: meta.key)
        return blobs

    def _describe(self, key: str, path: str) -> BlobMeta | None:
        # O_NONBLOCK keeps a stray FIFO from blocking the open; anything that
        # is not a regular file (or vanished meanwhile) is skipped.
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except OSError:
            return None
        with os.fdopen(fd, "rb") as blob:
            st = os.fstat(blob.fileno())
            if not stat.S_ISREG(st.st_mode):
                return None
            sha256 = hashlib.file_digest(blob, "sha256").hexdigest()
        return BlobMeta(
            key=key,
            size=st.st_size,
            sha256=sha256,
            modified_at=_format_mtime(st.st_mtime),
        )
