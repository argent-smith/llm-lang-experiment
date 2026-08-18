#!/usr/bin/env python3
"""Выравнивает столбцы markdown-таблиц в файле по ширине содержимого.

Используется как PostToolUse-хук после Edit/Write: перечитывает файл,
целиком переписывает найденные таблицы (заголовок, строка-разделитель,
тело) с ячейками, дополненными пробелами до ширины самой длинной ячейки
в столбце. Не трогает файл, если это не .md или таблиц не нашлось.

Запуск: align_md_tables.py <путь-к-файлу>
"""
import re
import sys


def split_row(row):
    return [cell.strip() for cell in row.strip().strip("|").split("|")]


def format_row(cells, widths):
    return "| " + " | ".join(
        cells[i].ljust(widths[i]) for i in range(len(cells))
    ) + " |"


def align_tables(text):
    lines = text.split("\n")
    out = []
    i = 0
    changed = False
    sep_re = re.compile(r'^\|(\s*:?-{2,}:?\s*\|)+\s*$')
    while i < len(lines):
        line = lines[i]
        if line.startswith("|") and i + 1 < len(lines) and sep_re.match(lines[i + 1]):
            header = line
            j = i + 2
            body = []
            while j < len(lines) and lines[j].startswith("|"):
                body.append(lines[j])
                j += 1

            header_cells = split_row(header)
            body_cells = [split_row(r) for r in body]
            ncols = len(header_cells)
            widths = [len(header_cells[c]) for c in range(ncols)]
            for row in body_cells:
                for c in range(min(ncols, len(row))):
                    widths[c] = max(widths[c], len(row[c]))

            new_header = format_row(header_cells, widths)
            new_sep = "| " + " | ".join("-" * widths[c] for c in range(ncols)) + " |"
            if new_header != header:
                changed = True
            out.append(new_header)
            out.append(new_sep)
            for k, row in enumerate(body_cells):
                new_row = format_row(row, widths)
                if new_row != body[k]:
                    changed = True
                out.append(new_row)
            i = j
        else:
            out.append(line)
            i += 1
    return "\n".join(out), changed


def main():
    if len(sys.argv) != 2:
        return
    path = sys.argv[1]
    if not path.endswith(".md"):
        return
    try:
        with open(path, encoding="utf-8") as f:
            original = f.read()
    except (FileNotFoundError, IsADirectoryError, UnicodeDecodeError):
        return

    updated, changed = align_tables(original)
    if changed:
        with open(path, "w", encoding="utf-8") as f:
            f.write(updated)


if __name__ == "__main__":
    main()
