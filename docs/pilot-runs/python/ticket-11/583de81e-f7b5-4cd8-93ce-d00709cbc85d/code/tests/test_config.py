import pytest

from syncbox_server.config import ConfigError, load_config


def test_requires_data_dir():
    with pytest.raises(ConfigError):
        load_config([], env={})


def test_data_dir_from_flag():
    config = load_config(["--data-dir", "/tmp/x"], env={})
    assert config.data_dir == "/tmp/x"
    assert config.port == 8080


def test_data_dir_from_env():
    config = load_config([], env={"SYNCBOX_DATA_DIR": "/tmp/y"})
    assert config.data_dir == "/tmp/y"
    assert config.port == 8080


def test_flag_data_dir_overrides_env():
    config = load_config(
        ["--data-dir", "/tmp/flag"], env={"SYNCBOX_DATA_DIR": "/tmp/env"}
    )
    assert config.data_dir == "/tmp/flag"


def test_port_from_flag_overrides_env():
    config = load_config(
        ["--data-dir", "/tmp/x", "--port", "9090"],
        env={"SYNCBOX_PORT": "7070"},
    )
    assert config.port == 9090


def test_port_from_env():
    config = load_config(["--data-dir", "/tmp/x"], env={"SYNCBOX_PORT": "7070"})
    assert config.port == 7070


def test_invalid_port_env_raises():
    with pytest.raises(ConfigError):
        load_config(["--data-dir", "/tmp/x"], env={"SYNCBOX_PORT": "not-a-number"})
