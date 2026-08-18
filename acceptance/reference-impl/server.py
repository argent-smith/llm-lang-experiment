#!/usr/bin/env python3
"""Служебная эталонная реализация Syncbox-сервера.

Не один из шести языков эксперимента — реализации самого эксперимента
живут в отдельных репозиториях, не здесь. Единственное назначение этого
файла — дать acceptance/smoke.sh что-то заведомо правильное для проверки
в CI, чтобы ловить регрессии в самом smoke-тесте, а не в языках.
"""
import argparse
import hashlib
import json
import os
import tempfile
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

DATA_DIR = None


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def safe_key(raw_after_blobs):
    if raw_after_blobs in ("", "/"):
        return None
    key = unquote(raw_after_blobs.lstrip("/"))
    parts = key.split("/")
    if not key or ".." in parts or key.startswith("/"):
        return None
    return key


def key_to_path(key):
    return os.path.normpath(os.path.join(DATA_DIR, key))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send_json(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_empty(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/healthz":
            self._send_empty(200)
            return
        if path == "/blobs":
            items = []
            for root, _dirs, files in os.walk(DATA_DIR):
                for name in files:
                    full = os.path.join(root, name)
                    key = os.path.relpath(full, DATA_DIR).replace(os.sep, "/")
                    st = os.stat(full)
                    items.append({
                        "key": key,
                        "size": st.st_size,
                        "sha256": sha256_of(full),
                        "modified_at": datetime.fromtimestamp(
                            st.st_mtime, tz=timezone.utc
                        ).isoformat().replace("+00:00", "Z"),
                    })
            self._send_json(200, items)
            return
        if path.startswith("/blobs"):
            key = safe_key(path[len("/blobs"):])
            if key is None:
                self._send_empty(400)
                return
            fpath = key_to_path(key)
            if not os.path.isfile(fpath):
                self._send_empty(404)
                return
            with open(fpath, "rb") as f:
                body = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self._send_empty(404)

    def do_PUT(self):
        path = urlsplit(self.path).path
        if not path.startswith("/blobs"):
            self._send_empty(404)
            return
        key = safe_key(path[len("/blobs"):])
        if key is None:
            self._send_empty(400)
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        fpath = key_to_path(key)
        parent = os.path.dirname(fpath)
        tmp_path = None
        try:
            os.makedirs(parent, exist_ok=True)
            fd, tmp_path = tempfile.mkstemp(dir=parent)
            with os.fdopen(fd, "wb") as f:
                f.write(body)
            os.replace(tmp_path, fpath)
        except (OSError, UnicodeError):
            # key декодировался в валидную Python-строку, но не
            # представим как имя файла на этой файловой системе —
            # для контракта это тот же случай, что и недопустимый key.
            if tmp_path and os.path.exists(tmp_path):
                os.unlink(tmp_path)
            self._send_empty(400)
            return
        self._send_json(201, {
            "key": key,
            "sha256": sha256_of(fpath),
            "size": len(body),
        })

    def do_DELETE(self):
        path = urlsplit(self.path).path
        if not path.startswith("/blobs"):
            self._send_empty(404)
            return
        key = safe_key(path[len("/blobs"):])
        if key is None:
            self._send_empty(400)
            return
        fpath = key_to_path(key)
        if not os.path.isfile(fpath):
            self._send_empty(404)
            return
        os.unlink(fpath)
        self._send_empty(204)

    # Любой метод вне контракта SYNCBOX-SPEC.md (TRACE, OPTIONS, QUERY и
    # т. п.): без этого http.server отвечает 501, а Schemathesis
    # (acceptance/contract-test.sh) считает любой 5xx server error и
    # падает — 405 корректнее и для реального REST-контракта. Обобщённый
    # fallback вместо do_TRACE/do_OPTIONS/... по одному, потому что
    # набор HTTP-методов не фиксирован (например, QUERY — черновик RFC).
    def __getattr__(self, name):
        if name.startswith("do_"):
            return lambda: self._send_empty(405)
        raise AttributeError(name)

    def log_message(self, fmt, *args):
        pass


def main():
    global DATA_DIR
    p = argparse.ArgumentParser()
    p.add_argument("--data-dir", required=True)
    p.add_argument("--port", type=int, default=8080)
    args = p.parse_args()
    DATA_DIR = os.path.abspath(args.data_dir)
    os.makedirs(DATA_DIR, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
