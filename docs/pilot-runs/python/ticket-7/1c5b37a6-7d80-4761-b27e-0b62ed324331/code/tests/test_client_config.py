import pytest

from syncbox_client.config import ClientConfigError, parse_args


def test_requires_server():
    with pytest.raises(ClientConfigError):
        parse_args(["push", "/tmp/x"], env={})


def test_server_from_flag():
    args = parse_args(["push", "/tmp/x", "--server", "http://host:8080"], env={})
    assert args.command == "push"
    assert args.dir == "/tmp/x"
    assert args.server == "http://host:8080"


def test_server_from_env():
    args = parse_args(["push", "/tmp/x"], env={"SYNCBOX_SERVER": "http://env:8080"})
    assert args.server == "http://env:8080"


def test_flag_overrides_env():
    args = parse_args(
        ["push", "/tmp/x", "--server", "http://flag:8080"],
        env={"SYNCBOX_SERVER": "http://env:8080"},
    )
    assert args.server == "http://flag:8080"


@pytest.mark.parametrize("command", ["push", "pull", "sync", "status"])
def test_accepts_all_four_commands(command):
    args = parse_args([command, "/tmp/x", "--server", "http://host:8080"], env={})
    assert args.command == command


def test_rejects_unknown_command():
    with pytest.raises(SystemExit):
        parse_args(["frobnicate", "/tmp/x", "--server", "http://host:8080"], env={})
