import uuid
from collections import namedtuple
from pathlib import Path
from urllib.parse import quote

import requests

from .push import local_files, sha256_file

PullResult = namedtuple("PullResult", ["downloaded", "skipped"])


class PullError(Exception):
    """Raised when pull can't complete because of a local or remote failure."""


def fetch_remote_hashes(server, session, timeout):
    response = session.get(f"{server}/blobs", timeout=timeout)
    response.raise_for_status()
    return {entry["key"]: entry["sha256"] for entry in response.json()}


def files_to_download(remote_hashes, local_hashes):
    """Keys that are missing locally or whose content differs."""
    return sorted(key for key, sha in remote_hashes.items() if local_hashes.get(key) != sha)


def resolve_download_path(root, key):
    """Map a server-reported key to a path inside root, rejecting anything
    that would escape it. The server is not expected to hand out such keys,
    but pull shouldn't blindly trust it to write to the local filesystem."""
    if not key or key.startswith("/") or "\x00" in key:
        raise PullError(f"refusing to write unsafe key: {key!r}")

    segments = key.split("/")
    if ".." in segments:
        raise PullError(f"refusing to write unsafe key: {key!r}")

    root = root.resolve()
    candidate = (root / key).resolve()
    if candidate != root and root not in candidate.parents:
        raise PullError(f"refusing to write unsafe key: {key!r}")

    return candidate


def download_file(server, session, key, dest_root, timeout):
    url = f"{server}/blobs/{quote(key, safe='/')}"
    dest = resolve_download_path(dest_root, key)
    dest.parent.mkdir(parents=True, exist_ok=True)

    with session.get(url, timeout=timeout, stream=True) as response:
        response.raise_for_status()
        tmp = dest.parent / f".{dest.name}.syncbox-tmp-{uuid.uuid4().hex}"
        try:
            with open(tmp, "wb") as f:
                for chunk in response.iter_content(chunk_size=1024 * 1024):
                    f.write(chunk)
            tmp.replace(dest)
        except BaseException:
            tmp.unlink(missing_ok=True)
            raise


def pull(directory, server, session=None, timeout=10):
    root = Path(directory)
    if not root.is_dir():
        raise PullError(f"not a directory: {directory}")

    server = server.rstrip("/")
    session = session or requests.Session()
    paths = local_files(root)
    local_hashes = {key: sha256_file(path) for key, path in paths.items()}

    try:
        remote_hashes = fetch_remote_hashes(server, session, timeout)
        to_download = files_to_download(remote_hashes, local_hashes)
        for key in to_download:
            download_file(server, session, key, root, timeout)
    except requests.exceptions.RequestException as exc:
        raise PullError(f"could not reach server at {server}: {exc}") from exc

    skipped = sorted(set(remote_hashes) - set(to_download))
    return PullResult(downloaded=to_download, skipped=skipped)
