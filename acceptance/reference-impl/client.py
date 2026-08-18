#!/usr/bin/env python3
"""Служебный эталонный CLI-клиент Syncbox — см. пояснение в server.py."""
import argparse
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime
from urllib.parse import quote


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def local_files(root):
    result = {}
    for dirpath, _dirs, filenames in os.walk(root):
        for name in filenames:
            full = os.path.join(dirpath, name)
            key = os.path.relpath(full, root).replace(os.sep, "/")
            result[key] = full
    return result


def remote_list(server):
    with urllib.request.urlopen(f"{server}/blobs", timeout=10) as r:
        return {item["key"]: item for item in json.load(r)}


def put_file(server, key, path):
    with open(path, "rb") as f:
        data = f.read()
    url = f"{server}/blobs/{quote(key, safe='/')}"
    req = urllib.request.Request(url, data=data, method="PUT")
    with urllib.request.urlopen(req, timeout=10) as r:
        r.read()


def get_file(server, key, dest):
    url = f"{server}/blobs/{quote(key, safe='/')}"
    with urllib.request.urlopen(url, timeout=10) as r:
        data = r.read()
    parent = os.path.dirname(dest)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(dest, "wb") as f:
        f.write(data)


def cmd_push(args):
    local = local_files(args.dir)
    try:
        remote = remote_list(args.server)
    except urllib.error.URLError as e:
        print(f"push: сервер недоступен: {e}", file=sys.stderr)
        return 1
    failed = 0
    for key, path in local.items():
        r = remote.get(key)
        if r is None or r["sha256"] != sha256_of(path):
            try:
                put_file(args.server, key, path)
            except urllib.error.URLError as e:
                print(f"push: не удалось загрузить {key}: {e}", file=sys.stderr)
                failed += 1
    return 1 if failed else 0


def cmd_pull(args):
    try:
        remote = remote_list(args.server)
    except urllib.error.URLError as e:
        print(f"pull: сервер недоступен: {e}", file=sys.stderr)
        return 1
    local = local_files(args.dir)
    failed = 0
    for key, info in remote.items():
        dest = os.path.join(args.dir, key)
        if key not in local or sha256_of(local[key]) != info["sha256"]:
            try:
                get_file(args.server, key, dest)
            except urllib.error.URLError as e:
                print(f"pull: не удалось скачать {key}: {e}", file=sys.stderr)
                failed += 1
    return 1 if failed else 0


def cmd_status(args):
    local = local_files(args.dir)
    try:
        remote = remote_list(args.server)
    except urllib.error.URLError as e:
        print(f"status: сервер недоступен: {e}", file=sys.stderr)
        return 1
    for key, path in local.items():
        r = remote.get(key)
        if r is None:
            print(f"push {key}")
        elif r["sha256"] != sha256_of(path):
            print(f"push {key} (изменён)")
    for key in remote:
        if key not in local:
            print(f"pull {key}")
    return 0


def cmd_sync(args):
    local = local_files(args.dir)
    try:
        remote = remote_list(args.server)
    except urllib.error.URLError as e:
        print(f"sync: сервер недоступен: {e}", file=sys.stderr)
        return 1
    failed = 0
    for key, path in local.items():
        r = remote.get(key)
        if r is None or r["sha256"] != sha256_of(path):
            local_mtime = os.path.getmtime(path)
            if r is not None:
                remote_mtime = datetime.fromisoformat(
                    r["modified_at"].replace("Z", "+00:00")
                ).timestamp()
                if remote_mtime > local_mtime:
                    try:
                        get_file(args.server, key, path)
                    except urllib.error.URLError as e:
                        print(f"sync: не удалось скачать {key}: {e}", file=sys.stderr)
                        failed += 1
                    continue
            try:
                put_file(args.server, key, path)
            except urllib.error.URLError as e:
                print(f"sync: не удалось загрузить {key}: {e}", file=sys.stderr)
                failed += 1
    for key in remote:
        if key not in local:
            dest = os.path.join(args.dir, key)
            try:
                get_file(args.server, key, dest)
            except urllib.error.URLError as e:
                print(f"sync: не удалось скачать {key}: {e}", file=sys.stderr)
                failed += 1
    return 1 if failed else 0


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="command", required=True)
    for name, fn in (("push", cmd_push), ("pull", cmd_pull),
                      ("sync", cmd_sync), ("status", cmd_status)):
        sp = sub.add_parser(name)
        sp.add_argument("dir")
        sp.add_argument("--server", required=True)
        sp.set_defaults(func=fn)
    args = p.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
