import hashlib
from collections import namedtuple
from pathlib import Path
from urllib.parse import quote

import requests

PushResult = namedtuple("PushResult", ["uploaded", "skipped"])

# Filename sync() keeps at the root of the synced directory to remember the
# last known common state between runs. It isn't blob content, so every
# directory walk that turns local files into sync candidates must skip it.
SYNC_MANIFEST_NAME = ".syncbox-manifest.json"


class PushError(Exception):
    """Raised when push can't complete because of a local or remote failure."""


def sha256_file(path, chunk_size=1024 * 1024):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(chunk_size), b""):
            digest.update(chunk)
    return digest.hexdigest()


def local_files(root):
    """Map POSIX-relative key -> filesystem path for every file under root."""
    files = {}
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        key = path.relative_to(root).as_posix()
        if key == SYNC_MANIFEST_NAME:
            continue
        files[key] = path
    return files


def fetch_remote_hashes(server, session, timeout):
    response = session.get(f"{server}/blobs", timeout=timeout)
    response.raise_for_status()
    return {entry["key"]: entry["sha256"] for entry in response.json()}


def files_to_upload(local_hashes, remote_hashes):
    """Keys that are missing on the server or whose content differs."""
    return sorted(key for key, sha in local_hashes.items() if remote_hashes.get(key) != sha)


def upload_file(server, session, key, path, timeout):
    url = f"{server}/blobs/{quote(key, safe='/')}"
    with open(path, "rb") as f:
        response = session.put(url, data=f, timeout=timeout)
    response.raise_for_status()


def push(directory, server, session=None, timeout=10):
    root = Path(directory)
    if not root.is_dir():
        raise PushError(f"not a directory: {directory}")

    server = server.rstrip("/")
    session = session or requests.Session()
    paths = local_files(root)
    local_hashes = {key: sha256_file(path) for key, path in paths.items()}

    try:
        remote_hashes = fetch_remote_hashes(server, session, timeout)
        to_upload = files_to_upload(local_hashes, remote_hashes)
        for key in to_upload:
            upload_file(server, session, key, paths[key], timeout)
    except requests.exceptions.RequestException as exc:
        raise PushError(f"could not reach server at {server}: {exc}") from exc

    skipped = sorted(set(local_hashes) - set(to_upload))
    return PushResult(uploaded=to_upload, skipped=skipped)
