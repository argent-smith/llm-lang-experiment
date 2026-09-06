import argparse
import os
from dataclasses import dataclass

COMMANDS = ("push", "pull", "sync", "status")


@dataclass(frozen=True)
class ClientArgs:
    command: str
    dir: str
    server: str


class ClientConfigError(Exception):
    pass


def parse_args(argv, env=None):
    env = os.environ if env is None else env

    parser = argparse.ArgumentParser(prog="syncbox")
    parser.add_argument("command", choices=COMMANDS)
    parser.add_argument("dir")
    parser.add_argument("--server", dest="server", default=None)
    args = parser.parse_args(argv)

    server = args.server or env.get("SYNCBOX_SERVER")
    if not server:
        raise ClientConfigError("--server is required (or set SYNCBOX_SERVER)")

    return ClientArgs(command=args.command, dir=args.dir, server=server)
