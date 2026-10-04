from __future__ import annotations

import json


def test_healthz_returns_200(conn):
    conn.request("GET", "/healthz")
    resp = conn.getresponse()
    assert resp.status == 200
    assert resp.getheader("Content-Type") == "application/json"
    assert json.loads(resp.read()) == {"status": "ok"}


def test_healthz_ignores_query_string(conn):
    conn.request("GET", "/healthz?probe=1")
    resp = conn.getresponse()
    assert resp.status == 200
    resp.read()


def test_healthz_head_has_no_body(conn):
    conn.request("HEAD", "/healthz")
    resp = conn.getresponse()
    assert resp.status == 200
    assert int(resp.getheader("Content-Length")) > 0
    assert resp.read() == b""


def test_unknown_path_returns_404(conn):
    conn.request("GET", "/nope")
    resp = conn.getresponse()
    assert resp.status == 404
    assert json.loads(resp.read()) == {"error": "not found"}


def test_wrong_method_returns_405_with_allow(conn):
    conn.request("POST", "/healthz", body=b"")
    resp = conn.getresponse()
    assert resp.status == 405
    assert resp.getheader("Allow") == "GET, HEAD"
    resp.read()


def test_keep_alive_survives_unread_request_body(conn):
    # The body of a rejected request must be drained, otherwise its bytes
    # would be parsed as the next request on the same connection.
    conn.request("PUT", "/healthz", body=b"GET /nope HTTP/1.1\r\n\r\n" * 100)
    resp = conn.getresponse()
    assert resp.status == 405
    resp.read()
    assert not resp.will_close

    conn.request("GET", "/healthz")
    resp = conn.getresponse()
    assert resp.status == 200
    resp.read()


def test_many_sequential_requests_on_one_connection(conn):
    for _ in range(20):
        conn.request("GET", "/healthz")
        resp = conn.getresponse()
        assert resp.status == 200
        resp.read()
