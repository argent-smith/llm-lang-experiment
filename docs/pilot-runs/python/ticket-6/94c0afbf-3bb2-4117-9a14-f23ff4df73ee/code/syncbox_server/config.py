import argparse
import os
from dataclasses import dataclass

DEFAULT_PORT = 8080


@dataclass(frozen=True)
class Config:
    data_dir: str
    port: int


class ConfigError(Exception):
    pass


def load_config(argv, env=None):
    env = os.environ if env is None else env

    parser = argparse.ArgumentParser(prog="syncbox-server")
    parser.add_argument("--data-dir", dest="data_dir", default=None)
    parser.add_argument("--port", dest="port", type=int, default=None)
    args = parser.parse_args(argv)

    data_dir = args.data_dir or env.get("SYNCBOX_DATA_DIR")
    if not data_dir:
        raise ConfigError("--data-dir is required (or set SYNCBOX_DATA_DIR)")

    if args.port is not None:
        port = args.port
    elif env.get("SYNCBOX_PORT"):
        try:
            port = int(env["SYNCBOX_PORT"])
        except ValueError as exc:
            raise ConfigError(
                f"invalid SYNCBOX_PORT value: {env['SYNCBOX_PORT']!r}"
            ) from exc
    else:
        port = DEFAULT_PORT

    return Config(data_dir=data_dir, port=port)
