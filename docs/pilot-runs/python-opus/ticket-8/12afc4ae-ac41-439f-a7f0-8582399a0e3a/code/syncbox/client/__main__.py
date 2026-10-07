"""Entry point: ``python -m syncbox.client <command> <dir> --server <url>``."""

from __future__ import annotations

import sys

from .cli import main

if __name__ == "__main__":
    sys.exit(main())
