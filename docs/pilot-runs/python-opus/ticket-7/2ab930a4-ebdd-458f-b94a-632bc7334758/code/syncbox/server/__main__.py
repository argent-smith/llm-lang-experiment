"""Entry point: ``python -m syncbox.server --data-dir PATH [--port N]``."""

from __future__ import annotations

import signal
import sys
import threading
from dataclasses import replace
from typing import Sequence

from .app import SyncboxServer
from .config import ConfigError, load_config, prepare_data_dir
from .storage import StoreError

EXIT_STARTUP_ERROR = 1
EXIT_USAGE = 2


def _error(message: str) -> None:
    print(f"syncbox-server: error: {message}", file=sys.stderr, flush=True)


def main(argv: Sequence[str] | None = None) -> int:
    try:
        config = load_config(argv)
    except ConfigError as exc:
        _error(str(exc))
        return EXIT_USAGE

    try:
        config = replace(config, data_dir=prepare_data_dir(config.data_dir))
    except ConfigError as exc:
        _error(str(exc))
        return EXIT_STARTUP_ERROR

    try:
        server = SyncboxServer(config)
    except StoreError as exc:
        _error(str(exc))
        return EXIT_STARTUP_ERROR
    except OSError as exc:
        _error(f"cannot listen on {config.host}:{config.port}: {exc.strerror or exc}")
        return EXIT_STARTUP_ERROR

    # Serve in a worker thread so the main thread can wait for SIGTERM/SIGINT
    # and then shut the server down cleanly (shutdown() must not be called
    # from the thread running serve_forever()).
    stop = threading.Event()
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, lambda *_: stop.set())

    worker = threading.Thread(target=server.serve_forever, name="http-server")
    worker.start()
    print(
        f"syncbox-server: listening on {config.host}:{config.port}, data dir {config.data_dir}",
        file=sys.stderr,
        flush=True,
    )
    try:
        stop.wait()
    finally:
        server.shutdown()
        worker.join()
        server.server_close()
    print("syncbox-server: stopped", file=sys.stderr, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
