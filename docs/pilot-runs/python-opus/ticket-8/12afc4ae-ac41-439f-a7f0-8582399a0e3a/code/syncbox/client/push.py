"""``syncbox push``: upload local files that the server lacks or has a different version of."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from .api import ServerClient
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
) -> PushResult:
    """Upload every file under ``root`` whose SHA-256 differs from the server's blob.

    Files the server already has with the same content are not sent again;
    blobs with no local file are left alone. Calls ``report`` with a line per
    uploaded file. Stops at the first failure (raising ClientError).
    """
    # The server is asked first, so an unreachable one fails the push before
    # the whole tree has been hashed.
    remote = {blob.key: blob.sha256 for blob in client.list_blobs()}
    result = PushResult()
    for file in scan(root, warn):
        if remote.get(file.key) == file.sha256:
            result.unchanged.append(file.key)
            continue
        client.put_blob(file.key, file.path)
        result.uploaded.append(file.key)
        report(f"{'updated' if file.key in remote else 'added'} {file.key}")
    return result
