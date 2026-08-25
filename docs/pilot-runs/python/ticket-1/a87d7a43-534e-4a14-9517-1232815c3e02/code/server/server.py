#!/usr/bin/env python3
"""Syncbox HTTP server entrypoint."""

import argparse
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class SyncboxRequestHandler(BaseHTTPRequestHandler):
    server_version = "Syncbox/0.1"

    def do_GET(self):
        if self.path == "/healthz":
            self._send_empty(200)
            return
        self._send_empty(404)

    def _send_empty(self, status):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, fmt, *args):
        pass


def parse_args(argv=None):
    parser = argparse.ArgumentParser(prog="syncbox-server")
    parser.add_argument(
        "--data-dir",
        default=os.environ.get("SYNCBOX_DATA_DIR"),
        help="Directory where blobs are stored (required, or SYNCBOX_DATA_DIR)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("SYNCBOX_PORT", "8080")),
        help="Port to listen on (default 8080, or SYNCBOX_PORT)",
    )
    args = parser.parse_args(argv)

    if not args.data_dir:
        parser.error("--data-dir is required (or set SYNCBOX_DATA_DIR)")

    return args


def main(argv=None):
    args = parse_args(argv)
    os.makedirs(args.data_dir, exist_ok=True)

    server = ThreadingHTTPServer(("0.0.0.0", args.port), SyncboxRequestHandler)
    print(f"syncbox server listening on 0.0.0.0:{args.port}, data-dir={args.data_dir}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
