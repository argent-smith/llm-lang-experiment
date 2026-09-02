import json
from collections import namedtuple
from datetime import datetime
from pathlib import Path

import requests

from .pull import download_file
from .push import local_files, sha256_file, upload_file

SyncResult = namedtuple("SyncResult", ["uploaded", "downloaded", "unchanged"])

# Manifest of the last known common state (key -> sha256), used to tell
# "changed on one side only" (plain push/pull) apart from a real conflict
# (changed on both sides since the last sync). Lives inside the synced
# directory so it survives between separate `syncbox sync` invocations, and
# is excluded from the set of files being synced.
STATE_FILENAME = ".syncbox-sync-state.json"


class SyncError(Exception):
    """Raised when sync can't complete because of a local or remote failure."""


def _state_path(root):
    return root / STATE_FILENAME


def load_baseline(root):
    path = _state_path(root)
    if not path.is_file():
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_baseline(root, baseline):
    path = _state_path(root)
    tmp = path.with_name(f"{path.name}.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(baseline, f, sort_keys=True)
    tmp.replace(path)


def parse_modified_at(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def fetch_remote_meta(server, session, timeout):
    response = session.get(f"{server}/blobs", timeout=timeout)
    response.raise_for_status()
    return {entry["key"]: entry for entry in response.json()}


def resolve_action(key, local_sha, remote_sha, baseline):
    """Decide what to do for a key present with differing content on both
    sides. A file changed relative to the baseline on only one side is a
    plain push/pull; changed on both (or never seen before) is a conflict,
    resolved by the caller using mtime."""
    base_sha = baseline.get(key)
    if base_sha == remote_sha:
        return "upload"
    if base_sha == local_sha:
        return "download"
    return "conflict"


def sync(directory, server, session=None, timeout=10):
    root = Path(directory)
    if not root.is_dir():
        raise SyncError(f"not a directory: {directory}")

    server = server.rstrip("/")
    session = session or requests.Session()

    baseline = load_baseline(root)
    paths = {key: path for key, path in local_files(root).items() if key != STATE_FILENAME}
    local_hashes = {key: sha256_file(path) for key, path in paths.items()}

    uploaded = []
    downloaded = []
    unchanged = []
    new_baseline = {}

    try:
        remote_meta = fetch_remote_meta(server, session, timeout)
        remote_hashes = {key: meta["sha256"] for key, meta in remote_meta.items()}

        for key in sorted(set(local_hashes) | set(remote_hashes)):
            local_sha = local_hashes.get(key)
            remote_sha = remote_hashes.get(key)

            if local_sha == remote_sha:
                unchanged.append(key)
                new_baseline[key] = local_sha
                continue

            if remote_sha is None:
                action = "upload"
            elif local_sha is None:
                action = "download"
            else:
                action = resolve_action(key, local_sha, remote_sha, baseline)
                if action == "conflict":
                    local_mtime = paths[key].stat().st_mtime
                    remote_mtime = parse_modified_at(remote_meta[key]["modified_at"])
                    action = "upload" if local_mtime >= remote_mtime else "download"

            if action == "upload":
                upload_file(server, session, key, paths[key], timeout)
                uploaded.append(key)
                new_baseline[key] = local_sha
            else:
                download_file(server, session, key, root, timeout)
                downloaded.append(key)
                new_baseline[key] = remote_sha
    except requests.exceptions.RequestException as exc:
        raise SyncError(f"could not reach server at {server}: {exc}") from exc

    save_baseline(root, new_baseline)

    return SyncResult(uploaded=uploaded, downloaded=downloaded, unchanged=unchanged)
