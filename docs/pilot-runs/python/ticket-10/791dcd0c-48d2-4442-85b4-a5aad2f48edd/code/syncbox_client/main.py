import sys

import requests

from .client import PullError, PushError, StatusError, SyncError, pull, push, status, sync
from .config import ClientConfigError, parse_args


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    try:
        args = parse_args(argv)
    except ClientConfigError as exc:
        print(f"syncbox: {exc}", file=sys.stderr)
        return 1

    if args.command == "pull":
        return _run_pull(args)

    if args.command == "sync":
        return _run_sync(args)

    if args.command == "status":
        return _run_status(args)

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


def _run_pull(args) -> int:
    try:
        result = pull(args.dir, args.server)
    except requests.exceptions.RequestException as exc:
        print(f"syncbox: could not reach server {args.server}: {exc}", file=sys.stderr)
        return 1
    except PullError as exc:
        print(f"syncbox: {exc}", file=sys.stderr)
        return 1

    for key in result.downloaded:
        print(f"downloaded {key}")
    print(
        f"pull complete: {len(result.downloaded)} downloaded, "
        f"{len(result.unchanged)} unchanged"
    )
    return 0


def _run_sync(args) -> int:
    try:
        result = sync(args.dir, args.server)
    except requests.exceptions.RequestException as exc:
        print(f"syncbox: could not reach server {args.server}: {exc}", file=sys.stderr)
        return 1
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


def _run_status(args) -> int:
    try:
        result = status(args.dir, args.server)
    except requests.exceptions.RequestException as exc:
        print(f"syncbox: could not reach server {args.server}: {exc}", file=sys.stderr)
        return 1
    except StatusError as exc:
        print(f"syncbox: {exc}", file=sys.stderr)
        return 1

    if not result.to_upload and not result.to_download:
        print("status: no differences, local and server are in sync")
        return 0

    if result.to_upload:
        print(f"would upload (local -> server): {len(result.to_upload)}")
        for key in result.to_upload:
            print(f"  upload   {key}")
    if result.to_download:
        print(f"would download (server -> local): {len(result.to_download)}")
        for key in result.to_download:
            print(f"  download {key}")
    print(
        f"status complete: {len(result.to_upload)} to upload, "
        f"{len(result.to_download)} to download, {len(result.unchanged)} unchanged"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
