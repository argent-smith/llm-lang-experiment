#!/usr/bin/env python3
"""Генерирует initial-промпты тикетов с зафиксированной версией языка —
для кампаний с закреплённой версией (docs/opus-ruby/, docs/opus-langs/).

    scripts/make-pinned-prompts.py --source-lang ruby --target-lang ruby4-opus \\
        --version "Ruby 4.0" --image ruby:4.0-slim [--tickets "1 2 ... 11"] \\
        [--out docs/opus-ruby/prompts]

Источник — тот же initial-промпт, что берёт run-pilot-replay.sh:
канонический из docs/pilot-runs/manifest.json, а если там фикс-промпт —
старейшая (по лексическому порядку session-uuid) сессия тикета с
initial-промптом. Текст не меняется, в конец дописывается один абзац с
версией и базовым образом — одинаковый для всех тикетов, чтобы агент не
сменил образ на поздних тикетах.

Пишет <out>/<target-lang>/ticket-<N>-prompt.txt; run-pilot-replay.sh
читает их через --prompt-dir <out>.
"""
import argparse
import json
import re
import sys
from pathlib import Path
from typing import Optional

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST = REPO_ROOT / "docs/pilot-runs/manifest.json"
INITIAL_RE = re.compile(r"^(Мы начинаем новый проект Syncbox|Продолжаем проект Syncbox)")

PIN_TEMPLATE = (
    "Версия языка в этом проекте зафиксирована: {version}, базовый "
    "Docker-образ {image} (FROM {image} в Dockerfile). Не меняй версию "
    "языка и базовый образ."
)


def is_initial(p: Path) -> bool:
    try:
        return bool(INITIAL_RE.match(p.read_text()[:400]))
    except OSError:
        return False


def resolve(lang: str, ticket: str) -> Optional[Path]:
    manifest = json.loads(MANIFEST.read_text())
    cano = manifest["languages"].get(lang, {}).get("tickets", {}).get(ticket)
    if cano:
        p = REPO_ROOT / cano / "prompt.txt"
        if is_initial(p):
            return p
    for p in sorted((REPO_ROOT / "docs/pilot-runs" / lang / f"ticket-{ticket}").glob("*/prompt.txt")):
        if is_initial(p):
            return p
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source-lang", required=True)
    ap.add_argument("--target-lang", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--image", required=True)
    ap.add_argument("--tickets", default="1 2 3 4 5 6 7 8 9 10 11")
    ap.add_argument("--out", default=str(REPO_ROOT / "docs/opus-ruby/prompts"))
    args = ap.parse_args()

    pin = PIN_TEMPLATE.format(version=args.version, image=args.image)
    out_dir = Path(args.out).resolve() / args.target_lang
    out_dir.mkdir(parents=True, exist_ok=True)
    for n in args.tickets.split():
        src = resolve(args.source_lang, n)
        if src is None:
            print(f"нет initial-промпта для {args.source_lang}/ticket-{n}", file=sys.stderr)
            return 1
        text = src.read_text().rstrip("\n")
        dst = out_dir / f"ticket-{n}-prompt.txt"
        dst.write_text(f"{text}\n\n{pin}\n")
        print(f"{dst.relative_to(REPO_ROOT)}  <-  {src.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
