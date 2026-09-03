import json
from collections import namedtuple
from datetime import datetime
from pathlib import Path

import requests

from .pull import download_file
from .push import local_files, sha256_file, upload_file

SyncResult = namedtuple("SyncResult", ["uploaded", "downloaded", "unchanged"])

# Where sync remembers the last known common state between runs. Lives inside
# <dir> (the only thing that survives between `run-client sync` invocations,
# since each run is a fresh --rm container) and is excluded from the file
# scan below so it's never itself treated as a blob to sync.
STATE_FILENAME = ".syncbox-sync-state.json"


class SyncError(Exception):
    """Raised when sync can't complete because of a local or remote failure."""


def load_state(root):
    path = root / STATE_FILENAME
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return data.get("entries", {})


def save_state(root, entries, server):
    path = root / STATE_FILENAME
    path.write_text(json.dumps({"version": 1, "server": server, "entries": entries}, sort_keys=True))


def fetch_remote_meta(server, session, timeout):
    response = session.get(f"{server}/blobs", timeout=timeout)
    response.raise_for_status()
    return {entry["key"]: entry for entry in response.json()}


def parse_modified_at(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def plan_sync(local_hashes, local_mtimes, remote_meta, base_entries):
    """Decide, per key, whether to upload, download, or leave it alone.

    Returns (to_upload, to_download, new_entries): sorted key lists for the
    two transfer directions, plus the base-state map to persist once those
    transfers complete.
    """
    to_upload = []
    to_download = []
    new_entries = {}

    for key in sorted(set(local_hashes) | set(remote_meta) | set(base_entries)):
        local_sha = local_hashes.get(key)
        remote_sha = remote_meta[key]["sha256"] if key in remote_meta else None
        base_sha = base_entries.get(key)

        if local_sha == remote_sha:
            if local_sha is not None:
                new_entries[key] = local_sha
            continue

        if remote_sha is None:
            # Present only locally (new, or the server-side copy was
            # deleted) -- sync never deletes, so this always goes up.
            to_upload.append(key)
            new_entries[key] = local_sha
            continue

        if local_sha is None:
            # Present only on the server (new, or the local copy was
            # deleted) -- sync never deletes, so this always comes down.
            to_download.append(key)
            new_entries[key] = remote_sha
            continue

        # Both sides have the key, with different content.
        if base_sha is None:
            # No known common history for this key: a plain SHA-256
            # divergence, not a "changed on both sides since the common
            # state" conflict per SYNCBOX-SPEC.md -- resolve like an
            # ordinary upload, no mtime rule involved.
            to_upload.append(key)
            new_entries[key] = local_sha
        elif base_sha == remote_sha:
            # Server side is unchanged since the baseline; local changed.
            to_upload.append(key)
            new_entries[key] = local_sha
        elif base_sha == local_sha:
            # Local side is unchanged since the baseline; server changed.
            to_download.append(key)
            new_entries[key] = remote_sha
        else:
            # Real conflict: both sides moved away from the known common
            # state. Freshest modified_at/mtime wins; ties go to local.
            remote_mtime = parse_modified_at(remote_meta[key]["modified_at"])
            if remote_mtime > local_mtimes[key]:
                to_download.append(key)
                new_entries[key] = remote_sha
            else:
                to_upload.append(key)
                new_entries[key] = local_sha

    return to_upload, to_download, new_entries


def sync(directory, server, session=None, timeout=10):
    root = Path(directory)
    if not root.is_dir():
        raise SyncError(f"not a directory: {directory}")

    server = server.rstrip("/")
    session = session or requests.Session()

    paths = local_files(root)
    paths.pop(STATE_FILENAME, None)
    local_hashes = {key: sha256_file(path) for key, path in paths.items()}
    local_mtimes = {key: path.stat().st_mtime for key, path in paths.items()}

    base_entries = load_state(root)

    try:
        remote_meta = fetch_remote_meta(server, session, timeout)
        to_upload, to_download, new_entries = plan_sync(
            local_hashes, local_mtimes, remote_meta, base_entries
        )

        for key in to_upload:
            upload_file(server, session, key, paths[key], timeout)
        for key in to_download:
            download_file(server, session, key, root, timeout)
    except requests.exceptions.RequestException as exc:
        raise SyncError(f"could not reach server at {server}: {exc}") from exc

    save_state(root, new_entries, server)

    all_keys = set(local_hashes) | set(remote_meta)
    unchanged = sorted(all_keys - set(to_upload) - set(to_download))
    return SyncResult(uploaded=to_upload, downloaded=to_download, unchanged=unchanged)
