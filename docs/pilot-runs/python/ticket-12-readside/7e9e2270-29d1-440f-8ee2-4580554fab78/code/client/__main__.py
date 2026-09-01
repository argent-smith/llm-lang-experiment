import argparse
import os
import sys

from .push import PushError, push

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


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)

    if args.command == "push":
        return run_push(args)

    print(f"syncbox: '{args.command}' is not implemented yet", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
