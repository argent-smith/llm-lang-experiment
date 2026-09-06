import sys

import requests

from .client import PushError, push
from .config import ClientConfigError, parse_args

_NOT_IMPLEMENTED = ("pull", "sync", "status")


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    try:
        args = parse_args(argv)
    except ClientConfigError as exc:
        print(f"syncbox: {exc}", file=sys.stderr)
        return 1

    if args.command in _NOT_IMPLEMENTED:
        print(
            f"syncbox: '{args.command}' is not implemented yet "
            "(planned for a future ticket)",
            file=sys.stderr,
        )
        return 2

    return _run_push(args)


def _run_push(args) -> int:
    try:
        result = push(args.dir, args.server)
    except requests.exceptions.RequestException as exc:
        print(f"syncbox: could not reach server {args.server}: {exc}", file=sys.stderr)
        return 1
    except PushError as exc:
        print(f"syncbox: {exc}", file=sys.stderr)
        return 1

    for key in result.uploaded:
        print(f"uploaded {key}")
    print(
        f"push complete: {len(result.uploaded)} uploaded, "
        f"{len(result.unchanged)} unchanged"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
