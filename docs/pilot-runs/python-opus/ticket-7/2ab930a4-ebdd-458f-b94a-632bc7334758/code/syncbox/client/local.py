"""The local side of a sync: files under a directory and their hashes.

A file's key is its path relative to the directory, with ``/`` separators
(``docs/readme.txt``) — the same convention the server uses for blob keys.

Only regular files are synced. Symbolic links (to files or directories) and
special files (FIFOs, sockets, devices) are skipped with a warning rather
than followed: a link may point outside the directory, and a FIFO would
block the read.
"""

from __future__ import annotations

import hashlib
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .errors import ClientError


@dataclass(frozen=True)
class LocalFile:
    key: str
    path: Path
    sha256: str


def _describe_error(exc: OSError) -> str:
    return exc.strerror or str(exc)


def key_for(rel_path: str) -> str:
    """The blob key for a ``/``-separated path relative to the directory.

    Raises ClientError if the path can't be a key: names that are not valid
    UTF-8 reach Python as lone surrogates and can't be sent to the server.
    """
    try:
        rel_path.encode("utf-8")
    except UnicodeEncodeError:
        shown = os.fsencode(rel_path).decode("utf-8", "backslashreplace")
        raise ClientError(f"cannot sync '{shown}': file name is not valid UTF-8") from None
    return rel_path


def find_files(root: Path, warn: Callable[[str], None]) -> list[tuple[str, Path]]:
    """``(key, path)`` of every regular file under ``root``, sorted by key."""
    found: list[tuple[str, Path]] = []
    # (directory, its key prefix); an explicit stack, as trees can be deeper
    # than Python's recursion limit.
    pending: list[tuple[Path, str]] = [(root, "")]
    while pending:
        directory, prefix = pending.pop()
        try:
            with os.scandir(directory) as it:
                entries = list(it)
        except OSError as exc:
            where = repr(prefix.rstrip("/")) if prefix else str(root)
            raise ClientError(f"cannot read directory {where}: {_describe_error(exc)}") from None
        for entry in entries:
            rel = prefix + entry.name
            try:
                if entry.is_symlink():
                    warn(f"skipping {rel!r}: symbolic link")
                elif entry.is_dir(follow_symlinks=False):
                    pending.append((Path(entry.path), rel + "/"))
                elif entry.is_file(follow_symlinks=False):
                    found.append((key_for(rel), Path(entry.path)))
                else:
                    warn(f"skipping {rel!r}: not a regular file")
            except OSError as exc:
                raise ClientError(f"cannot read {rel!r}: {_describe_error(exc)}") from None
    found.sort()
    return found


def file_sha256(key: str, path: Path) -> str:
    try:
        # O_NONBLOCK: a file swapped for a FIFO since the scan can't block us.
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with open(fd, "rb") as f:
            return hashlib.file_digest(f, "sha256").hexdigest()
    except OSError as exc:
        raise ClientError(f"cannot read {key!r}: {_describe_error(exc)}") from None


def scan(root: Path, warn: Callable[[str], None]) -> list[LocalFile]:
    """Every regular file under ``root`` with its SHA-256, sorted by key."""
    return [LocalFile(key, path, file_sha256(key, path)) for key, path in find_files(root, warn)]
