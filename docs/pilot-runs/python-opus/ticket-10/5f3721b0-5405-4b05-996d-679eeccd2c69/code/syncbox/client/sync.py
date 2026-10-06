"""``syncbox sync``: push and pull in one pass, resolving conflicts by modification time.

Files are matched by key and compared by SHA-256, as push and pull compare
them. For a file that differs between ``<dir>`` and the server:

- present on one side only: it is copied to the other (uploaded or
  downloaded). Nothing is ever deleted, on either side: a file deleted on
  one side comes back from the other.
- present on both, and one side still has the content recorded at the last
  sync (see state.py): only the other side changed it, so that version is
  copied over.
- present on both, and neither side has the recorded content (a conflict:
  both changed it since): the version with the later modification time —
  the local file's mtime or the blob's ``modified_at`` — wins; on a tie the
  local version does.
- present on both with no recorded content at all (the first sync, or a
  file created on both sides since): neither side is known to be
  unchanged, so the same rule decides.

Downloads are written as pull writes them, and a local file that changes
between being hashed and being replaced is skipped rather than overwritten.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from .api import RemoteBlob, ServerClient
from .errors import ClientError
from .local import LocalFile, scan
from .pull import Skip, is_safe_key, open_root, pull_blob


@dataclass
class SyncResult:
    uploaded: list[str] = field(default_factory=list)
    downloaded: list[str] = field(default_factory=list)
    unchanged: list[str] = field(default_factory=list)
    conflicts: list[str] = field(default_factory=list)  # also in uploaded or downloaded
    skipped: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class _Plan:
    upload: bool  # else download
    kind: str  # "new", "changed", "conflict" or "differs"
    note: str = ""


def sync(
    root: Path,
    client: ServerClient,
    state: dict[str, str],
    report: Callable[[str], None],
    warn: Callable[[str], None],
) -> SyncResult:
    """Bring ``root`` and the server to the same content.

    ``state`` is ``{key: sha256}`` as of the last sync; it is updated in
    place as files are found or made equal on both sides, so that it can be
    saved even if the sync stops part way. Calls ``report`` with a line per
    transferred file and ``warn`` per skipped one. Stops at the first
    failure (raising ClientError).
    """
    # The server is asked first, so an unreachable one fails before the
    # whole tree has been hashed.
    remote: dict[str, RemoteBlob] = {}
    for blob in client.list_blobs():
        if is_safe_key(blob.key):
            remote[blob.key] = blob
        else:
            warn(f"skipping {blob.key!r}: not a valid key for a local file")
    local = {file.key: file for file in scan(root, warn)}

    for key in [key for key in state if key not in local and key not in remote]:
        del state[key]

    result = SyncResult()
    root_fd = open_root(root)
    try:
        for key in sorted(local.keys() | remote.keys()):
            file, blob = local.get(key), remote.get(key)
            if file is not None and blob is not None and file.sha256 == blob.sha256:
                state[key] = file.sha256
                result.unchanged.append(key)
                continue
            plan = _plan(file, blob, state.get(key))
            try:
                if plan.upload:
                    assert file is not None
                    state[key] = client.put_blob(key, file.path)
                    result.uploaded.append(key)
                else:
                    assert blob is not None
                    if pull_blob(root_fd, blob, client, None if file is None else file.sha256) is None:
                        # Changed locally to the server's version meanwhile.
                        state[key] = blob.sha256
                        result.unchanged.append(key)
                        continue
                    state[key] = blob.sha256
                    result.downloaded.append(key)
            except Skip as skip:
                warn(f"skipping {key!r}: {skip}")
                result.skipped.append(key)
                continue
            if plan.kind == "conflict":
                result.conflicts.append(key)
            line = f"{'upload' if plan.upload else 'download':<8}  {plan.kind:<8}  {key}"
            report(f"{line}  ({plan.note})" if plan.note else line)
    finally:
        os.close(root_fd)
    return result


def _plan(file: LocalFile | None, blob: RemoteBlob | None, synced: str | None) -> _Plan:
    """Which way a file that differs between the sides goes; ``synced`` is its hash at the last sync."""
    if blob is None:
        return _Plan(upload=True, kind="new")
    if file is None:
        return _Plan(upload=False, kind="new")
    if synced == file.sha256:
        return _Plan(upload=False, kind="changed")
    if synced == blob.sha256:
        return _Plan(upload=True, kind="changed")
    local_time = _local_mtime(file)
    if blob.modified_at is None:
        raise ClientError(f"cannot sync {file.key!r}: the server did not report when it was modified")
    if local_time == blob.modified_at:
        upload, note = True, "same modification time, local wins"
    else:
        upload = local_time > blob.modified_at
        note = "local is newer" if upload else "server is newer"
    if synced is None:
        return _Plan(upload, kind="differs", note=f"no common version known; {note}")
    return _Plan(upload, kind="conflict", note=note)


def _local_mtime(file: LocalFile) -> datetime:
    """The file's mtime, at the microsecond precision of the server's ``modified_at``."""
    try:
        st = os.lstat(file.path)
    except OSError as exc:
        raise ClientError(f"cannot read {file.key!r}: {exc.strerror or exc}") from None
    # The same conversion the server applies to a blob's mtime.
    return datetime.fromtimestamp(st.st_mtime, tz=timezone.utc)
