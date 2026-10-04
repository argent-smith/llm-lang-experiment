"""Blob storage on the local filesystem.

Layout under the data directory:

- ``blobs/<key>`` — blob contents; the ``/``-separated components of the key
  map to nested directories.
- ``tmp/`` — uploads in progress. A blob is written here in full and then
  renamed into ``blobs/``, so readers never see a partially written blob.

Directories under ``blobs/`` exist only to hold blobs: deleting a blob also
removes the directories it leaves empty, so a deleted "a/b" doesn't keep
blocking a later put of "a".
"""

from __future__ import annotations

import errno
import hashlib
import os
import stat
import tempfile
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import BinaryIO, Iterable

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

# errno values from looking up a blob that mean there is none under the key:
# the path is missing, runs through a file ("a/b" when "a" is a blob), or is
# too long to exist at all.
_MISSING_ERRNOS = frozenset({
    errno.ENOENT,
    errno.ENOTDIR,
    errno.ENAMETOOLONG,
    errno.ELOOP,
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
        # Serialises changes to the directory tree under root, so a delete
        # can't remove a directory that a concurrent put has just created
        # but not yet moved its blob into.
        self._tree_lock = threading.Lock()

    def _path(self, key: str) -> Path:
        return self.root.joinpath(*key.split("/"))

    def _storable_path(self, key: str) -> Path:
        """The path of ``key``; raise InvalidKey if it exceeds PATH_MAX."""
        path = self._path(key)
        if len(os.fsencode(path)) >= _MAX_PATH_BYTES:
            raise InvalidKey("key is too long")
        return path

    def put(self, key: str, chunks: Iterable[bytes]) -> PutResult:
        """Store the concatenated ``chunks`` under ``key``, replacing any old blob.

        ``key`` must have passed validate_key. Raises InvalidKey if the key
        cannot be stored as a file; exceptions raised by ``chunks`` propagate.
        """
        # The length is checked up front: mkdir(parents=True) would otherwise
        # create part of the directory chain before failing.
        target = self._storable_path(key)
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
                with self._tree_lock:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    os.replace(tmp_name, target)
            except OSError as exc:
                if exc.errno in _KEY_ERRNOS:
                    raise InvalidKey(f"key cannot be stored: {exc.strerror}") from None
                raise
        finally:
            Path(tmp_name).unlink(missing_ok=True)
        return PutResult(key=key, sha256=digest.hexdigest(), size=size)

    def delete(self, key: str) -> bool:
        """Delete the blob stored under ``key``.

        ``key`` must have passed validate_key. Returns False if there is no
        such blob; as with open(), only a regular file counts as one. Raises
        InvalidKey for a key that put() would reject as too long.
        """
        target = self._storable_path(key)
        with self._tree_lock:
            try:
                if not stat.S_ISREG(os.lstat(target).st_mode):
                    return False
                os.unlink(target)
            except OSError as exc:
                if exc.errno in _MISSING_ERRNOS:
                    return False
                raise
            self._prune_empty_dirs(target.parent)
        return True

    def _prune_empty_dirs(self, directory: Path) -> None:
        """Remove ``directory`` and its ancestors below root while they are empty."""
        while directory != self.root:
            try:
                directory.rmdir()
            except OSError:
                return  # not empty
            directory = directory.parent

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

    def open(self, key: str) -> tuple[BinaryIO, int] | None:
        """Open the blob stored under ``key`` for reading.

        ``key`` must have passed validate_key. Returns the open file and its
        size, or None if there is no such blob.
        """
        opened = _open_regular(self._path(key))
        if opened is None:
            return None
        blob, st = opened
        return blob, st.st_size

    def _describe(self, key: str, path: str) -> BlobMeta | None:
        opened = _open_regular(path)
        if opened is None:
            return None
        blob, st = opened
        with blob:
            sha256 = hashlib.file_digest(blob, "sha256").hexdigest()
        return BlobMeta(
            key=key,
            size=st.st_size,
            sha256=sha256,
            modified_at=_format_mtime(st.st_mtime),
        )


def _open_regular(path: str | Path) -> tuple[BinaryIO, os.stat_result] | None:
    """Open ``path`` for reading if it is a regular file, else return None."""
    # O_NONBLOCK keeps a stray FIFO from blocking the open. Anything that is
    # not a regular file, is missing (or vanished meanwhile), or whose path
    # can't be resolved (runs through a file, too long) is not a blob.
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    # Checked on the bare descriptor: os.fdopen() refuses directories.
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        os.close(fd)
        return None
    return os.fdopen(fd, "rb"), st
