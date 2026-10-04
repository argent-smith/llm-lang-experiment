"""``syncbox push``: upload local files that the server lacks or has a different version of."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from .api import ServerClient
from .errors import ClientError, Failures
from .local import scan


@dataclass
class PushResult:
    uploaded: list[str] = field(default_factory=list)
    unchanged: list[str] = field(default_factory=list)


def push(
    root: Path,
    client: ServerClient,
    report: Callable[[str], None],
    warn: Callable[[str], None],
    failures: Failures,
) -> PushResult:
    """Upload every file under ``root`` whose SHA-256 differs from the server's blob.

    Files the server already has with the same content are not sent again;
    blobs with no local file are left alone. Calls ``report`` with a line per
    uploaded file. A file that can't be read or uploaded is added to
    ``failures`` and the push goes on with the rest; raises ClientError if
    it can't get going at all (no list of blobs, ``root`` unreadable).
    """
    # The server is asked first, so an unreachable one fails the push before
    # the whole tree has been hashed.
    remote = {blob.key: blob.sha256 for blob in client.list_blobs()}
    result = PushResult()
    for file in scan(root, warn, failures):
        if remote.get(file.key) == file.sha256:
            result.unchanged.append(file.key)
            continue
        try:
            client.put_blob(file.key, file.path)
        except ClientError as exc:
            failures.add(file.key, str(exc))
            continue
        result.uploaded.append(file.key)
        report(f"{'updated' if file.key in remote else 'added'} {file.key}")
    return result
