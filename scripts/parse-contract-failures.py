#!/usr/bin/env python3
"""Парсит stdout `schemathesis run` (4.x) и печатает JSON-массив несоответствий.

Вызывается из scripts/run-gates.sh, когда контракт-гейт упал. Каждое
несоответствие: метод, путь операции, полученный код, задокументированные
коды, и точная строка воспроизведения (curl ...), как её печатает
schemathesis. Санитайзинг (замена конкретного host:port и путей) — не
здесь, а в scripts/build-fix-prompt.py, когда это идёт в промпт агенту.
"""
import json
import re
import sys

# schemathesis печатает с ANSI-кодами и правым паддингом пробелами —
# убираем и то, и другое, чтобы регэкспы ниже были устойчивы.
text = re.sub(r"\x1b\[[0-9;]*m", "", sys.stdin.read())
text = "\n".join(line.rstrip() for line in text.splitlines())

# Всё после заголовка FAILURES и до SUMMARY / WARNINGS. Заголовков FAILURES
# может быть несколько (по одному на прогон при 3x) — берём все.
bodies = re.findall(r"=+ FAILURES =+\s*\n(.*?)(?:\n=+ (?:SUMMARY|WARNINGS) =+|\Z)", text, re.S)
# Ведущий \n: первый заголовок секции идёт в самом начале body без него, а
# сплит-регэксп ниже требует \n перед подчёркиваниями.
body = "\n" + "\n".join(bodies)

# Секции разделены строкой "____ METHOD /path ____".
chunks = re.split(r"\n_{5,} (.+?) _{5,}\s*\n", body)
failures = []
# chunks: [pre, "METHOD /path", section, "METHOD /path", section, ...]
for i in range(1, len(chunks), 2):
    header = chunks[i].strip()
    section = chunks[i + 1] if i + 1 < len(chunks) else ""
    parts = header.split(None, 1)
    method = parts[0] if parts else ""
    path = parts[1] if len(parts) > 1 else ""

    received = re.search(r"Received:\s*(\d+)", section)
    documented = re.search(r"Documented:\s*(.+)", section)

    reproduce = ""
    rm = re.search(r"Reproduce with:\s*\n\s*\n?\s*(curl [^\n]+)", section)
    if rm:
        reproduce = rm.group(1).strip()

    server_error = "- Server error" in section or re.search(r"\[5\d\d\]", section) is not None

    failures.append(
        {
            "method": method,
            "path": path,
            "received": received.group(1) if received else "",
            "documented": documented.group(1).strip() if documented else "",
            "server_error": server_error,
            "reproduce": reproduce,
        }
    )

# Дедупликация по (method, path, received).
seen = set()
uniq = []
for f in failures:
    key = (f["method"], f["path"], f["received"])
    if key in seen:
        continue
    seen.add(key)
    uniq.append(f)

print(json.dumps(uniq, ensure_ascii=False))
