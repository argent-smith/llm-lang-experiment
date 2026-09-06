import hashlib
import os
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote

import requests

DEFAULT_TIMEOUT = 10


class PushError(Exception):
    pass


@dataclass
class PushResult:
    uploaded: list
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
