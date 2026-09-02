import argparse
import os
import sys

from .pull import PullError, pull
from .push import PushError, push
from .status import StatusError, status
from .sync import SyncError, sync

COMMANDS = ("push", "pull", "sync", "status")


def parse_args(argv):
    parser = argparse.ArgumentParser(prog="syncbox")
    subparsers = parser.add_subparsers(dest="command", required=True)

    for name in COMMANDS:
        sub = subparsers.add_parser(name)
        sub.add_argument("dir")
        sub.add_argument(
            "--server",
            default=os.environ.get("SYNCBOX_SERVER"),
            help="Server base URL (or SYNCBOX_SERVER)",
        )

    args = parser.parse_args(argv)

    if not args.server:
        parser.error("--server is required (or set SYNCBOX_SERVER)")

    return args


def run_push(args):
    try:
        result = push(args.dir, args.server)
    except PushError as exc:
        print(f"syncbox: {exc}", file=sys.stderr)
        return 1

    for key in result.uploaded:
        print(f"uploaded {key}")

    print(f"push complete: {len(result.uploaded)} uploaded, {len(result.skipped)} unchanged")
    return 0


def run_pull(args):
    try:
        result = pull(args.dir, args.server)
    except PullError as exc:
        print(f"syncbox: {exc}", file=sys.stderr)
        return 1

    for key in result.downloaded:
        print(f"downloaded {key}")

    print(f"pull complete: {len(result.downloaded)} downloaded, {len(result.skipped)} unchanged")
    return 0


def run_status(args):
    try:
        result = status(args.dir, args.server)
    except StatusError as exc:
        print(f"syncbox: {exc}", file=sys.stderr)
        return 1

    for key in result.to_upload:
        print(f"would upload   {key}")
    for key in result.to_download:
        print(f"would download {key}")

    print(
        f"status complete: {len(result.to_upload)} would upload, "
        f"{len(result.to_download)} would download, {len(result.unchanged)} unchanged"
    )
    return 0


def run_sync(args):
    try:
        result = sync(args.dir, args.server)
    except SyncError as exc:
        print(f"syncbox: {exc}", file=sys.stderr)
        return 1

    for key in result.uploaded:
        print(f"uploaded {key}")
    for key in result.downloaded:
        print(f"downloaded {key}")

    print(
        f"sync complete: {len(result.uploaded)} uploaded, "
        f"{len(result.downloaded)} downloaded, {len(result.unchanged)} unchanged"
    )
    return 0


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)

    if args.command == "push":
        return run_push(args)
    if args.command == "pull":
        return run_pull(args)
    if args.command == "status":
        return run_status(args)
    if args.command == "sync":
        return run_sync(args)

    print(f"syncbox: '{args.command}' is not implemented yet", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
