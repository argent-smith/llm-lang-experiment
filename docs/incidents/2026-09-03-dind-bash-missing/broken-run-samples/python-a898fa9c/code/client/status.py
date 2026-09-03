from collections import namedtuple
from pathlib import Path

import requests

from .pull import files_to_download
from .push import fetch_remote_hashes, files_to_upload, local_files, sha256_file

StatusResult = namedtuple("StatusResult", ["to_upload", "to_download", "unchanged"])


class StatusError(Exception):
    """Raised when status can't complete because of a local or remote failure."""


def status(directory, server, session=None, timeout=10):
    """Compare <directory> against the server without changing either side."""
    root = Path(directory)
    if not root.is_dir():
        raise StatusError(f"not a directory: {directory}")

    server = server.rstrip("/")
    session = session or requests.Session()
    paths = local_files(root)
    local_hashes = {key: sha256_file(path) for key, path in paths.items()}

    try:
        remote_hashes = fetch_remote_hashes(server, session, timeout)
    except requests.exceptions.RequestException as exc:
        raise StatusError(f"could not reach server at {server}: {exc}") from exc

    to_upload = files_to_upload(local_hashes, remote_hashes)
    to_download = files_to_download(remote_hashes, local_hashes)
    unchanged = sorted(
        key for key, sha in local_hashes.items() if remote_hashes.get(key) == sha
    )

    return StatusResult(to_upload=to_upload, to_download=to_download, unchanged=unchanged)
