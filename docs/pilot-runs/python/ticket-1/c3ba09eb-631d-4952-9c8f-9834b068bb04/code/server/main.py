import argparse
import os
from pathlib import Path

from server.app import create_app

DEFAULT_PORT = 8080


def parse_args(argv=None):
    parser = argparse.ArgumentParser(prog="syncbox-server")
    parser.add_argument(
        "--data-dir",
        default=os.environ.get("SYNCBOX_DATA_DIR"),
        help="Path to the blob storage root (or SYNCBOX_DATA_DIR)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("SYNCBOX_PORT", DEFAULT_PORT)),
        help="Port to listen on (or SYNCBOX_PORT)",
    )
    args = parser.parse_args(argv)
    if not args.data_dir:
        parser.error("--data-dir is required (or set SYNCBOX_DATA_DIR)")
    return args


def main(argv=None):
    args = parse_args(argv)
    data_dir = Path(args.data_dir)
    data_dir.mkdir(parents=True, exist_ok=True)
    app = create_app(data_dir)
    app.run(host="0.0.0.0", port=args.port)


if __name__ == "__main__":
    main()
