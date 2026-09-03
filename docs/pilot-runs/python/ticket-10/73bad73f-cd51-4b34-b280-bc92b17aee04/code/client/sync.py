import json
from collections import namedtuple
from datetime import datetime, timezone
from pathlib import Path

import requests

from .pull import download_file
from .push import SYNC_MANIFEST_NAME, local_files, sha256_file, upload_file

SyncResult = namedtuple("SyncResult", ["uploaded", "downloaded", "unchanged"])


class SyncError(Exception):
    """Raised when sync can't complete because of a local or remote failure."""


def fetch_remote_entries(server, session, timeout):
    response = session.get(f"{server}/blobs", timeout=timeout)
    response.raise_for_status()
    return {entry["key"]: entry for entry in response.json()}


def parse_modified_at(value):
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    return datetime.fromisoformat(value)


def local_mtime(path):
    return datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)


def manifest_path(root):
    return root / SYNC_MANIFEST_NAME


def load_manifest(root):
    """The last known common state (key -> shared sha256) from a prior sync.

    Missing or unreadable manifest just means "no known common state yet" --
    the same situation as a first-ever sync run.
    """
    try:
        with open(manifest_path(root), "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save_manifest(root, manifest):
    with open(manifest_path(root), "w", encoding="utf-8") as f:
        json.dump(manifest, f, sort_keys=True, indent=2)
        f.write("\n")


def resolve_action(local_sha, remote_sha, base_sha, local_dt, remote_dt):
    """Decide what to do with one key: "upload", "download", or "unchanged".

    Follows the sync conflict rule from SYNCBOX-SPEC.md literally: a file
    missing on one side moves to that side; a file changed relative to the
    last known common state on only one side moves in that direction,
    regardless of timestamps; a file changed on both sides is a genuine
    conflict, resolved by whichever modified_at/mtime is newer, with ties
    going to the local version.
    """
    if local_sha == remote_sha:
        return "unchanged"
    if local_sha is None:
        return "download"
    if remote_sha is None:
        return "upload"

    if base_sha is not None:
        local_changed = local_sha != base_sha
        remote_changed = remote_sha != base_sha
        if local_changed and not remote_changed:
            return "upload"
        if remote_changed and not local_changed:
            return "download"

    return "download" if remote_dt > local_dt else "upload"


def sync(directory, server, session=None, timeout=10):
    root = Path(directory)
    if not root.is_dir():
        raise SyncError(f"not a directory: {directory}")

    server = server.rstrip("/")
    session = session or requests.Session()
    manifest = load_manifest(root)
    paths = local_files(root)
    local_hashes = {key: sha256_file(path) for key, path in paths.items()}

    uploaded = []
    downloaded = []
    unchanged = []
    final_hashes = {}

    try:
        remote_entries = fetch_remote_entries(server, session, timeout)
        remote_hashes = {key: entry["sha256"] for key, entry in remote_entries.items()}

        for key in sorted(set(local_hashes) | set(remote_hashes)):
            local_sha = local_hashes.get(key)
            remote_sha = remote_hashes.get(key)
            local_dt = local_mtime(paths[key]) if key in paths else None
            remote_dt = (
                parse_modified_at(remote_entries[key]["modified_at"])
                if key in remote_entries
                else None
            )

            action = resolve_action(local_sha, remote_sha, manifest.get(key), local_dt, remote_dt)

            if action == "upload":
                upload_file(server, session, key, paths[key], timeout)
                uploaded.append(key)
                final_hashes[key] = local_sha
            elif action == "download":
                download_file(server, session, key, root, timeout)
                downloaded.append(key)
                final_hashes[key] = remote_sha
            else:
                unchanged.append(key)
                final_hashes[key] = local_sha
    except requests.exceptions.RequestException as exc:
        raise SyncError(f"could not reach server at {server}: {exc}") from exc

    save_manifest(root, final_hashes)
    return SyncResult(
        uploaded=sorted(uploaded), downloaded=sorted(downloaded), unchanged=sorted(unchanged)
    )
