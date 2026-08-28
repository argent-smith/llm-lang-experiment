import pytest

from server.__main__ import parse_args


def test_data_dir_required_without_flag_or_env(monkeypatch):
    monkeypatch.delenv("SYNCBOX_DATA_DIR", raising=False)

    with pytest.raises(SystemExit):
        parse_args([])


def test_data_dir_from_flag(monkeypatch):
    monkeypatch.delenv("SYNCBOX_DATA_DIR", raising=False)

    args = parse_args(["--data-dir", "/tmp/x"])

    assert args.data_dir == "/tmp/x"


def test_data_dir_from_env(monkeypatch):
    monkeypatch.setenv("SYNCBOX_DATA_DIR", "/tmp/from-env")

    args = parse_args([])

    assert args.data_dir == "/tmp/from-env"


def test_data_dir_flag_overrides_env(monkeypatch):
    monkeypatch.setenv("SYNCBOX_DATA_DIR", "/tmp/from-env")

    args = parse_args(["--data-dir", "/tmp/from-flag"])

    assert args.data_dir == "/tmp/from-flag"


def test_port_defaults_to_8080(monkeypatch):
    monkeypatch.delenv("SYNCBOX_PORT", raising=False)

    args = parse_args(["--data-dir", "/tmp/x"])

    assert args.port == 8080


def test_port_from_env(monkeypatch):
    monkeypatch.setenv("SYNCBOX_PORT", "9090")

    args = parse_args(["--data-dir", "/tmp/x"])

    assert args.port == 9090


def test_port_flag_overrides_env(monkeypatch):
    monkeypatch.setenv("SYNCBOX_PORT", "9090")

    args = parse_args(["--data-dir", "/tmp/x", "--port", "7070"])

    assert args.port == 7070
