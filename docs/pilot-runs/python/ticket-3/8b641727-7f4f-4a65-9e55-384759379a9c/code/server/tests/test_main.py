import pytest

from server.main import parse_args


def test_requires_data_dir(monkeypatch):
    monkeypatch.delenv("SYNCBOX_DATA_DIR", raising=False)
    monkeypatch.delenv("SYNCBOX_PORT", raising=False)

    with pytest.raises(SystemExit):
        parse_args([])


def test_defaults_port_to_8080(monkeypatch):
    monkeypatch.delenv("SYNCBOX_PORT", raising=False)

    args = parse_args(["--data-dir", "/tmp/data"])

    assert args.port == 8080


def test_cli_flags(monkeypatch):
    monkeypatch.delenv("SYNCBOX_DATA_DIR", raising=False)
    monkeypatch.delenv("SYNCBOX_PORT", raising=False)

    args = parse_args(["--data-dir", "/tmp/data", "--port", "9090"])

    assert args.data_dir == "/tmp/data"
    assert args.port == 9090


def test_env_vars(monkeypatch):
    monkeypatch.setenv("SYNCBOX_DATA_DIR", "/tmp/env-data")
    monkeypatch.setenv("SYNCBOX_PORT", "9191")

    args = parse_args([])

    assert args.data_dir == "/tmp/env-data"
    assert args.port == 9191


def test_cli_flags_override_env(monkeypatch):
    monkeypatch.setenv("SYNCBOX_DATA_DIR", "/tmp/env-data")
    monkeypatch.setenv("SYNCBOX_PORT", "9191")

    args = parse_args(["--data-dir", "/tmp/cli-data", "--port", "7070"])

    assert args.data_dir == "/tmp/cli-data"
    assert args.port == 7070
