#!/usr/bin/env python3
"""Разбирает текстовый вывод `dune build @check` (со включёнными через
dune-workspace-quality дополнительными -w флагами) в JSON.

У OCaml/dune, как и у Scalafix, нет встроенного структурированного (JSON)
вывода для warnings компилятора — только текст (подтверждено эмпирически:
`dune build @check --help` не даёт флага формата вывода). Типичный блок
одного предупреждения:

    File "lib/server.ml", line 42, characters 10-15:
    42 |   let open List in
              ^^^^^^^^^^^^^
    Warning 44 [open-shadow-identifier]: this open statement shadows ...

Использование: parse-ocaml-warnings.py < dune-output.txt > quality.json
"""
import json
import re
import sys

FILE_RE = re.compile(r'^File "(.+)", line (\d+), characters (\d+)-(\d+):$')
WARNING_RE = re.compile(r'^Warning (\d+) \[([A-Za-z0-9_-]+)\]: (.*)$')


def parse(lines):
    warnings = []
    i = 0
    n = len(lines)
    while i < n:
        m = FILE_RE.match(lines[i])
        if not m:
            i += 1
            continue
        path, line_no, col_start, col_end = m.groups()
        j = i + 1
        warn_match = None
        # Warning-строка идёт после блока с исходной строкой и "^^^"
        # подчёркиванием — фиксированное число строк не гарантировано
        # (зависит от длины подсвечиваемого фрагмента), поэтому ищем
        # вперёд до следующего File-блока или конца вывода.
        while j < n and not FILE_RE.match(lines[j]):
            warn_match = WARNING_RE.match(lines[j])
            if warn_match:
                break
            j += 1
        if warn_match:
            code, name, message = warn_match.groups()
            # Сообщение может продолжаться на следующих строках до
            # пустой строки или начала следующего File-блока.
            k = j + 1
            extra = []
            while k < n and lines[k].strip() and not FILE_RE.match(lines[k]):
                extra.append(lines[k].strip())
                k += 1
            if extra:
                message = " ".join([message] + extra)
            warnings.append({
                "file": path,
                "line": int(line_no),
                "column_start": int(col_start),
                "column_end": int(col_end),
                "code": int(code),
                "name": name,
                "message": message,
            })
            i = k
        else:
            i = j
    return warnings


def main():
    raw = sys.stdin.read()
    lines = raw.splitlines()
    warnings = parse(lines)
    json.dump(
        {"ocaml_compiler_warnings": {"warnings": warnings, "raw_stdout": raw}},
        sys.stdout,
        ensure_ascii=False,
        indent=2,
    )


if __name__ == "__main__":
    main()
