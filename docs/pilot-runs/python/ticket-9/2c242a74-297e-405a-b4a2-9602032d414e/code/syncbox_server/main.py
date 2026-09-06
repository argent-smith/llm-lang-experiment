import sys

from .app import create_app
from .config import ConfigError, load_config


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    try:
        config = load_config(argv)
    except ConfigError as exc:
        print(f"run-server: {exc}", file=sys.stderr)
        return 1

    app = create_app(config)
    app.run(host="0.0.0.0", port=config.port, threaded=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
