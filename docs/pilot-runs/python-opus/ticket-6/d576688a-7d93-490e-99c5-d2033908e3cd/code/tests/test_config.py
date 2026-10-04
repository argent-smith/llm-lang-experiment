from __future__ import annotations

from pathlib import Path

import pytest

from syncbox.server.config import (
    DEFAULT_PORT,
    ConfigError,
    load_config,
    prepare_data_dir,
)


def test_flags():
    config = load_config(["--data-dir", "/srv/data", "--port", "9000"], environ={})
    assert config.data_dir == Path("/srv/data")
    assert config.port == 9000


def test_flags_with_equals_sign():
    config = load_config(["--data-dir=/srv/data", "--port=9000"], environ={})
    assert config.data_dir == Path("/srv/data")
    assert config.port == 9000


def test_port_defaults_to_8080():
    config = load_config(["--data-dir", "/srv/data"], environ={})
    assert config.port == DEFAULT_PORT == 8080


def test_environment_variables():
    env = {"SYNCBOX_DATA_DIR": "/env/data", "SYNCBOX_PORT": "9100"}
    config = load_config([], environ=env)
    assert config.data_dir == Path("/env/data")
    assert config.port == 9100


def test_flags_override_environment():
    env = {"SYNCBOX_DATA_DIR": "/env/data", "SYNCBOX_PORT": "9100"}
    config = load_config(["--data-dir", "/flag/data", "--port", "9200"], environ=env)
    assert config.data_dir == Path("/flag/data")
    assert config.port == 9200


def test_flags_and_environment_can_be_mixed():
    config = load_config(["--port", "9200"], environ={"SYNCBOX_DATA_DIR": "/env/data"})
    assert config.data_dir == Path("/env/data")
    assert config.port == 9200


def test_empty_environment_variables_are_ignored():
    env = {"SYNCBOX_DATA_DIR": "/env/data", "SYNCBOX_PORT": ""}
    assert load_config([], environ=env).port == DEFAULT_PORT
    with pytest.raises(ConfigError, match="data directory is required"):
        load_config([], environ={"SYNCBOX_DATA_DIR": ""})


def test_data_dir_is_required():
    with pytest.raises(ConfigError, match="data directory is required"):
        load_config(["--port", "9000"], environ={})


@pytest.mark.parametrize("port", ["0", "65536", "-1", "abc", "80.5", " 80", "+80", "8_080", ""])
def test_invalid_port_flag(port):
    with pytest.raises(ConfigError, match="invalid port"):
        load_config(["--data-dir", "/d", "--port", port], environ={})


def test_invalid_port_env():
    with pytest.raises(ConfigError, match="invalid port"):
        load_config(["--data-dir", "/d"], environ={"SYNCBOX_PORT": "http"})


@pytest.mark.parametrize("port", ["1", "65535", "08080"])
def test_port_range_edges(port):
    assert load_config(["--data-dir", "/d", "--port", port], environ={}).port == int(port)


def test_unknown_flag_is_a_usage_error():
    with pytest.raises(SystemExit) as exc:
        load_config(["--data-dir", "/d", "--bogus"], environ={})
    assert exc.value.code == 2


def test_prepare_data_dir_creates_missing_directories(tmp_path):
    target = tmp_path / "a" / "b"
    assert prepare_data_dir(target) == target
    assert target.is_dir()


def test_prepare_data_dir_accepts_existing_directory(tmp_path):
    assert prepare_data_dir(tmp_path) == tmp_path


def test_prepare_data_dir_returns_absolute_path(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    assert prepare_data_dir(Path("rel")) == tmp_path / "rel"


def test_prepare_data_dir_rejects_regular_file(tmp_path):
    target = tmp_path / "file"
    target.write_text("x")
    with pytest.raises(ConfigError, match="not a directory"):
        prepare_data_dir(target)
