#!/usr/bin/env python3
"""Разбирает `work_ms` (см. analyze-timing-breakdown.py) на подкатегории —
тесты / сборка (не-инфраструктурная часть build-вызова) / curl-проверки /
docker-обвязка (up/down/ps/logs, не build) / чтение-правка файлов агентом /
прочий Bash — для одного или нескольких прогонов подряд, с агрегацией по
языку.

Не пишет ничего на диск и не трогает существующие timing-breakdown.json —
чистое исследование поверх transcript.jsonl, разовый разбор для доклада
(секция про распределение времени агента на Ruby-тикетах), не часть
регулярного пайплайна run-pilot-ticket.sh.

Переиспользует регексы и BuildKit/legacy-классификаторы инфраструктуры из
analyze-timing-breakdown.py (динамический импорт — имя модуля с дефисами),
чтобы граница infra/work не разъехалась с уже посчитанными
timing-breakdown.json.

Использование:
  scripts/analyze-work-categories.py <archive-dir> [<archive-dir> ...]
  scripts/analyze-work-categories.py --manifest ruby   # все 11 канонических тикетов языка
"""
import importlib.util
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent

spec = importlib.util.spec_from_file_location(
    "atb", HERE / "analyze-timing-breakdown.py"
)
atb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(atb)

TEST_RE = re.compile(
    r"\brspec\b|bundle exec (rspec|rake)|\bpytest\b|\bnpm test\b|"
    r"\bnode --test\b|\bgo test\b|\bmix test\b|\bsbt test\b|\bdune (runtest|test)\b|"
    r"run-tests\b|\bnpm run test\b|\byarn test\b",
    re.IGNORECASE,
)
CURL_RE = re.compile(r"^\s*curl\b", re.IGNORECASE)
DOCKER_OPS_RE = re.compile(
    r"docker compose (up|down|ps|logs|stop|restart|rm)\b|^\s*docker (ps|logs|stop|rm|kill)\b",
    re.IGNORECASE,
)
NON_BASH_EDIT_TOOLS = {"Read", "Write", "Edit", "Glob", "Grep", "NotebookEdit"}


def categorize_event(ev):
    tool = ev["tool"]
    classification = ev["classification"]
    detail = ev["detail"]
    elapsed = ev["elapsed_s"]

    if classification == "infra":
        return "infra", 0.0  # уже учтено в infra_ms официальной разбивки
    if classification.startswith("build"):
        m = re.search(r"work ([\d.]+)s", classification)
        work_s = float(m.group(1)) if m else 0.0
        legacy_work = "build-legacy (heuristic: work" in classification
        return "build", (elapsed if legacy_work else work_s)
    if tool != "Bash":
        if tool in NON_BASH_EDIT_TOOLS:
            return "code_edit", elapsed
        return "other_bash", elapsed
    if TEST_RE.search(detail):
        return "tests", elapsed
    if CURL_RE.search(detail):
        return "smoke_curl", elapsed
    if DOCKER_OPS_RE.search(detail):
        return "docker_ops", elapsed
    return "other_bash", elapsed


def analyze_dir(archive_dir: Path):
    # atb.analyze() пишет <archive-dir>/timing-breakdown.json как побочный
    # эффект (verbose=True добавит туда events — раздувает уже
    # закоммиченный файл). Снимаем исходные байты и восстанавливаем после
    # вызова: этот скрипт — разовое исследование, не должен молча менять
    # архивные данные прогонов.
    out_path = archive_dir / "timing-breakdown.json"
    original = out_path.read_bytes() if out_path.exists() else None
    try:
        breakdown = atb.analyze(archive_dir, verbose=True)
    finally:
        if original is not None:
            out_path.write_bytes(original)
        elif out_path.exists():
            out_path.unlink()
    events = breakdown.get("events", [])
    cats = {}
    for ev in events:
        cat, secs = categorize_event(ev)
        cats[cat] = cats.get(cat, 0.0) + secs
    return cats, breakdown


def load_manifest_dirs(lang):
    manifest = json.loads((REPO_ROOT / "docs/pilot-runs/manifest.json").read_text())
    tickets = manifest["languages"][lang]["tickets"]
    out = []
    for n in sorted(tickets, key=lambda x: (len(x), x)):
        if not n[0].isdigit() or "-" in n:
            continue  # только канонический бэклог 1..11, без readside/fix-вариантов
        out.append((n, REPO_ROOT / tickets[n]))
    return out


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)
    if args[0] == "--manifest":
        lang = args[1]
        dirs = load_manifest_dirs(lang)
    else:
        dirs = [(p, Path(p)) for p in args]

    totals = {}
    work_ms_official_sum = 0.0
    for label, d in dirs:
        cats, breakdown = analyze_dir(d)
        work_ms_official_sum += breakdown["work_ms"]
        line = " ".join(f"{k}={v:.1f}s" for k, v in sorted(cats.items(), key=lambda kv: -kv[1]))
        print(f"[{label}] {line}")
        for k, v in cats.items():
            totals[k] = totals.get(k, 0.0) + v

    print()
    print("Итого по категориям (минуты):")
    grand_total = sum(v for k, v in totals.items() if k != "infra")
    for k, v in sorted(totals.items(), key=lambda kv: -kv[1]):
        if k == "infra":
            continue
        pct = (v / grand_total * 100) if grand_total else 0
        print(f"  {k:12s} {v/60:6.2f} мин  ({pct:4.1f}%)")
    print(f"  {'сумма work':12s} {grand_total/60:6.2f} мин")
    print(f"  (официальный work_ms по timing-breakdown.json: {work_ms_official_sum/60000:.2f} мин — сверка)")


if __name__ == "__main__":
    main()
