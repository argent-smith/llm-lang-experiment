"""``syncbox status``: show what push and pull would transfer, changing nothing.

The server is only asked for its list of blobs (GET /blobs), and files under
``<dir>`` are only read, to hash them, so neither side is changed. Files are
compared as push and pull compare them: by key and SHA-256, so a file whose
content differs on the two sides is listed in both directions.

A local file (or directory) that can't be read is a failure, and its keys
are left out of the comparison rather than listed as missing locally.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from .api import ServerClient
from .errors import Failures
from .local import scan
from .pull import is_safe_key


@dataclass(frozen=True)
class Change:
    key: str
    new: bool  # missing on the receiving side, rather than different there


@dataclass
class StatusResult:
    upload: list[Change] = field(default_factory=list)
    download: list[Change] = field(default_factory=list)
    unchanged: list[str] = field(default_factory=list)


def status(
    root: Path,
    client: ServerClient,
    report: Callable[[str], None],
    warn: Callable[[str], None],
    failures: Failures,
) -> StatusResult:
    """Compare the files under ``root`` with the blobs on the server.

    Calls ``report`` with a line per file that push would upload, then per
    file that pull would download: ``upload new <key>`` for a file the
    server lacks, ``upload changed <key>`` for one it has another version
    of, and ``download new|changed <key>`` alike. A local file that can't
    be read is added to ``failures``; raises ClientError if the comparison
    can't be made at all (no list of blobs, ``root`` unreadable).
    """
    # The server is asked first, so an unreachable one fails before the
    # whole tree has been hashed.
    remote: dict[str, str] = {}
    for blob in client.list_blobs():
        if is_safe_key(blob.key):
            remote[blob.key] = blob.sha256
        else:
            warn(f"server lists an invalid key {blob.key!r}; pull would refuse to download it")
    local = {file.key: file.sha256 for file in scan(root, warn, failures)}
    remote = {key: sha256 for key, sha256 in remote.items() if not failures.covers(key)}

    result = StatusResult()
    for key, sha256 in local.items():
        if remote.get(key) == sha256:
            result.unchanged.append(key)
        else:
            result.upload.append(Change(key, new=key not in remote))
    for key in sorted(remote):
        if local.get(key) != remote[key]:
            result.download.append(Change(key, new=key not in local))

    for direction, changes in (("upload", result.upload), ("download", result.download)):
        for change in changes:
            report(f"{direction:<8}  {'new' if change.new else 'changed':<7}  {change.key}")
    return result
