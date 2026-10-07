"""What ``sync`` last saw both sides agree on, kept between runs.

For each pair of a local directory and a server there is a state file: the
SHA-256 of every file that, as of the last sync, had the same content
locally and on the server. That is the "last known common state" the
conflict rule compares against: a side whose file still has the recorded
hash hasn't changed it since.

State files live outside the synced directory, so they are never synced
themselves nor seen by anything comparing the directory with the server:
in SYNCBOX_STATE_DIR if set, else ``$XDG_STATE_HOME/syncbox``, else
``~/.local/state/syncbox``. The directory is identified by its real path,
or by SYNCBOX_DIR_ID if set (run-client sets it to the host path, as inside
the container the directory is always at the same mount point).

A state file is only a record; losing it costs nothing but conflict
detection on the next run. So a missing, unreadable or malformed one is
treated as empty (with a warning, unless it's merely missing), and a
failure to save one is a warning, not an error.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
from pathlib import Path
from typing import Callable, Mapping

from .api import ServerURL
from .errors import ClientError

ENV_STATE_DIR = "SYNCBOX_STATE_DIR"
ENV_DIR_ID = "SYNCBOX_DIR_ID"

_VERSION = 1
_SHA256 = re.compile(r"[0-9a-f]{64}")


def state_dir(env: Mapping[str, str]) -> Path:
    """Where state files are kept, per the environment."""
    if env.get(ENV_STATE_DIR):
        return Path(env[ENV_STATE_DIR])
    xdg = env.get("XDG_STATE_HOME")
    if xdg and os.path.isabs(xdg):
        return Path(xdg, "syncbox")
    home = env.get("HOME") or os.path.expanduser("~")
    if not os.path.isabs(home):
        raise ClientError(f"cannot tell where to keep the sync state: set {ENV_STATE_DIR}")
    return Path(home, ".local", "state", "syncbox")


class SyncState:
    """The state file of one directory and server."""

    def __init__(self, directory: Path, dir_id: str, server: ServerURL) -> None:
        self.dir_id = dir_id
        self.server = f"http://{server.host.lower()}:{server.port}{server.base_path}"
        name = hashlib.sha256(f"{self.dir_id}\0{self.server}".encode("utf-8", "surrogateescape")).hexdigest()
        self.path = directory / f"{name[:32]}.json"

    @classmethod
    def for_dir(cls, root: Path, server: ServerURL, env: Mapping[str, str]) -> SyncState:
        return cls(state_dir(env), env.get(ENV_DIR_ID) or os.path.realpath(root), server)

    def load(self, warn: Callable[[str], None]) -> dict[str, str]:
        """``{key: sha256}`` as of the last sync; empty if there was none."""
        try:
            payload = json.loads(self.path.read_bytes())
        except FileNotFoundError:
            return {}
        except OSError as exc:
            warn(f"cannot read sync state {str(self.path)!r}: {exc.strerror or exc}; treating every file as new")
            return {}
        except ValueError:
            payload = None
        files = payload.get("files") if isinstance(payload, dict) and payload.get("version") == _VERSION else None
        if (
            not isinstance(files, dict)
            or payload.get("dir") != self.dir_id
            or payload.get("server") != self.server
            or not all(isinstance(k, str) and isinstance(v, str) and _SHA256.fullmatch(v) for k, v in files.items())
        ):
            warn(f"ignoring malformed sync state {str(self.path)!r}; treating every file as new")
            return {}
        return files

    def save(self, files: Mapping[str, str], warn: Callable[[str], None]) -> None:
        """Record ``{key: sha256}`` as the state for the next sync, replacing the file atomically."""
        payload = {"version": _VERSION, "dir": self.dir_id, "server": self.server, "files": dict(sorted(files.items()))}
        data = json.dumps(payload, indent=1, ensure_ascii=True).encode() + b"\n"
        tmp = self.path.with_name(f".{self.path.stem}-{secrets.token_hex(8)}.tmp")
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600)
            try:
                with open(fd, "wb") as f:
                    f.write(data)
                    f.flush()
                    os.fsync(fd)
                os.replace(tmp, self.path)
            finally:
                tmp.unlink(missing_ok=True)
        except OSError as exc:
            warn(
                f"cannot save sync state {str(self.path)!r}: {exc.strerror or exc};"
                " the next sync will compare against the previous state"
            )
