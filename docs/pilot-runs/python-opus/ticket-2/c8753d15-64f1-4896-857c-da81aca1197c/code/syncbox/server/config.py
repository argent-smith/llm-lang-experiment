"""Server configuration: command-line flags with environment-variable fallback.

Precedence: flag > environment variable > default. ``--data-dir`` has no
default and must come from either the flag or ``SYNCBOX_DATA_DIR``.
"""

from __future__ import annotations

import argparse
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Sequence

DEFAULT_PORT = 8080
DEFAULT_HOST = "0.0.0.0"

ENV_DATA_DIR = "SYNCBOX_DATA_DIR"
ENV_PORT = "SYNCBOX_PORT"

_PORT_RE = re.compile(r"[0-9]+")


class ConfigError(Exception):
    """Invalid or missing configuration value."""


@dataclass(frozen=True)
class ServerConfig:
    data_dir: Path
    port: int = DEFAULT_PORT
    host: str = DEFAULT_HOST


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="syncbox-server",
        description="Syncbox HTTP server.",
    )
    parser.add_argument(
        "--data-dir",
        metavar="PATH",
        help=f"directory where blobs are stored (env: {ENV_DATA_DIR}; required)",
    )
    parser.add_argument(
        "--port",
        metavar="N",
        help=f"TCP port to listen on (env: {ENV_PORT}; default: {DEFAULT_PORT})",
    )
    return parser


def parse_port(raw: str) -> int:
    # int() alone would also accept " 80", "+80" and "8_080".
    if not _PORT_RE.fullmatch(raw):
        raise ConfigError(f"invalid port {raw!r}: expected an integer 1-65535")
    port = int(raw)
    if not 1 <= port <= 65535:
        raise ConfigError(f"invalid port {raw!r}: expected an integer 1-65535")
    return port


def load_config(
    argv: Sequence[str] | None = None,
    environ: Mapping[str, str] | None = None,
) -> ServerConfig:
    """Build the config from ``argv`` and ``environ`` (default: the real ones).

    Raises ConfigError for missing/invalid values; argparse itself exits with
    code 2 on unknown flags.
    """
    env = os.environ if environ is None else environ
    args = build_parser().parse_args(argv)

    # Empty environment variables are treated as unset.
    data_dir = args.data_dir if args.data_dir is not None else env.get(ENV_DATA_DIR) or None
    if not data_dir:
        raise ConfigError(f"data directory is required: pass --data-dir or set {ENV_DATA_DIR}")

    raw_port = args.port if args.port is not None else env.get(ENV_PORT) or None
    port = DEFAULT_PORT if raw_port is None else parse_port(raw_port)

    return ServerConfig(data_dir=Path(data_dir), port=port)


def prepare_data_dir(path: Path) -> Path:
    """Create the data directory if needed and check that it is usable.

    Returns the absolute path. Raises ConfigError if it cannot be used.
    """
    path = path.absolute()
    try:
        path.mkdir(parents=True, exist_ok=True)
    except FileExistsError:
        raise ConfigError(f"data directory {str(path)!r} exists and is not a directory") from None
    except OSError as exc:
        raise ConfigError(f"cannot create data directory {str(path)!r}: {exc.strerror}") from None
    if not os.access(path, os.R_OK | os.W_OK | os.X_OK):
        raise ConfigError(f"data directory {str(path)!r} is not readable and writable")
    return path
