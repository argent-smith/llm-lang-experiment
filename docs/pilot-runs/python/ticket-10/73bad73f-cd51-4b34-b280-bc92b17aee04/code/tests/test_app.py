import hashlib
import os
import re
import threading
from pathlib import Path

import pytest

from server.app import InvalidKeyError, create_app, resolve_blob_path


def test_healthz_returns_200(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.get("/healthz")

    assert response.status_code == 200


def test_put_blob_returns_201_with_key_sha256_size(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    content = b"hello world"

    response = client.put("/blobs/greeting.txt", data=content)

    assert response.status_code == 201
    assert response.get_json() == {
        "key": "greeting.txt",
        "sha256": hashlib.sha256(content).hexdigest(),
        "size": len(content),
    }


def test_put_blob_writes_file_to_data_dir(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    client.put("/blobs/greeting.txt", data=b"hello world")

    assert (tmp_path / "greeting.txt").read_bytes() == b"hello world"


def test_put_blob_creates_nested_directories(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.put("/blobs/docs/readme.txt", data=b"nested content")

    assert response.status_code == 201
    assert response.get_json()["key"] == "docs/readme.txt"
    assert (tmp_path / "docs" / "readme.txt").read_bytes() == b"nested content"


def test_put_blob_overwrites_existing_key(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    client.put("/blobs/greeting.txt", data=b"first")
    response = client.put("/blobs/greeting.txt", data=b"second")

    assert response.status_code == 201
    assert (tmp_path / "greeting.txt").read_bytes() == b"second"


def test_get_blob_returns_content_after_put(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    content = b"hello world"
    client.put("/blobs/greeting.txt", data=content)

    response = client.get("/blobs/greeting.txt")

    assert response.status_code == 200
    assert response.data == content


def test_get_blob_nested_key_after_put(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    client.put("/blobs/docs/readme.txt", data=b"nested content")

    response = client.get("/blobs/docs/readme.txt")

    assert response.status_code == 200
    assert response.data == b"nested content"


def test_get_blob_returns_404_when_missing(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.get("/blobs/missing.txt")

    assert response.status_code == 404


def test_list_blobs_returns_empty_array_for_empty_store(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.get("/blobs")

    assert response.status_code == 200
    assert response.get_json() == []


def test_list_blobs_returns_metadata_for_stored_blobs(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    content = b"hello world"
    client.put("/blobs/greeting.txt", data=content)

    response = client.get("/blobs")

    assert response.status_code == 200
    body = response.get_json()
    assert len(body) == 1
    entry = body[0]
    assert entry["key"] == "greeting.txt"
    assert entry["size"] == len(content)
    assert entry["sha256"] == hashlib.sha256(content).hexdigest()
    assert re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}", entry["modified_at"])


def test_list_blobs_includes_nested_keys_as_posix_paths(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    client.put("/blobs/docs/readme.txt", data=b"nested content")

    response = client.get("/blobs")

    body = response.get_json()
    assert [entry["key"] for entry in body] == ["docs/readme.txt"]


def test_list_blobs_lists_multiple_blobs(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    client.put("/blobs/a.txt", data=b"a")
    client.put("/blobs/docs/b.txt", data=b"bb")

    response = client.get("/blobs")

    body = response.get_json()
    keys = sorted(entry["key"] for entry in body)
    assert keys == ["a.txt", "docs/b.txt"]


def test_delete_blob_returns_204_and_removes_file(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    client.put("/blobs/greeting.txt", data=b"hello world")

    response = client.delete("/blobs/greeting.txt")

    assert response.status_code == 204
    assert response.data == b""
    assert not (tmp_path / "greeting.txt").exists()


def test_delete_blob_returns_404_when_missing(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.delete("/blobs/missing.txt")

    assert response.status_code == 404


def test_delete_blob_nested_key(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    client.put("/blobs/docs/readme.txt", data=b"nested content")

    response = client.delete("/blobs/docs/readme.txt")

    assert response.status_code == 204
    assert not (tmp_path / "docs" / "readme.txt").exists()


def test_deleted_blob_is_absent_from_get_and_list(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    client.put("/blobs/greeting.txt", data=b"hello world")

    client.delete("/blobs/greeting.txt")

    assert client.get("/blobs/greeting.txt").status_code == 404
    assert client.get("/blobs").get_json() == []


def test_delete_blob_does_not_affect_other_blobs(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    client.put("/blobs/a.txt", data=b"a")
    client.put("/blobs/docs/b.txt", data=b"bb")

    client.delete("/blobs/a.txt")

    response = client.get("/blobs")
    keys = sorted(entry["key"] for entry in response.get_json())
    assert keys == ["docs/b.txt"]


TRAVERSAL_KEYS = [
    "../secret.txt",
    "../../etc/passwd",
    "docs/../../secret.txt",
    "docs/../../../secret.txt",
    "a/b/../../../secret.txt",
    "..",
    "%2e%2e/secret.txt",
]


@pytest.mark.parametrize("key", TRAVERSAL_KEYS)
def test_put_blob_rejects_dotdot_traversal(tmp_path, key):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.put(f"/blobs/{key}", data=b"pwned")

    assert response.status_code == 400
    assert not (tmp_path.parent / "secret.txt").exists()


@pytest.mark.parametrize("key", TRAVERSAL_KEYS)
def test_get_blob_rejects_dotdot_traversal(tmp_path, key):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.get(f"/blobs/{key}")

    assert response.status_code == 400


@pytest.mark.parametrize("key", TRAVERSAL_KEYS)
def test_delete_blob_rejects_dotdot_traversal(tmp_path, key):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.delete(f"/blobs/{key}")

    assert response.status_code == 400


def test_resolve_blob_path_rejects_absolute_key(tmp_path):
    with pytest.raises(InvalidKeyError):
        resolve_blob_path(str(tmp_path), "/etc/passwd")


def test_resolve_blob_path_accepts_relative_key(tmp_path):
    path = resolve_blob_path(str(tmp_path), "docs/readme.txt")

    assert path == (tmp_path / "docs" / "readme.txt").resolve()


def test_get_blob_double_slash_key_never_leaks_outside_root(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    # A leading "/" right after /blobs/ can only reach the app via Werkzeug's
    # slash-merging redirect, which rewrites it to a key relative to root
    # before our view ever sees it -- confirm that stays true, i.e. it must
    # never resolve to a real /etc/passwd on the host.
    response = client.get("/blobs//etc/passwd", follow_redirects=True)

    assert response.status_code == 404


def test_put_blob_rejects_key_with_null_byte(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.put("/blobs/foo%00bar", data=b"x")

    assert response.status_code == 400


def test_put_blob_rejects_key_with_replacement_character(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.put("/blobs/��", data=b"x")

    assert response.status_code == 400


def test_traversal_key_does_not_escape_via_symlink(tmp_path):
    outside = tmp_path.parent / "outside-dir"
    outside.mkdir(exist_ok=True)
    (tmp_path / "escape").symlink_to(outside, target_is_directory=True)
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.put("/blobs/escape/secret.txt", data=b"pwned")

    assert response.status_code == 400
    assert not (outside / "secret.txt").exists()
    assert not (outside / "secret.txt").exists()


def test_legit_key_containing_dotdot_substring_is_allowed(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.put("/blobs/my..file.txt", data=b"content")

    assert response.status_code == 201
    assert (tmp_path / "my..file.txt").read_bytes() == b"content"


# --- Atomic write / concurrent PUT (ticket 6) -------------------------------


def test_put_blob_leaves_no_temp_files_after_success(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    client.put("/blobs/docs/readme.txt", data=b"content")

    leftover = [p for p in tmp_path.rglob("*") if p.is_file() and p.name != "readme.txt"]
    assert leftover == []


def test_put_blob_removes_temp_file_on_write_failure(tmp_path, monkeypatch):
    app = create_app(str(tmp_path))
    client = app.test_client()

    def failing_replace(src, dst):
        raise OSError("simulated failure")

    monkeypatch.setattr(os, "replace", failing_replace)

    response = client.put("/blobs/key.txt", data=b"content")

    assert response.status_code == 400
    assert not (tmp_path / "key.txt").exists()
    leftover = [p for p in tmp_path.rglob("*") if p.is_file()]
    assert leftover == []


# --- OS-level write failures surface as 400, never 500 (ticket 12) ---------
#
# resolve_blob_path's structural checks (traversal, null byte, invalid
# UTF-8, escaping the root) can't catch every key a real filesystem will
# refuse: some byte sequences are valid UTF-8 but still aren't
# representable as a path entry on a given filesystem/locale, and the
# failure only surfaces once the OS actually tries to create/rename the
# file -- sometimes intermittently. write_blob_atomic must turn any such
# failure, regardless of which step (mkdir/open/write/fsync/rename) or
# which bytes triggered it, into a 400, never an unhandled 500.


@pytest.mark.parametrize(
    "failing_target,exc",
    [
        ("mkdir", OSError(5, "Input/output error")),
        ("open", OSError(2, "No such file or directory")),
        ("fsync", OSError(84, "Invalid or incomplete multibyte or wide character")),
        ("replace", OSError(5, "Input/output error")),
        ("replace", UnicodeEncodeError("utf-8", "\udcff", 0, 1, "surrogates not allowed")),
    ],
)
def test_put_blob_returns_400_when_disk_write_fails_at_any_step(
    tmp_path, monkeypatch, failing_target, exc
):
    app = create_app(str(tmp_path))
    client = app.test_client()

    if failing_target == "mkdir":
        real_mkdir = Path.mkdir

        def failing_mkdir(self, *args, **kwargs):
            if self.name == ".syncbox-tmp":
                raise exc
            return real_mkdir(self, *args, **kwargs)

        monkeypatch.setattr(Path, "mkdir", failing_mkdir)
    elif failing_target == "open":
        monkeypatch.setattr(
            "server.app.open",
            lambda *a, **kw: (_ for _ in ()).throw(exc),
            raising=False,
        )
    elif failing_target == "fsync":
        monkeypatch.setattr(os, "fsync", lambda fd: (_ for _ in ()).throw(exc))
    elif failing_target == "replace":
        monkeypatch.setattr(os, "replace", lambda src, dst: (_ for _ in ()).throw(exc))

    response = client.put("/blobs/some-key.txt", data=b"content")

    assert response.status_code == 400
    assert response.get_json()["error"]
    assert not (tmp_path / "some-key.txt").exists()
    leftover = [p for p in tmp_path.rglob("*") if p.is_file()]
    assert leftover == []


def test_put_blob_write_failure_does_not_affect_other_keys(tmp_path, monkeypatch):
    app = create_app(str(tmp_path))
    client = app.test_client()
    real_replace = os.replace
    calls = {"n": 0}

    def flaky_replace(src, dst):
        calls["n"] += 1
        if calls["n"] == 1:
            raise OSError(5, "Input/output error")
        return real_replace(src, dst)

    monkeypatch.setattr(os, "replace", flaky_replace)

    failed = client.put("/blobs/flaky.txt", data=b"first attempt")
    assert failed.status_code == 400

    ok = client.put("/blobs/other.txt", data=b"unrelated")
    assert ok.status_code == 201
    assert (tmp_path / "other.txt").read_bytes() == b"unrelated"


@pytest.mark.parametrize(
    "key",
    [
        "e1%C2%8E%C2%B6%F3%9C%B8%A0",
        "%C2%8E",
        "%C2%B6",
        "docs/%F3%9C%B8%A0/readme.txt",
    ],
)
def test_put_blob_unusual_but_valid_utf8_key_never_returns_500(tmp_path, key):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.put(f"/blobs/{key}", data=b"x")

    assert response.status_code in (201, 400)
    if response.status_code == 201:
        get_response = client.get(f"/blobs/{key}")
        assert get_response.status_code == 200
        assert get_response.data == b"x"


def test_get_during_in_progress_put_never_sees_partial_content(tmp_path, monkeypatch):
    app = create_app(str(tmp_path))
    client = app.test_client()
    old_content = b"OLD" * 10000
    client.put("/blobs/key.txt", data=old_content)

    reached_replace = threading.Event()
    release_replace = threading.Event()
    real_replace = os.replace

    def patched_replace(src, dst):
        reached_replace.set()
        assert release_replace.wait(timeout=5)
        real_replace(src, dst)

    monkeypatch.setattr(os, "replace", patched_replace)

    new_content = b"NEW" * 10000
    results = {}

    def do_put():
        results["response"] = client.put("/blobs/key.txt", data=new_content)

    put_thread = threading.Thread(target=do_put)
    put_thread.start()
    assert reached_replace.wait(timeout=5), "PUT never reached the rename step"

    # Rename hasn't happened yet -- a reader must see the fully old file,
    # never a truncated or partially-written one.
    mid_write = client.get("/blobs/key.txt")
    assert mid_write.status_code == 200
    assert mid_write.data == old_content

    release_replace.set()
    put_thread.join(timeout=5)

    assert results["response"].status_code == 201
    final = client.get("/blobs/key.txt")
    assert final.data == new_content


def test_concurrent_put_different_keys_do_not_interfere(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    barrier = threading.Barrier(2)
    results = {}
    content_a = b"A" * 50000
    content_b = b"B" * 50000

    def put_a():
        barrier.wait(timeout=5)
        results["a"] = client.put("/blobs/a.txt", data=content_a)

    def put_b():
        barrier.wait(timeout=5)
        results["b"] = client.put("/blobs/docs/b.txt", data=content_b)

    t1 = threading.Thread(target=put_a)
    t2 = threading.Thread(target=put_b)
    t1.start()
    t2.start()
    t1.join(timeout=5)
    t2.join(timeout=5)

    assert results["a"].status_code == 201
    assert results["b"].status_code == 201
    assert (tmp_path / "a.txt").read_bytes() == content_a
    assert (tmp_path / "docs" / "b.txt").read_bytes() == content_b


def test_list_blobs_excludes_temp_directory_contents(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()
    client.put("/blobs/keep.txt", data=b"kept")

    tmp_dir = tmp_path / ".syncbox-tmp"
    tmp_dir.mkdir(exist_ok=True)
    (tmp_dir / "leftover.tmp").write_bytes(b"leftover")

    response = client.get("/blobs")

    keys = [entry["key"] for entry in response.get_json()]
    assert keys == ["keep.txt"]


@pytest.mark.parametrize(
    "key", [".syncbox-tmp/x", "docs/.syncbox-tmp/y", ".syncbox-tmp"]
)
def test_reserved_tmp_segment_is_rejected_as_invalid_key(tmp_path, key):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.put(f"/blobs/{key}", data=b"x")

    assert response.status_code == 400


# --- Garbage/boundary key values never produce out-of-schema responses -----
#
# syncbox-openapi.yaml only allows 201/400 for PUT and 200/204/404/400 for
# GET/DELETE. Two classes of key can slip past those: (1) a key that
# Werkzeug's own URL routing can't match at all -- e.g. one that decodes to
# a literal "\n", which breaks the <path:key> route regex -- so it never
# reaches our view or resolve_blob_path, and surfaces as Werkzeug's generic
# non-JSON 404 (an outright schema violation for PUT, and an unexplained
# 404 for GET/DELETE); (2) a key that routes and passes structural
# validation but trips an OS-level error when GET/DELETE actually touch the
# filesystem (the read-side counterpart of the ticket 12 write-side fix).
# Both classes must become a plain 400, never a 500 or a bare 404.

UNROUTABLE_KEYS = [
    "lf%0Aonly.txt",
    "crlf%0D%0Ainjected.txt",
    "nested/dir%0Away/file.txt",
    "trailing%0A",
    # Reported schema violation: a key mixing ordinary bytes with astral/
    # C1/Latin-1 percent-encoded sequences and an embedded LF -- same root
    # cause as the other entries (the decoded LF breaks route matching),
    # just with noisier surrounding bytes.
    "%E4%AA%9FX%C2%84%C2%A4%C3%8F%0A%F1%B3%A0%80",
    # Same class again, LF trailing instead of interior, mixing Cyrillic/
    # C1/Latin-1/astral bytes -- external schema check flagged GET 400 as
    # "outside the schema" because syncbox-openapi.yaml didn't document 400
    # for GET/DELETE, even though it's the same invalid-key case as PUT.
    "%D0%B6%C2%9F%C3%9E%F0%9F%8E%89%0A",
]


@pytest.mark.parametrize("key", UNROUTABLE_KEYS)
def test_put_blob_unroutable_key_returns_400_not_generic_404(tmp_path, key):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.put(f"/blobs/{key}", data=b"x")

    assert response.status_code == 400
    assert response.get_json() == {"error": "invalid key"}


@pytest.mark.parametrize("key", UNROUTABLE_KEYS)
def test_get_blob_unroutable_key_returns_400_not_generic_404(tmp_path, key):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.get(f"/blobs/{key}")

    assert response.status_code == 400
    assert response.get_json() == {"error": "invalid key"}


@pytest.mark.parametrize("key", UNROUTABLE_KEYS)
def test_delete_blob_unroutable_key_returns_400_not_generic_404(tmp_path, key):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.delete(f"/blobs/{key}")

    assert response.status_code == 400
    assert response.get_json() == {"error": "invalid key"}


def test_unrelated_unknown_route_still_returns_plain_404(tmp_path):
    app = create_app(str(tmp_path))
    client = app.test_client()

    response = client.get("/does-not-exist")

    assert response.status_code == 404


def test_get_blob_returns_400_when_existence_check_hits_os_error(tmp_path, monkeypatch):
    app = create_app(str(tmp_path))
    client = app.test_client()
    client.put("/blobs/key.txt", data=b"content")

    real_is_file = Path.is_file

    def failing_is_file(self):
        if self.name == "key.txt":
            raise OSError(84, "Invalid or incomplete multibyte or wide character")
        return real_is_file(self)

    monkeypatch.setattr(Path, "is_file", failing_is_file)

    response = client.get("/blobs/key.txt")

    assert response.status_code == 400
    assert response.get_json()["error"]


def test_get_blob_returns_400_when_send_file_hits_os_error(tmp_path, monkeypatch):
    app = create_app(str(tmp_path))
    client = app.test_client()
    client.put("/blobs/key.txt", data=b"content")

    def failing_send_file(*args, **kwargs):
        raise OSError(5, "Input/output error")

    monkeypatch.setattr("server.app.send_file", failing_send_file)

    response = client.get("/blobs/key.txt")

    assert response.status_code == 400
    assert response.get_json()["error"]


def test_delete_blob_returns_400_when_existence_check_hits_os_error(tmp_path, monkeypatch):
    app = create_app(str(tmp_path))
    client = app.test_client()
    client.put("/blobs/key.txt", data=b"content")

    real_is_file = Path.is_file

    def failing_is_file(self):
        if self.name == "key.txt":
            raise OSError(84, "Invalid or incomplete multibyte or wide character")
        return real_is_file(self)

    monkeypatch.setattr(Path, "is_file", failing_is_file)

    response = client.delete("/blobs/key.txt")

    assert response.status_code == 400
    assert response.get_json()["error"]
    assert (tmp_path / "key.txt").exists()


def test_delete_blob_returns_400_when_unlink_hits_os_error(tmp_path, monkeypatch):
    app = create_app(str(tmp_path))
    client = app.test_client()
    client.put("/blobs/key.txt", data=b"content")

    def failing_unlink(self, *args, **kwargs):
        raise OSError(5, "Input/output error")

    monkeypatch.setattr(Path, "unlink", failing_unlink)

    response = client.delete("/blobs/key.txt")

    assert response.status_code == 400
    assert response.get_json()["error"]
    assert (tmp_path / "key.txt").exists()


# --- Legit keys with unusual-but-valid substrings must not be blocked ------

UNUSUAL_VALID_KEYS = [
    "cafe-%C3%A9.txt",  # Latin-1 Supplement letter (U+00E9, e-acute)
    "pilcrow-%C2%B6.txt",  # high Latin-1 punctuation (U+00B6)
    "c1-control-%C2%8E.txt",  # C1 control char (U+008E)
    "emoji-%F0%9F%98%80.txt",  # astral plane (U+1F600)
    "pua-%F3%9C%B8%A0.txt",  # astral supplementary private-use plane
]


@pytest.mark.parametrize("key", UNUSUAL_VALID_KEYS)
def test_legit_key_with_unusual_valid_bytes_is_not_blocked(tmp_path, key):
    app = create_app(str(tmp_path))
    client = app.test_client()

    put_response = client.put(f"/blobs/{key}", data=b"payload")

    assert put_response.status_code == 201

    get_response = client.get(f"/blobs/{key}")
    assert get_response.status_code == 200
    assert get_response.data == b"payload"

    delete_response = client.delete(f"/blobs/{key}")
    assert delete_response.status_code == 204
