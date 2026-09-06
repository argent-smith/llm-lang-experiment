import hashlib
import json
import os
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

import requests

DEFAULT_TIMEOUT = 10
_TMP_PREFIX = ".syncbox-pull-tmp-"

# Directory sync() uses, inside the synced <dir> itself, to persist the
# last-known-common-state manifest between runs. scan_files() prunes it so
# it never shows up as a regular file to push/pull/sync/status.
_SYNC_STATE_DIRNAME = ".syncbox"
_MANIFEST_FILENAME = "manifest.json"
_MANIFEST_TMP_PREFIX = ".manifest-tmp-"


class PushError(Exception):
    pass


class PullError(Exception):
    pass


class StatusError(Exception):
    pass


class SyncError(Exception):
    pass


@dataclass
class PushResult:
    uploaded: list
    unchanged: list


@dataclass
class PullResult:
    downloaded: list
    unchanged: list


@dataclass
class StatusResult:
    to_upload: list
    to_download: list
    unchanged: list


@dataclass
class SyncResult:
    uploaded: list
    downloaded: list
    unchanged: list


def sha256_file(path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def scan_files(root: Path) -> dict:
    """Map POSIX relative key -> absolute on-disk path for every regular file under root."""
    files = {}
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        if os.path.relpath(dirpath, root) == ".":
            # sync()'s own bookkeeping directory is never treated as synced content.
            dirnames[:] = [d for d in dirnames if d != _SYNC_STATE_DIRNAME]
        for name in filenames:
            full = os.path.join(dirpath, name)
            if not os.path.isfile(full):
                continue
            key = Path(os.path.relpath(full, root)).as_posix()
            files[key] = full
    return files


def fetch_remote_listing(server_url: str, session: requests.Session) -> dict:
    """Map key -> full BlobMeta dict ({"key", "size", "sha256", "modified_at"})."""
    response = session.get(f"{server_url}/blobs", timeout=DEFAULT_TIMEOUT)
    response.raise_for_status()
    return {item["key"]: item for item in response.json()}


def fetch_remote_index(server_url: str, session: requests.Session) -> dict:
    return {
        key: item["sha256"]
        for key, item in fetch_remote_listing(server_url, session).items()
    }


def upload_blob(server_url: str, key: str, path, session: requests.Session) -> None:
    url = f"{server_url}/blobs/{quote(key, safe='/')}"
    with open(path, "rb") as f:
        data = f.read()
    response = session.put(
        url,
        data=data,
        timeout=DEFAULT_TIMEOUT,
        headers={"Content-Type": "application/octet-stream"},
    )
    if response.status_code != 201:
        raise PushError(f"failed to upload {key}: server returned {response.status_code}")


def push(dir_path, server_url: str, session: requests.Session = None) -> PushResult:
    root = Path(dir_path)
    if not root.is_dir():
        raise PushError(f"{dir_path} is not a directory")

    server_url = server_url.rstrip("/")
    owns_session = session is None
    session = session or requests.Session()
    try:
        local_files = scan_files(root)
        remote_index = fetch_remote_index(server_url, session)

        uploaded = []
        unchanged = []
        for key in sorted(local_files):
            sha256 = sha256_file(local_files[key])
            if remote_index.get(key) == sha256:
                unchanged.append(key)
                continue
            upload_blob(server_url, key, local_files[key], session)
            uploaded.append(key)

        return PushResult(uploaded=uploaded, unchanged=unchanged)
    finally:
        if owns_session:
            session.close()


def _local_path_for_key(root: Path, key: str) -> Path:
    """Resolve a server-provided key to a path inside root.

    Mirrors the server's own key validation: the server should never hand
    out a key containing '..'/'.' segments, but pull writes to the local
    filesystem based on that key, so it re-checks rather than trusting a
    buggy or compromised server to keep every write inside root.
    """
    parts = key.split("/")
    if not key or any(part in ("", ".", "..") for part in parts):
        raise PullError(f"server returned an unsafe key: {key!r}")
    candidate = root.joinpath(*parts)
    real_root = os.path.realpath(root)
    real_candidate = os.path.realpath(candidate)
    if os.path.commonpath([real_root, real_candidate]) != real_root:
        raise PullError(f"server returned a key that escapes {root}: {key!r}")
    return candidate


def download_blob(server_url: str, key: str, dest: Path, session: requests.Session) -> None:
    url = f"{server_url}/blobs/{quote(key, safe='/')}"
    response = session.get(url, timeout=DEFAULT_TIMEOUT)
    if response.status_code != 200:
        raise PullError(f"failed to download {key}: server returned {response.status_code}")

    dest.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=dest.parent, prefix=_TMP_PREFIX)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(response.content)
        os.replace(tmp_path, dest)
    except OSError:
        os.remove(tmp_path)
        raise


def pull(dir_path, server_url: str, session: requests.Session = None) -> PullResult:
    root = Path(dir_path)
    if not root.is_dir():
        raise PullError(f"{dir_path} is not a directory")

    server_url = server_url.rstrip("/")
    owns_session = session is None
    session = session or requests.Session()
    try:
        local_files = scan_files(root)
        remote_index = fetch_remote_index(server_url, session)

        downloaded = []
        unchanged = []
        for key in sorted(remote_index):
            sha256 = remote_index[key]
            local_path = local_files.get(key)
            if local_path is not None and sha256_file(local_path) == sha256:
                unchanged.append(key)
                continue
            dest = _local_path_for_key(root, key)
            download_blob(server_url, key, dest, session)
            downloaded.append(key)

        return PullResult(downloaded=downloaded, unchanged=unchanged)
    finally:
        if owns_session:
            session.close()


def _manifest_dir(root: Path) -> Path:
    return root / _SYNC_STATE_DIRNAME


def _manifest_path(root: Path) -> Path:
    return _manifest_dir(root) / _MANIFEST_FILENAME


def _load_manifest(root: Path) -> dict:
    """Last-known-common-state: key -> sha256 as of the last successful sync().

    Missing or unreadable/corrupt manifest is treated as "no known state yet"
    (first run) rather than an error - sync() degrades gracefully to plain
    upload/download in that case.
    """
    try:
        with open(_manifest_path(root), "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {k: v for k, v in data.items() if isinstance(k, str) and isinstance(v, str)}


def _save_manifest(root: Path, manifest: dict) -> None:
    directory = _manifest_dir(root)
    directory.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=_MANIFEST_TMP_PREFIX)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(manifest, f)
        os.replace(tmp_path, _manifest_path(root))
    except OSError:
        os.remove(tmp_path)
        raise


def _epoch_seconds_from_modified_at(modified_at: str) -> int:
    dt = datetime.strptime(modified_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    return int(dt.timestamp())


def _local_mtime_epoch(path) -> int:
    # Truncated to whole seconds to match modified_at's second-resolution
    # format, so equal-instant files compare as a genuine tie rather than
    # local looking spuriously "newer" due to sub-second precision.
    return int(os.stat(path).st_mtime)


def sync(dir_path, server_url: str, session: requests.Session = None) -> SyncResult:
    """Two-way sync: upload local-only/changed files, download remote-only/changed
    files, and resolve genuine conflicts (both sides changed since the last known
    common state) by newer modified_at/mtime, local wins ties. Never deletes.
    """
    root = Path(dir_path)
    if not root.is_dir():
        raise SyncError(f"{dir_path} is not a directory")

    server_url = server_url.rstrip("/")
    owns_session = session is None
    session = session or requests.Session()
    try:
        local_files = scan_files(root)
        remote_listing = fetch_remote_listing(server_url, session)
        manifest = _load_manifest(root)
        local_hashes = {key: sha256_file(path) for key, path in local_files.items()}

        uploaded = []
        downloaded = []
        unchanged = []
        new_manifest = {}

        for key in sorted(set(local_hashes) | set(remote_listing)):
            local_sha = local_hashes.get(key)
            remote_item = remote_listing.get(key)
            remote_sha = remote_item["sha256"] if remote_item is not None else None

            if remote_sha is None:
                upload_blob(server_url, key, local_files[key], session)
                uploaded.append(key)
                new_manifest[key] = local_sha
                continue

            if local_sha is None:
                download_blob(server_url, key, _local_path_for_key(root, key), session)
                downloaded.append(key)
                new_manifest[key] = remote_sha
                continue

            if local_sha == remote_sha:
                unchanged.append(key)
                new_manifest[key] = local_sha
                continue

            last_known = manifest.get(key)
            if last_known == local_sha:
                # local unchanged since baseline, only the remote side moved
                download_blob(server_url, key, _local_path_for_key(root, key), session)
                downloaded.append(key)
                new_manifest[key] = remote_sha
            elif last_known == remote_sha:
                # remote unchanged since baseline, only the local side moved
                upload_blob(server_url, key, local_files[key], session)
                uploaded.append(key)
                new_manifest[key] = local_sha
            else:
                # conflict (or no known baseline yet): newer mtime wins, ties go local
                local_epoch = _local_mtime_epoch(local_files[key])
                remote_epoch = _epoch_seconds_from_modified_at(remote_item["modified_at"])
                if remote_epoch > local_epoch:
                    download_blob(server_url, key, _local_path_for_key(root, key), session)
                    downloaded.append(key)
                    new_manifest[key] = remote_sha
                else:
                    upload_blob(server_url, key, local_files[key], session)
                    uploaded.append(key)
                    new_manifest[key] = local_sha

        _save_manifest(root, new_manifest)
        return SyncResult(uploaded=uploaded, downloaded=downloaded, unchanged=unchanged)
    finally:
        if owns_session:
            session.close()


def status(dir_path, server_url: str, session: requests.Session = None) -> StatusResult:
    """Dry-run comparison of local dir vs server: never writes anywhere."""
    root = Path(dir_path)
    if not root.is_dir():
        raise StatusError(f"{dir_path} is not a directory")

    server_url = server_url.rstrip("/")
    owns_session = session is None
    session = session or requests.Session()
    try:
        local_files = scan_files(root)
        remote_index = fetch_remote_index(server_url, session)
        local_hashes = {key: sha256_file(path) for key, path in local_files.items()}

        to_upload = sorted(
            key for key, sha256 in local_hashes.items() if remote_index.get(key) != sha256
        )
        to_download = sorted(
            key for key, sha256 in remote_index.items() if local_hashes.get(key) != sha256
        )
        unchanged = sorted(
            key for key, sha256 in local_hashes.items() if remote_index.get(key) == sha256
        )

        return StatusResult(to_upload=to_upload, to_download=to_download, unchanged=unchanged)
    finally:
        if owns_session:
            session.close()
