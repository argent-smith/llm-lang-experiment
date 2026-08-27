#!/usr/bin/env python3
"""Разбирает текстовый вывод `sbt scalafixAll --check` в JSON.

У Scalafix, в отличие от ruff/rubocop/eslint/golangci-lint, нет
встроенного структурированного (JSON) вывода — только текст,
эмпирически подтверждено (docs/incidents не заводился, разбор — в
scripts/run-code-quality.sh). Два разных формата в одном выводе:

- Линтер-правила (DisableSyntax) — построчные диагностики:
  `path:line:col: error: [Rule.name] message`.
- Rewrite-правила (OrganizeImports, RemoveUnused и т.д.) — unified
  diff на файл, без указания конкретного правила внутри diff-блока
  (несколько rewrite-правил мержатся в один diff на файл в режиме
  --check) — считаются одной находкой на файл, атрибуция "rewrite
  rules" общая, не по конкретному правилу.

Использование: parse-scalafix-output.py < sbt-output.txt > quality.json
"""
import json
import re
import sys

DIAG_RE = re.compile(r'^\[error\] (/\S+\.scala):(\d+):(\d+): error: \[([^\]]+)\] (.*)$')
DIFF_START_RE = re.compile(r'^\[error\] --- (/\S+\.scala)$')


def strip_prefix(line: str) -> str:
    return line[len("[error] "):] if line.startswith("[error] ") else line


def parse(lines):
    diagnostics = []
    rewrite_diffs = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        m = DIAG_RE.match(line)
        if m:
            path, ln, col, rule, message = m.groups()
            diagnostics.append({
                "file": path,
                "line": int(ln),
                "column": int(col),
                "rule": rule,
                "message": message,
            })
            i += 1
            continue
        m = DIFF_START_RE.match(line)
        if m:
            path = m.group(1)
            hunk = [strip_prefix(line)]
            i += 1
            while i < n and lines[i].startswith("[error] ") and not DIAG_RE.match(lines[i]) and not DIFF_START_RE.match(lines[i]):
                hunk.append(strip_prefix(lines[i]))
                i += 1
            rewrite_diffs.append({"file": path, "unified_diff": "\n".join(hunk)})
            continue
        i += 1
    return diagnostics, rewrite_diffs


def main():
    raw = sys.stdin.read()
    lines = raw.splitlines()
    diagnostics, rewrite_diffs = parse(lines)
    json.dump(
        {
            "scalafix": {
                "diagnostics": diagnostics,
                "rewrite_diffs": rewrite_diffs,
                "raw_stdout": raw,
            }
        },
        sys.stdout,
        ensure_ascii=False,
        indent=2,
    )


if __name__ == "__main__":
    main()
