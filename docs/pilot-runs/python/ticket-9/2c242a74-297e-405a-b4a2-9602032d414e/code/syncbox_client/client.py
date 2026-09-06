import hashlib
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote

import requests

DEFAULT_TIMEOUT = 10
_TMP_PREFIX = ".syncbox-pull-tmp-"


class PushError(Exception):
    pass


class PullError(Exception):
    pass


class StatusError(Exception):
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


def sha256_file(path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def scan_files(root: Path) -> dict:
    """Map POSIX relative key -> absolute on-disk path for every regular file under root."""
    files = {}
    for dirpath, _dirnames, filenames in os.walk(root, followlinks=False):
        for name in filenames:
            full = os.path.join(dirpath, name)
            if not os.path.isfile(full):
                continue
            key = Path(os.path.relpath(full, root)).as_posix()
            files[key] = full
    return files


def fetch_remote_index(server_url: str, session: requests.Session) -> dict:
    response = session.get(f"{server_url}/blobs", timeout=DEFAULT_TIMEOUT)
    response.raise_for_status()
    return {item["key"]: item["sha256"] for item in response.json()}


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
