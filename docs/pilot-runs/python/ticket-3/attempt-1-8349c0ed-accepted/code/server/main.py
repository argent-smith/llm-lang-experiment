from __future__ import annotations

import argparse
import os
import sys

from server.app import create_app


def _resolve_config(argv: list[str]) -> tuple[str, int]:
    parser = argparse.ArgumentParser(prog="syncbox-server")
    parser.add_argument("--data-dir", dest="data_dir", default=None)
    parser.add_argument("--port", dest="port", type=int, default=None)
    args = parser.parse_args(argv)

    data_dir = args.data_dir or os.environ.get("SYNCBOX_DATA_DIR")
    if not data_dir:
        print("error: --data-dir is required (or set SYNCBOX_DATA_DIR)", file=sys.stderr)
        sys.exit(2)

    if args.port is not None:
        port = args.port
    else:
        port_raw = os.environ.get("SYNCBOX_PORT", "8080")
        try:
            port = int(port_raw)
        except ValueError:
            print(f"error: invalid SYNCBOX_PORT value: {port_raw!r}", file=sys.stderr)
            sys.exit(2)

    return data_dir, port


def main(argv: list[str] | None = None) -> None:
    data_dir, port = _resolve_config(sys.argv[1:] if argv is None else argv)
    os.makedirs(data_dir, exist_ok=True)

    app = create_app(data_dir)

    from waitress import serve

    print(f"syncbox server listening on 0.0.0.0:{port}, data-dir={data_dir}", file=sys.stderr)
    serve(app, host="0.0.0.0", port=port)


if __name__ == "__main__":
    main()
