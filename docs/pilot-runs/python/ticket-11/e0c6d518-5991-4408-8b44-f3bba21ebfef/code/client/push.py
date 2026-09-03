import hashlib
from collections import namedtuple
from pathlib import Path
from urllib.parse import quote

import requests

PushResult = namedtuple("PushResult", ["uploaded", "skipped", "failed"])

# One entry per file that couldn't be processed -- key plus a human-readable
# reason -- so callers can report a summary without aborting the rest of the
# run. Shared across push/pull/sync/status.
FileFailure = namedtuple("FileFailure", ["key", "reason"])

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


def hash_local_files(paths):
    """Hash every local file, isolating unreadable ones instead of failing outright.

    Returns (hashes, failures): hashes maps key -> sha256 for every file that
    could be read; failures lists a FileFailure for each one that couldn't
    (permission error, vanished mid-walk, etc.), so the caller can still
    process every other file rather than aborting the whole command.
    """
    hashes = {}
    failures = []
    for key, path in paths.items():
        try:
            hashes[key] = sha256_file(path)
        except OSError as exc:
            failures.append(FileFailure(key=key, reason=f"cannot read local file: {exc}"))
    return hashes, failures


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
    local_hashes, failed = hash_local_files(paths)

    try:
        remote_hashes = fetch_remote_hashes(server, session, timeout)
    except requests.exceptions.RequestException as exc:
        raise PushError(f"could not reach server at {server}: {exc}") from exc

    to_upload = files_to_upload(local_hashes, remote_hashes)
    uploaded = []
    for key in to_upload:
        try:
            upload_file(server, session, key, paths[key], timeout)
        except (requests.exceptions.RequestException, OSError) as exc:
            failed.append(FileFailure(key=key, reason=str(exc)))
            continue
        uploaded.append(key)

    skipped = sorted(set(local_hashes) - set(to_upload))
    return PushResult(uploaded=uploaded, skipped=skipped, failed=sorted(failed))
