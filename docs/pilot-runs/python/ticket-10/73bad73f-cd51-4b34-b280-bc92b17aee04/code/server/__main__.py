import argparse
import os
import sys

from .app import create_app


def parse_args(argv):
    parser = argparse.ArgumentParser(prog="run-server")
    parser.add_argument(
        "--data-dir",
        default=os.environ.get("SYNCBOX_DATA_DIR"),
        help="Root directory for blob storage (or SYNCBOX_DATA_DIR)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("SYNCBOX_PORT", "8080")),
        help="Port to listen on (or SYNCBOX_PORT, default 8080)",
    )
    args = parser.parse_args(argv)

    if not args.data_dir:
        parser.error("--data-dir is required (or set SYNCBOX_DATA_DIR)")

    return args


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    os.makedirs(args.data_dir, exist_ok=True)

    app = create_app(args.data_dir)
    app.run(host="0.0.0.0", port=args.port, threaded=True)


if __name__ == "__main__":
    main()
