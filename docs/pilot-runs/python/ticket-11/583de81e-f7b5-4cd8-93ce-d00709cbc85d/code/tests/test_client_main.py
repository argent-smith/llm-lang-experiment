import pytest

from syncbox_client.main import main


def test_missing_server_flag_prints_error_and_returns_nonzero(tmp_path, capsys, monkeypatch):
    monkeypatch.delenv("SYNCBOX_SERVER", raising=False)

    exit_code = main(["push", str(tmp_path)])
    captured = capsys.readouterr()

    assert exit_code != 0
    assert "server" in captured.err.lower()


def test_sync_reports_error_when_server_unreachable(tmp_path, capsys):
    exit_code = main(["sync", str(tmp_path), "--server", "http://127.0.0.1:1"])
    captured = capsys.readouterr()

    assert exit_code != 0
    assert captured.err.strip() != ""


def test_sync_end_to_end_via_main(live_server, tmp_path, capsys):
    server_url, data_dir = live_server
    (data_dir / "server-only.txt").write_bytes(b"from server")
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "local-only.txt").write_bytes(b"from client")

    exit_code = main(["sync", str(client_dir), "--server", server_url])
    captured = capsys.readouterr()

    assert exit_code == 0
    assert "local-only.txt" in captured.out
    assert "server-only.txt" in captured.out
    assert (client_dir / "server-only.txt").read_bytes() == b"from server"
    assert (data_dir / "local-only.txt").read_bytes() == b"from client"


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


def test_status_end_to_end_via_main_reports_both_directions_and_changes_nothing(
    live_server, tmp_path, capsys
):
    server_url, data_dir = live_server
    (data_dir / "server-only.txt").write_bytes(b"from server")

    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "local-only.txt").write_bytes(b"from client")

    exit_code = main(["status", str(client_dir), "--server", server_url])
    captured = capsys.readouterr()

    assert exit_code == 0
    assert "local-only.txt" in captured.out
    assert "server-only.txt" in captured.out
    # read-only: nothing was created on either side
    assert [p.name for p in client_dir.iterdir()] == ["local-only.txt"]
    assert [p.name for p in data_dir.iterdir()] == ["server-only.txt"]


def test_status_reports_no_differences_when_in_sync(live_server, tmp_path, capsys):
    server_url, data_dir = live_server
    (data_dir / "same.txt").write_bytes(b"identical")
    client_dir = tmp_path / "client"
    client_dir.mkdir()
    (client_dir / "same.txt").write_bytes(b"identical")

    exit_code = main(["status", str(client_dir), "--server", server_url])
    captured = capsys.readouterr()

    assert exit_code == 0
    assert "no differences" in captured.out.lower()


def test_status_reports_error_when_server_unreachable(tmp_path, capsys):
    client_dir = tmp_path / "client"
    client_dir.mkdir()

    exit_code = main(["status", str(client_dir), "--server", "http://127.0.0.1:1"])
    captured = capsys.readouterr()

    assert exit_code != 0
    assert captured.err.strip() != ""
