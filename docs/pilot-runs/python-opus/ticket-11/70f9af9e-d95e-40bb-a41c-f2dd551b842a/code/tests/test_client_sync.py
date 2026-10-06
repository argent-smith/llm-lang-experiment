"""``syncbox sync`` against an in-process server, run through cli.main()."""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path

import pytest

from syncbox.client import api, sync as sync_module
from syncbox.client.api import parse_server_url
from syncbox.client.cli import main
from syncbox.client.state import SyncState, state_dir

from .test_blobs import delete, get, list_blobs
from .test_client_pull import files_only, seed, tree
from .test_client_push import FILES, sha, url_of, write

# Whole seconds apart, well clear of any timestamp rounding.
OLD = 1_600_000_000
NEW = 1_700_000_000


@pytest.fixture
def local(tmp_path_factory) -> Path:
    """The directory to sync (the server fixture's data dir is tmp_path)."""
    return tmp_path_factory.mktemp("local")


@pytest.fixture
def state(tmp_path_factory) -> Path:
    """Where sync keeps its state between runs."""
    return tmp_path_factory.mktemp("state")


@pytest.fixture
def requests(server, monkeypatch) -> list[tuple[str, str]]:
    """(method, path) of every request the server has received, in order."""
    received: list[tuple[str, str]] = []
    handler = server.RequestHandlerClass
    real_dispatch = handler._dispatch

    def recording_dispatch(self):
        received.append((self.command, self.path))
        real_dispatch(self)

    monkeypatch.setattr(handler, "_dispatch", recording_dispatch)
    return received


def sync(local: Path, server, state: Path, env: dict[str, str] | None = None) -> int:
    return main(
        ["sync", str(local), "--server", url_of(server)],
        environ={"SYNCBOX_STATE_DIR": str(state), **(env or {})},
    )


def remote_files(conn) -> dict[str, bytes]:
    files = {}
    for blob in list_blobs(conn):
        resp, body = get(conn, blob["key"])
        assert resp.status == 200
        files[blob["key"]] = body
    return files


def set_local_mtime(local: Path, key: str, seconds: float) -> None:
    os.utime(local.joinpath(*key.split("/")), (seconds, seconds))


def set_server_mtime(server, key: str, seconds: float) -> None:
    os.utime(server.store.root.joinpath(*key.split("/")), (seconds, seconds))


def report(out: str) -> list[str]:
    """The per-file lines of sync output, without the summary."""
    return out.splitlines()[:-1]


def summary(out: str) -> str:
    return out.splitlines()[-1]


def changes(requests: list[tuple[str, str]]) -> list[tuple[str, str]]:
    """The requests other than listing blobs."""
    return [r for r in requests if r != ("GET", "/blobs")]


def synced_once(server, conn, local, state, capsys, files: dict[str, bytes]) -> None:
    """Both sides hold ``files`` and sync has recorded that as their common state."""
    seed(conn, files)
    write(local, files)
    assert sync(local, server, state) == 0
    assert capsys.readouterr().out == f"0 uploaded, 0 downloaded, {len(files)} already up to date\n"


# --- files present on one side only -------------------------------------------


def test_file_only_present_locally_is_uploaded(server, conn, local, state, capsys):
    write(local, {"docs/new.txt": b"local only"})

    assert sync(local, server, state) == 0

    assert remote_files(conn) == {"docs/new.txt": b"local only"}
    assert files_only(local) == {"docs/new.txt": b"local only"}
    out = capsys.readouterr().out
    assert report(out) == ["upload    new       docs/new.txt"]
    assert summary(out) == "1 uploaded, 0 downloaded, 0 already up to date"


def test_file_only_present_on_the_server_is_downloaded(server, conn, local, state, capsys):
    seed(conn, {"docs/deep/remote.txt": b"server only"})

    assert sync(local, server, state) == 0

    assert files_only(local) == {"docs/deep/remote.txt": b"server only"}
    assert remote_files(conn) == {"docs/deep/remote.txt": b"server only"}
    out = capsys.readouterr().out
    assert report(out) == ["download  new       docs/deep/remote.txt"]
    assert summary(out) == "0 uploaded, 1 downloaded, 0 already up to date"


def test_first_sync_merges_both_trees(server, conn, local, state, capsys):
    seed(conn, {"remote/only": b"r", "shared/same": b"same"})
    write(local, {**FILES, "shared/same": b"same"})

    assert sync(local, server, state) == 0

    expected = {**FILES, "remote/only": b"r", "shared/same": b"same"}
    assert files_only(local) == expected
    assert remote_files(conn) == expected
    out = capsys.readouterr().out
    assert sorted(report(out)) == sorted(
        [f"upload    new       {key}" for key in FILES] + ["download  new       remote/only"]
    )
    assert summary(out) == f"{len(FILES)} uploaded, 1 downloaded, 1 already up to date"


def test_second_sync_transfers_nothing(server, conn, local, state, requests, capsys):
    seed(conn, {"remote": b"r"})
    write(local, FILES)
    assert sync(local, server, state) == 0
    requests.clear()
    capsys.readouterr()

    assert sync(local, server, state) == 0

    assert changes(requests) == []
    assert capsys.readouterr().out == f"0 uploaded, 0 downloaded, {len(FILES) + 1} already up to date\n"


def test_identical_files_are_compared_by_content_not_time(server, conn, local, state, requests, capsys):
    seed(conn, {"same": b"same content"})
    write(local, {"same": b"same content"})
    set_local_mtime(local, "same", NEW)
    set_server_mtime(server, "same", OLD)
    requests.clear()

    assert sync(local, server, state) == 0

    assert changes(requests) == []
    assert capsys.readouterr().out == "0 uploaded, 0 downloaded, 1 already up to date\n"


# --- files changed on one side since the last sync -------------------------------


def test_file_changed_only_locally_is_uploaded(server, conn, local, state, capsys):
    synced_once(server, conn, local, state, capsys, {"notes.txt": b"v1", "other": b"o"})
    write(local, {"notes.txt": b"v2 local"})
    # The server's copy is newer, but unchanged since the last sync: the local change wins.
    set_local_mtime(local, "notes.txt", OLD)
    set_server_mtime(server, "notes.txt", NEW)

    assert sync(local, server, state) == 0

    assert remote_files(conn) == {"notes.txt": b"v2 local", "other": b"o"}
    assert files_only(local) == {"notes.txt": b"v2 local", "other": b"o"}
    out = capsys.readouterr().out
    assert report(out) == ["upload    changed   notes.txt"]
    assert summary(out) == "1 uploaded, 0 downloaded, 1 already up to date"


def test_file_changed_only_on_the_server_is_downloaded(server, conn, local, state, capsys):
    synced_once(server, conn, local, state, capsys, {"docs/notes.txt": b"v1", "other": b"o"})
    seed(conn, {"docs/notes.txt": b"v2 server"})
    # The local copy is newer, but unchanged since the last sync: the server's change wins.
    set_local_mtime(local, "docs/notes.txt", NEW)
    set_server_mtime(server, "docs/notes.txt", OLD)

    assert sync(local, server, state) == 0

    assert files_only(local) == {"docs/notes.txt": b"v2 server", "other": b"o"}
    assert remote_files(conn) == {"docs/notes.txt": b"v2 server", "other": b"o"}
    out = capsys.readouterr().out
    assert report(out) == ["download  changed   docs/notes.txt"]
    assert summary(out) == "0 uploaded, 1 downloaded, 1 already up to date"


def test_changes_on_both_sides_to_different_files_are_all_kept(server, conn, local, state, capsys):
    synced_once(server, conn, local, state, capsys, {"a": b"a1", "b": b"b1", "c": b"c1"})
    write(local, {"a": b"a2 local", "new-local": b"l"})
    seed(conn, {"b": b"b2 server", "new-remote": b"r"})

    assert sync(local, server, state) == 0

    expected = {"a": b"a2 local", "b": b"b2 server", "c": b"c1", "new-local": b"l", "new-remote": b"r"}
    assert files_only(local) == expected
    assert remote_files(conn) == expected
    assert report(capsys.readouterr().out) == [
        "upload    changed   a",
        "download  changed   b",
        "upload    new       new-local",
        "download  new       new-remote",
    ]


# --- conflicts: changed on both sides since the last sync -------------------------


def test_conflict_newer_local_version_wins(server, conn, local, state, capsys):
    synced_once(server, conn, local, state, capsys, {"doc.txt": b"base"})
    write(local, {"doc.txt": b"local edit"})
    seed(conn, {"doc.txt": b"server edit"})
    set_local_mtime(local, "doc.txt", NEW)
    set_server_mtime(server, "doc.txt", OLD)

    assert sync(local, server, state) == 0

    assert remote_files(conn) == {"doc.txt": b"local edit"}
    assert files_only(local) == {"doc.txt": b"local edit"}
    out = capsys.readouterr().out
    assert report(out) == ["upload    conflict  doc.txt  (local is newer)"]
    assert summary(out) == "1 uploaded, 0 downloaded, 0 already up to date (1 conflict resolved)"


def test_conflict_newer_server_version_wins(server, conn, local, state, capsys):
    synced_once(server, conn, local, state, capsys, {"dir/doc.txt": b"base"})
    write(local, {"dir/doc.txt": b"local edit"})
    seed(conn, {"dir/doc.txt": b"server edit"})
    set_local_mtime(local, "dir/doc.txt", OLD)
    set_server_mtime(server, "dir/doc.txt", NEW)

    assert sync(local, server, state) == 0

    assert files_only(local) == {"dir/doc.txt": b"server edit"}
    assert remote_files(conn) == {"dir/doc.txt": b"server edit"}
    out = capsys.readouterr().out
    assert report(out) == ["download  conflict  dir/doc.txt  (server is newer)"]
    assert summary(out) == "0 uploaded, 1 downloaded, 0 already up to date (1 conflict resolved)"


@pytest.mark.parametrize("mtime_ns", [NEW * 10**9, NEW * 10**9 + 123_456_789])
def test_conflict_with_equal_mtime_local_version_wins(server, conn, local, state, capsys, mtime_ns):
    synced_once(server, conn, local, state, capsys, {"doc.txt": b"base"})
    write(local, {"doc.txt": b"local edit"})
    seed(conn, {"doc.txt": b"server edit"})
    os.utime(local / "doc.txt", ns=(mtime_ns, mtime_ns))
    os.utime(server.store.root / "doc.txt", ns=(mtime_ns, mtime_ns))

    assert sync(local, server, state) == 0

    assert remote_files(conn) == {"doc.txt": b"local edit"}
    assert files_only(local) == {"doc.txt": b"local edit"}
    assert report(capsys.readouterr().out) == ["upload    conflict  doc.txt  (same modification time, local wins)"]


def test_conflicts_are_decided_per_file(server, conn, local, state, capsys):
    synced_once(server, conn, local, state, capsys, {"l": b"base", "s": b"base", "t": b"base"})
    write(local, {"l": b"local l", "s": b"local s", "t": b"local t"})
    seed(conn, {"l": b"server l", "s": b"server s", "t": b"server t"})
    for key, local_time, server_time in [("l", NEW, OLD), ("s", OLD, NEW), ("t", NEW, NEW)]:
        set_local_mtime(local, key, local_time)
        set_server_mtime(server, key, server_time)

    assert sync(local, server, state) == 0

    expected = {"l": b"local l", "s": b"server s", "t": b"local t"}
    assert files_only(local) == expected
    assert remote_files(conn) == expected
    out = capsys.readouterr().out
    assert summary(out) == "2 uploaded, 1 downloaded, 0 already up to date (3 conflicts resolved)"


def test_server_modified_at_is_what_the_server_lists(server, conn, local, state, capsys):
    # The comparison uses the modified_at from GET /blobs, as an instant in UTC.
    synced_once(server, conn, local, state, capsys, {"doc.txt": b"base"})
    write(local, {"doc.txt": b"local edit"})
    seed(conn, {"doc.txt": b"server edit"})
    set_server_mtime(server, "doc.txt", NEW)
    listed = datetime.fromisoformat(list_blobs(conn)[0]["modified_at"])
    assert listed == datetime.fromtimestamp(NEW, tz=timezone.utc)
    set_local_mtime(local, "doc.txt", NEW + 1)

    assert sync(local, server, state) == 0
    assert remote_files(conn) == {"doc.txt": b"local edit"}


def test_file_that_differs_with_no_common_state_goes_by_mtime(server, conn, local, state, capsys):
    # First sync, both sides have their own version: neither is known to be
    # unchanged, so the newer one wins, and on a tie the local one.
    seed(conn, {"l": b"server l", "s": b"server s", "t": b"server t"})
    write(local, {"l": b"local l", "s": b"local s", "t": b"local t"})
    for key, local_time, server_time in [("l", NEW, OLD), ("s", OLD, NEW), ("t", NEW, NEW)]:
        set_local_mtime(local, key, local_time)
        set_server_mtime(server, key, server_time)

    assert sync(local, server, state) == 0

    expected = {"l": b"local l", "s": b"server s", "t": b"local t"}
    assert files_only(local) == expected
    assert remote_files(conn) == expected
    out = capsys.readouterr().out
    assert report(out) == [
        "upload    differs   l  (no common version known; local is newer)",
        "download  differs   s  (no common version known; server is newer)",
        "upload    differs   t  (no common version known; same modification time, local wins)",
    ]
    assert summary(out) == "2 uploaded, 1 downloaded, 0 already up to date"


def test_resolved_conflict_becomes_the_common_state(server, conn, local, state, capsys):
    synced_once(server, conn, local, state, capsys, {"doc.txt": b"base"})
    write(local, {"doc.txt": b"local edit"})
    seed(conn, {"doc.txt": b"server edit"})
    set_local_mtime(local, "doc.txt", OLD)
    set_server_mtime(server, "doc.txt", NEW)
    assert sync(local, server, state) == 0
    capsys.readouterr()

    # The server's version won; a later local edit is a plain local change,
    # even though the server's copy has the newer time.
    write(local, {"doc.txt": b"edited again"})
    set_local_mtime(local, "doc.txt", OLD)
    set_server_mtime(server, "doc.txt", NEW)
    assert sync(local, server, state) == 0

    assert remote_files(conn) == {"doc.txt": b"edited again"}
    assert report(capsys.readouterr().out) == ["upload    changed   doc.txt"]


# --- nothing is deleted ---------------------------------------------------------------


def test_file_deleted_locally_is_restored_not_deleted_on_the_server(server, conn, local, state, requests, capsys):
    synced_once(server, conn, local, state, capsys, {"keep": b"k", "gone/locally": b"g"})
    (local / "gone" / "locally").unlink()
    (local / "gone").rmdir()

    assert sync(local, server, state) == 0

    assert not [r for r in requests if r[0] == "DELETE"]
    assert remote_files(conn) == {"keep": b"k", "gone/locally": b"g"}
    assert files_only(local) == {"keep": b"k", "gone/locally": b"g"}
    assert report(capsys.readouterr().out) == ["download  new       gone/locally"]


def test_file_deleted_on_the_server_is_uploaded_again_not_deleted_locally(server, conn, local, state, capsys):
    synced_once(server, conn, local, state, capsys, {"keep": b"k", "gone/remotely": b"g"})
    assert delete(conn, "gone/remotely")[0].status == 204

    assert sync(local, server, state) == 0

    assert files_only(local) == {"keep": b"k", "gone/remotely": b"g"}
    assert remote_files(conn) == {"keep": b"k", "gone/remotely": b"g"}
    assert report(capsys.readouterr().out) == ["upload    new       gone/remotely"]


# --- the state kept between runs ------------------------------------------------------------


def test_state_is_kept_outside_the_synced_directory(server, conn, local, state, capsys):
    seed(conn, {"remote": b"r"})
    write(local, {"local": b"l"})

    assert sync(local, server, state) == 0

    assert tree(local) == {"local": b"l", "remote": b"r"}
    assert sorted(b["key"] for b in list_blobs(conn)) == ["local", "remote"]
    [state_file] = state.iterdir()
    recorded = json.loads(state_file.read_bytes())
    assert recorded["files"] == {"local": sha(b"l"), "remote": sha(b"r")}
    assert recorded["dir"] == os.path.realpath(local)
    capsys.readouterr()

    # Nothing left over for status to report either.
    assert main(["status", str(local), "--server", url_of(server)], environ={}) == 0
    assert capsys.readouterr().out == "nothing to upload or download, 2 up to date\n"


def test_state_is_per_directory(server, conn, local, state, tmp_path_factory, capsys):
    # Another directory synced with the same server has no common state of
    # its own yet: its different version is resolved by mtime, not taken as
    # an unchanged copy.
    synced_once(server, conn, local, state, capsys, {"doc.txt": b"base"})
    other = tmp_path_factory.mktemp("other")
    write(other, {"doc.txt": b"other version"})
    set_local_mtime(other, "doc.txt", OLD)

    assert sync(other, server, state) == 0

    assert files_only(other) == {"doc.txt": b"base"}
    assert report(capsys.readouterr().out) == [
        "download  differs   doc.txt  (no common version known; server is newer)"
    ]
    assert len(list(state.iterdir())) == 2


def test_dir_id_overrides_the_directory_path(server, conn, local, state, tmp_path_factory, capsys):
    # run-client passes the host path, as the container always sees /work.
    synced_once(server, conn, local, state, capsys, {"doc.txt": b"base"})
    [state_file] = state.iterdir()
    copy = tmp_path_factory.mktemp("copy")
    env = {"SYNCBOX_DIR_ID": os.path.realpath(local)}
    write(copy, {"doc.txt": b"changed in the copy"})
    set_local_mtime(copy, "doc.txt", OLD)

    assert sync(copy, server, state, env=env) == 0

    # The copy shares the original's state, so this is a plain local change.
    assert remote_files(conn) == {"doc.txt": b"changed in the copy"}
    assert report(capsys.readouterr().out) == ["upload    changed   doc.txt"]
    assert list(state.iterdir()) == [state_file]


def test_dir_reached_through_a_symlink_shares_the_state(server, conn, local, state, tmp_path_factory, capsys):
    synced_once(server, conn, local, state, capsys, {"doc.txt": b"base"})
    link = tmp_path_factory.mktemp("links") / "link"
    link.symlink_to(local, target_is_directory=True)
    write(local, {"doc.txt": b"local change"})
    set_local_mtime(local, "doc.txt", OLD)

    assert sync(link, server, state) == 0

    assert report(capsys.readouterr().out) == ["upload    changed   doc.txt"]
    assert len(list(state.iterdir())) == 1


def test_malformed_state_is_ignored_with_a_warning(server, conn, local, state, capsys):
    synced_once(server, conn, local, state, capsys, {"doc.txt": b"base"})
    [state_file] = state.iterdir()
    state_file.write_text("{not json")
    write(local, {"doc.txt": b"local change"})
    set_local_mtime(local, "doc.txt", OLD)

    assert sync(local, server, state) == 0

    # Without the common state the server's newer copy wins.
    captured = capsys.readouterr()
    assert "warning: ignoring malformed sync state" in captured.err
    assert report(captured.out) == ["download  differs   doc.txt  (no common version known; server is newer)"]
    # And the state is written afresh.
    assert json.loads(state_file.read_bytes())["files"] == {"doc.txt": sha(b"base")}


def test_unsaved_state_is_a_warning(server, conn, local, tmp_path, capsys):
    blocker = tmp_path / "not-a-directory"
    blocker.write_bytes(b"")
    write(local, {"a": b"a"})

    assert sync(local, server, blocker / "state") == 0

    captured = capsys.readouterr()
    assert "warning: cannot save sync state" in captured.err
    assert remote_files(conn) == {"a": b"a"}


def test_state_records_files_synced_before_a_failure(server, conn, local, state, capsys):
    # "a" can't be uploaded: the server has a blob "a/b", so "a" is a directory there.
    seed(conn, {"a/b": b"server"})
    write(local, {"0-first": b"0", "a": b"local file"})

    assert sync(local, server, state) == 1

    assert "cannot upload 'a'" in capsys.readouterr().err
    [state_file] = state.iterdir()
    assert json.loads(state_file.read_bytes())["files"] == {"0-first": sha(b"0")}


def test_state_drops_files_gone_from_both_sides(server, conn, local, state, capsys):
    synced_once(server, conn, local, state, capsys, {"keep": b"k", "gone": b"g"})
    (local / "gone").unlink()
    assert delete(conn, "gone")[0].status == 204

    assert sync(local, server, state) == 0

    [state_file] = state.iterdir()
    assert json.loads(state_file.read_bytes())["files"] == {"keep": sha(b"k")}


def test_state_dir_defaults():
    assert state_dir({"SYNCBOX_STATE_DIR": "/s", "XDG_STATE_HOME": "/x", "HOME": "/h"}) == Path("/s")
    assert state_dir({"XDG_STATE_HOME": "/x", "HOME": "/h"}) == Path("/x/syncbox")
    assert state_dir({"XDG_STATE_HOME": "relative", "HOME": "/h"}) == Path("/h/.local/state/syncbox")
    assert state_dir({"HOME": "/h"}) == Path("/h/.local/state/syncbox")


def test_state_file_is_per_server(tmp_path):
    def path(url: str) -> Path:
        return SyncState(tmp_path, "/dir", parse_server_url(url)).path

    assert path("http://127.0.0.1:8080") == path("HTTP://127.0.0.1:8080/")
    assert path("http://127.0.0.1") == path("http://127.0.0.1:80")
    assert len({path("http://127.0.0.1:8080"), path("http://127.0.0.1:8081"), path("http://127.0.0.1:8080/x")}) == 3


# --- races and odd cases -------------------------------------------------------------------


def test_local_file_changed_during_sync_is_not_overwritten(server, conn, local, state, monkeypatch, capsys):
    synced_once(server, conn, local, state, capsys, {"doc.txt": b"base", "other": b"o1"})
    seed(conn, {"doc.txt": b"server edit", "other": b"o2"})
    real_pull_blob = sync_module.pull_blob

    def edit_then_pull(root_fd, blob, client, replacing):
        if blob.key == "doc.txt":
            write(local, {"doc.txt": b"edited after the scan"})
        return real_pull_blob(root_fd, blob, client, replacing)

    monkeypatch.setattr(sync_module, "pull_blob", edit_then_pull)

    assert sync(local, server, state) == 0

    assert files_only(local) == {"doc.txt": b"edited after the scan", "other": b"o2"}
    captured = capsys.readouterr()
    assert "skipping 'doc.txt': changed locally during the sync" in captured.err
    assert report(captured.out) == ["download  changed   other"]

    # The next sync sees a conflict, as the edit was made after the last common state.
    set_local_mtime(local, "doc.txt", NEW)
    set_server_mtime(server, "doc.txt", OLD)
    monkeypatch.setattr(sync_module, "pull_blob", real_pull_blob)
    assert sync(local, server, state) == 0
    assert remote_files(conn)["doc.txt"] == b"edited after the scan"


def test_symlink_is_neither_uploaded_nor_overwritten(server, conn, local, state, tmp_path_factory, capsys):
    outside = tmp_path_factory.mktemp("outside")
    write(outside, {"target": b"outside"})
    (local / "link").symlink_to(outside / "target")
    seed(conn, {"link": b"from the server"})

    assert sync(local, server, state) == 0

    assert (local / "link").is_symlink()
    assert (outside / "target").read_bytes() == b"outside"
    assert remote_files(conn) == {"link": b"from the server"}
    captured = capsys.readouterr()
    assert "skipping 'link': symbolic link" in captured.err


def test_missing_server_modified_at_fails_a_conflict(server, conn, local, state, monkeypatch, capsys):
    seed(conn, {"doc.txt": b"server"})
    write(local, {"doc.txt": b"local"})
    real_parse = api._parse_blob_list
    monkeypatch.setattr(
        api, "_parse_blob_list",
        lambda body: [api.RemoteBlob(b.key, b.size, b.sha256) for b in real_parse(body)],
    )

    assert sync(local, server, state) == 1

    assert "cannot sync 'doc.txt': the server did not report when it was modified" in capsys.readouterr().err
    assert remote_files(conn) == {"doc.txt": b"server"}
    assert files_only(local) == {"doc.txt": b"local"}


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("2026-10-04T10:00:00.123456Z", datetime(2026, 10, 4, 10, 0, 0, 123456, tzinfo=timezone.utc)),
        ("2026-10-04T13:00:00+03:00", datetime(2026, 10, 4, 10, 0, 0, tzinfo=timezone.utc)),
        ("2026-10-04T10:00:00", datetime(2026, 10, 4, 10, 0, 0, tzinfo=timezone.utc)),
        ("yesterday", None),
        (12345, None),
        (None, None),
    ],
)
def test_modified_at_parsing(raw, expected):
    body = json.dumps([{"key": "k", "size": 0, "sha256": sha(b""), "modified_at": raw}]).encode()
    [blob] = api._parse_blob_list(body)
    assert blob.modified_at == expected


def test_server_url_from_environment(server, conn, local, state, capsys):
    write(local, {"a": b"a"})
    env = {"SYNCBOX_STATE_DIR": str(state), "SYNCBOX_SERVER": url_of(server)}

    assert main(["sync", str(local)], environ=env) == 0

    assert remote_files(conn) == {"a": b"a"}


def test_server_url_is_required(local, state, capsys):
    assert main(["sync", str(local)], environ={"SYNCBOX_STATE_DIR": str(state)}) == 2
    assert "server URL is required" in capsys.readouterr().err
    assert list(state.iterdir()) == []


def test_large_files_both_ways(server, conn, local, state):
    up, down = os.urandom(3 * 1024 * 1024 + 1), os.urandom(2 * 1024 * 1024 + 3)
    write(local, {"up.bin": up})
    seed(conn, {"down.bin": down})

    assert sync(local, server, state) == 0

    assert sha((local / "down.bin").read_bytes()) == sha(down)
    resp, body = get(conn, "up.bin")
    assert resp.status == 200 and sha(body) == sha(up)
