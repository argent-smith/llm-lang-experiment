"""Command line: ``syncbox <push|pull|sync|status> <dir> --server <url>``.

``--server`` falls back to the SYNCBOX_SERVER environment variable (the flag
wins; an empty variable counts as unset). Exit codes: 0 on success, 1 if the
command failed, 2 on a usage error.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Mapping, Sequence

from .api import ServerClient, parse_server_url
from .errors import ClientError
from .pull import pull
from .push import push

ENV_SERVER = "SYNCBOX_SERVER"

EXIT_OK = 0
EXIT_FAILURE = 1
EXIT_USAGE = 2

COMMANDS = {
    "push": "upload files that are missing or different on the server",
    "pull": "download files that are missing or different locally",
    "sync": "push and pull; on conflict the newer version wins",
    "status": "show what push/pull would transfer, changing nothing",
}
IMPLEMENTED = {"push", "pull"}


def _error(message: str) -> None:
    print(f"syncbox: error: {message}", file=sys.stderr, flush=True)


def _warn(message: str) -> None:
    print(f"syncbox: warning: {message}", file=sys.stderr, flush=True)


def _report(line: str) -> None:
    print(line, flush=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="syncbox", description="Syncbox client.")
    commands = parser.add_subparsers(dest="command", metavar="<command>", required=True)
    for name, summary in COMMANDS.items():
        command = commands.add_parser(name, help=summary, description=summary)
        command.add_argument("dir", metavar="<dir>", help="local directory")
        command.add_argument(
            "--server",
            metavar="<url>",
            help=f"server URL, e.g. http://127.0.0.1:8080 (env: {ENV_SERVER}; required)",
        )
    return parser


def main(argv: Sequence[str] | None = None, environ: Mapping[str, str] | None = None) -> int:
    env = os.environ if environ is None else environ
    args = build_parser().parse_args(argv)  # exits with EXIT_USAGE on bad arguments

    raw_server = args.server if args.server is not None else env.get(ENV_SERVER) or None
    if not raw_server:
        _error(f"server URL is required: pass --server or set {ENV_SERVER}")
        return EXIT_USAGE
    try:
        server = parse_server_url(raw_server)
    except ValueError as exc:
        _error(str(exc))
        return EXIT_USAGE

    if args.command not in IMPLEMENTED:
        _error(f"'{args.command}' is not implemented yet; only 'push' and 'pull' are available")
        return EXIT_FAILURE

    root = Path(args.dir)
    if not root.is_dir():
        problem = "is not a directory" if root.exists() else "does not exist"
        _error(f"{args.dir!r} {problem}")
        return EXIT_FAILURE

    try:
        with ServerClient(server) as client:
            if args.command == "push":
                pushed = push(root, client, report=_report, warn=_warn)
                summary = f"{len(pushed.uploaded)} uploaded, {len(pushed.unchanged)} already up to date"
            else:
                pulled = pull(root, client, report=_report, warn=_warn)
                summary = f"{len(pulled.downloaded)} downloaded, {len(pulled.unchanged)} already up to date"
    except ClientError as exc:
        _error(str(exc))
        return EXIT_FAILURE
    except KeyboardInterrupt:
        _error("interrupted")
        return 130
    _report(summary)
    return EXIT_OK
