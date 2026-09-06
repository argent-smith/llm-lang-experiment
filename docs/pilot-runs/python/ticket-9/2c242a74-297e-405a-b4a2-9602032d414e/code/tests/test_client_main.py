import pytest

from syncbox_client.main import main


def test_missing_server_flag_prints_error_and_returns_nonzero(tmp_path, capsys, monkeypatch):
    monkeypatch.delenv("SYNCBOX_SERVER", raising=False)

    exit_code = main(["push", str(tmp_path)])
    captured = capsys.readouterr()

    assert exit_code != 0
    assert "server" in captured.err.lower()


@pytest.mark.parametrize("command", ["status", "sync"])
def test_unimplemented_commands_print_message_instead_of_crashing(command, tmp_path, capsys):
    exit_code = main([command, str(tmp_path), "--server", "http://127.0.0.1:1"])
    captured = capsys.readouterr()

    assert exit_code != 0
    assert "not implemented" in captured.err.lower()


def test_push_end_to_end_via_main(live_server, tmp_path, capsys):
    server_url, data_dir = live_server
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "f.txt").write_bytes(b"content")

    exit_code = main(["push", str(client_dir), "--server", server_url])
    captured = capsys.readouterr()

    assert exit_code == 0
    assert "f.txt" in captured.out
    assert (data_dir / "f.txt").read_bytes() == b"content"


def test_push_reports_error_when_server_unreachable(tmp_path, capsys):
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "f.txt").write_bytes(b"content")

    exit_code = main(["push", str(client_dir), "--server", "http://127.0.0.1:1"])
    captured = capsys.readouterr()

    assert exit_code != 0
    assert captured.err.strip() != ""


def test_pull_end_to_end_via_main(live_server, tmp_path, capsys):
    server_url, data_dir = live_server
    (data_dir / "f.txt").write_bytes(b"content")
    client_dir = tmp_path / "client"
    client_dir.mkdir()

    exit_code = main(["pull", str(client_dir), "--server", server_url])
    captured = capsys.readouterr()

    assert exit_code == 0
    assert "f.txt" in captured.out
    assert (client_dir / "f.txt").read_bytes() == b"content"


def test_pull_reports_error_when_server_unreachable(tmp_path, capsys):
    client_dir = tmp_path / "client"
    client_dir.mkdir()

    exit_code = main(["pull", str(client_dir), "--server", "http://127.0.0.1:1"])
    captured = capsys.readouterr()

    assert exit_code != 0
    assert captured.err.strip() != ""
