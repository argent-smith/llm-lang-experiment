"""``syncbox pull``: download blobs that are missing locally or differ from the local file.

Blob keys come from the server and are not trusted: a key must be a relative
path of plain names (no ``..``, ``.``, empty or absolute components), and
the path is walked one directory at a time from ``<dir>`` without following
symbolic links, so neither a key nor a symlink inside ``<dir>`` can lead a
write outside it. As with push, symlinks and special files are not synced:
a key that leads to one is skipped with a warning.

A file is written to a temporary file in its directory, checked against the
SHA-256 the server listed and then renamed over the old version, so the
local file is always either the old version or the complete new one.
"""

from __future__ import annotations

import errno
import os
import secrets
import stat
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from .api import RemoteBlob, ServerClient, ServerError
from .errors import ClientError
from .local import file_sha256

# O_PATH: walking through a directory needs no read permission on it.
# O_NOFOLLOW: a symlink in place of a directory is not followed (open fails).
_DIR_FLAGS = os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
_TMP_FLAGS = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC


@dataclass
class PullResult:
    downloaded: list[str] = field(default_factory=list)
    unchanged: list[str] = field(default_factory=list)
    skipped: list[str] = field(default_factory=list)


class _Skip(Exception):
    """The blob is left alone; the message says why."""


def is_safe_key(key: str) -> bool:
    """Whether ``key`` is a relative POSIX path of plain names that can be a local file name."""
    if not key or "\0" in key:
        return False
    try:
        key.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return all(part not in ("", ".", "..") for part in key.split("/"))


def _describe(exc: OSError) -> str:
    return exc.strerror or str(exc)


def pull(
    root: Path,
    client: ServerClient,
    report: Callable[[str], None],
    warn: Callable[[str], None],
) -> PullResult:
    """Download every blob whose SHA-256 differs from the file under ``root`` at its key.

    Files that already have the server's content are not downloaded again;
    local files with no blob are left alone. Calls ``report`` with a line
    per downloaded file and ``warn`` per skipped blob. Stops at the first
    failure (raising ClientError).
    """
    blobs = client.list_blobs()
    for blob in blobs:
        if not is_safe_key(blob.key):
            raise ClientError(f"server listed an invalid key {blob.key!r}; nothing was downloaded")
    try:
        root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    except OSError as exc:
        raise ClientError(f"cannot open directory {str(root)!r}: {_describe(exc)}") from None
    result = PullResult()
    try:
        for blob in blobs:
            try:
                outcome = _pull_blob(root_fd, blob, client)
            except _Skip as skip:
                warn(f"skipping {blob.key!r}: {skip}")
                result.skipped.append(blob.key)
                continue
            if outcome is None:
                result.unchanged.append(blob.key)
            else:
                result.downloaded.append(blob.key)
                report(f"{outcome} {blob.key}")
    finally:
        os.close(root_fd)
    return result


def _pull_blob(root_fd: int, blob: RemoteBlob, client: ServerClient) -> str | None:
    """Bring the file at ``blob.key`` up to date: "added", "updated", or None if it already was."""
    *dirs, name = blob.key.split("/")
    parent_fd = _open_parent(root_fd, dirs, blob.key, create=False)
    existing = None
    try:
        if parent_fd is not None:
            existing = _existing_file(parent_fd, name, blob.key)
            if (
                existing is not None
                and existing.st_size == blob.size
                and file_sha256(blob.key, name, dir_fd=parent_fd) == blob.sha256
            ):
                return None
        else:
            parent_fd = _open_parent(root_fd, dirs, blob.key, create=True)
        _download(client, blob, parent_fd, name, None if existing is None else existing.st_mode)
    finally:
        if parent_fd is not None:
            os.close(parent_fd)
    return "added" if existing is None else "updated"


def _open_parent(root_fd: int, dirs: list[str], key: str, create: bool) -> int | None:
    """A descriptor of the directory ``dirs`` under ``root_fd``, walked without following symlinks.

    Missing directories are created if ``create`` is set; otherwise None is
    returned for a directory that doesn't exist.
    """
    fd = os.dup(root_fd)
    for depth, name in enumerate(dirs, 1):
        try:
            child = _open_dir(fd, name, create)
        except OSError as exc:
            where = "/".join(dirs[:depth])
            if exc.errno in (errno.ELOOP, errno.ENOTDIR):
                if _is_symlink(fd, name):
                    raise _Skip(f"{where!r} is a symbolic link") from None
                raise ClientError(f"cannot write {key!r}: {where!r} is not a directory") from None
            raise ClientError(f"cannot write {key!r}: {where!r}: {_describe(exc)}") from None
        finally:
            os.close(fd)
        if child is None:
            return None
        fd = child
    return fd


def _is_symlink(parent_fd: int, name: str) -> bool:
    try:
        return stat.S_ISLNK(os.stat(name, dir_fd=parent_fd, follow_symlinks=False).st_mode)
    except OSError:
        return False


def _open_dir(parent_fd: int, name: str, create: bool) -> int | None:
    while True:
        try:
            return os.open(name, _DIR_FLAGS, dir_fd=parent_fd)
        except FileNotFoundError:
            if not create:
                return None
        try:
            os.mkdir(name, dir_fd=parent_fd)
        except FileExistsError:
            pass  # created meanwhile; open it


def _existing_file(parent_fd: int, name: str, key: str) -> os.stat_result | None:
    """What is at ``name`` now: a regular file's stat, or None if nothing is."""
    try:
        st = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise ClientError(f"cannot read {key!r}: {_describe(exc)}") from None
    if stat.S_ISLNK(st.st_mode):
        raise _Skip("symbolic link")
    if stat.S_ISDIR(st.st_mode):
        raise ClientError(f"cannot write {key!r}: a directory is in the way")
    if not stat.S_ISREG(st.st_mode):
        raise _Skip("not a regular file")
    return st


def _download(client: ServerClient, blob: RemoteBlob, parent_fd: int, name: str, mode: int | None) -> None:
    """Download ``blob`` and put it at ``name`` in ``parent_fd``, keeping the permissions ``mode``."""
    key = blob.key
    # Fixed length, so the temporary name fits wherever ``name`` does.
    tmp_name = f".syncbox-{secrets.token_hex(8)}.tmp"
    try:
        fd = os.open(tmp_name, _TMP_FLAGS, 0o666, dir_fd=parent_fd)
    except OSError as exc:
        raise ClientError(f"cannot write {key!r}: {_describe(exc)}") from None
    renamed = False
    try:
        with open(fd, "wb") as f:
            sha256 = client.get_blob(key, blob.size, f.write)
            if sha256 is None:
                raise _Skip("no longer on the server")
            if sha256 != blob.sha256:
                raise ServerError(
                    f"cannot download {key!r}: received sha256 {sha256}, listed {blob.sha256}"
                    " (changed on the server meanwhile?)"
                )
            if mode is not None:
                os.fchmod(fd, stat.S_IMODE(mode) & 0o777)
            f.flush()
            os.fsync(fd)
        os.replace(tmp_name, name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        renamed = True
    except OSError as exc:
        raise ClientError(f"cannot write {key!r}: {_describe(exc)}") from None
    finally:
        if not renamed:
            try:
                os.unlink(tmp_name, dir_fd=parent_fd)
            except OSError:
                pass
