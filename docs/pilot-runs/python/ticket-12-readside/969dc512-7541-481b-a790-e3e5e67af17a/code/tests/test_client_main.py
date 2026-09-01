import threading

import pytest
from werkzeug.serving import make_server

from client.__main__ import main, parse_args
from server.app import create_app


# --- argument parsing --------------------------------------------------


def test_server_required_without_flag_or_env(monkeypatch, tmp_path):
    monkeypatch.delenv("SYNCBOX_SERVER", raising=False)

    with pytest.raises(SystemExit):
        parse_args(["push", str(tmp_path)])


def test_server_from_flag(monkeypatch, tmp_path):
    monkeypatch.delenv("SYNCBOX_SERVER", raising=False)

    args = parse_args(["push", str(tmp_path), "--server", "http://example.test"])

    assert args.server == "http://example.test"
    assert args.dir == str(tmp_path)
    assert args.command == "push"


def test_server_from_env(monkeypatch, tmp_path):
    monkeypatch.setenv("SYNCBOX_SERVER", "http://from-env.test")

    args = parse_args(["push", str(tmp_path)])

    assert args.server == "http://from-env.test"


def test_server_flag_overrides_env(monkeypatch, tmp_path):
    monkeypatch.setenv("SYNCBOX_SERVER", "http://from-env.test")

    args = parse_args(["push", str(tmp_path), "--server", "http://from-flag.test"])

    assert args.server == "http://from-flag.test"


def test_command_required(monkeypatch):
    with pytest.raises(SystemExit):
        parse_args([])


def test_unknown_command_rejected(monkeypatch, tmp_path):
    with pytest.raises(SystemExit):
        parse_args(["bogus", str(tmp_path), "--server", "http://example.test"])


@pytest.mark.parametrize("command", ["push", "pull", "sync", "status"])
def test_all_four_commands_accepted_by_parser(command, tmp_path):
    args = parse_args([command, str(tmp_path), "--server", "http://example.test"])

    assert args.command == command


# --- unimplemented commands report cleanly, don't crash -----------------


@pytest.mark.parametrize("command", ["pull", "sync", "status"])
def test_unimplemented_commands_print_message_and_exit_nonzero(command, tmp_path, capsys):
    exit_code = main([command, str(tmp_path), "--server", "http://example.test"])

    assert exit_code != 0
    captured = capsys.readouterr()
    assert command in captured.err
    assert "not implemented" in captured.err


# --- push wiring through main() ------------------------------------------


@pytest.fixture
def live_server(tmp_path):
    data_dir = tmp_path / "data"
    data_dir.mkdir()
    app = create_app(str(data_dir))
    httpd = make_server("127.0.0.1", 0, app)
    thread = threading.Thread(target=httpd.serve_forever)
    thread.start()
    try:
        yield f"http://127.0.0.1:{httpd.server_port}", data_dir
    finally:
        httpd.shutdown()
        thread.join()


def test_main_push_uploads_and_returns_zero(tmp_path, live_server, capsys):
    server_url, data_dir = live_server
    source = tmp_path / "source"
    source.mkdir()
    (source / "a.txt").write_bytes(b"hello")

    exit_code = main(["push", str(source), "--server", server_url])

    assert exit_code == 0
    assert (data_dir / "a.txt").read_bytes() == b"hello"
    captured = capsys.readouterr()
    assert "a.txt" in captured.out


def test_main_push_server_unreachable_prints_error_and_exits_nonzero(tmp_path, capsys):
    source = tmp_path / "source"
    source.mkdir()
    (source / "a.txt").write_bytes(b"x")

    exit_code = main(["push", str(source), "--server", "http://127.0.0.1:1"])

    assert exit_code != 0
    captured = capsys.readouterr()
    assert "syncbox:" in captured.err
