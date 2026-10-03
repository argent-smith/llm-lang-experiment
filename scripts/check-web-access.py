#!/usr/bin/env python3
"""Проверка транскриптов пилотных прогонов на обращения агента в интернет
и признаки контаминации — пост-фактум, пока исходящая сеть харнеса не
закрыта allowlist-ом (CLAUDE.md, «Сначала пилот», пункт 4).

    scripts/check-web-access.py [--strict] <путь>...

<путь> — transcript.jsonl, архивная сессия (docs/pilot-runs/<lang>/ticket-<N>/<session>/)
или любая директория выше (например docs/pilot-runs/ruby4-opus) — внутри
ищутся все transcript.jsonl.

Уровни находок:
  FAIL — признак контаминации:
         * маркеры мета-репозитория (llm-lang-experiment, argent-smith) в
           любом вызове инструмента или его результате;
         * вызов WebFetch/WebSearch (под PILOT_DISALLOW_WEB_TOOLS=1 их быть
           не должно);
         * обращение к внешнему хосту со словом syncbox в команде (поиск
           готовых решений).
  WARN — обращение к внешнему хосту из Bash (кроме реестров пакетов),
         упоминание хостинга кода (github/gitlab/bitbucket) в команде,
         вызов субагента (его вызовы инструментов могут не попасть в
         транскрипт — слепое пятно). Смотреть руками.
  INFO — обращения к реестрам пакетов и образов (rubygems, Docker Hub,
         npm, PyPI): сеть, но не исходники решений.

Локальные адреса (localhost, приватные IP, имена без точки — сервисы
compose и контейнеры, зарезервированные домены вроде example.com и
*.invalid) и URL с переменными оболочки не считаются.

Ограничение: ловится только то, что видно в тексте команды. Сетевой
запрос из кода, который агент написал в файл и запустил, виден, только
если в коде или в выводе есть маркеры мета-репозитория.

Выход: 0 — нет FAIL (и нет WARN при --strict), 1 — есть, 2 — ошибка запуска.
"""
import argparse
import ipaddress
import json
import re
import sys
from pathlib import Path

STRONG_MARKERS = re.compile(r"llm-lang-experiment|argent-smith", re.I)
WEB_TOOLS = {"WebFetch", "WebSearch"}
SUBAGENT_TOOLS = {"Agent", "Task"}
URL = re.compile(r"\b(?:https?|git|ssh|ftp)://(?:[^@/\s'\"`]+@)?(\[[^\]]+\]|[^/\s'\"`:?#)\]]+)", re.I)
CODE_HOSTING = re.compile(r"\b(?:[a-z0-9-]+\.)*(?:github\.com|githubusercontent\.com|gitlab\.com|bitbucket\.org)\b", re.I)
REGISTRIES = re.compile(
    r"(^|\.)(rubygems\.org|docker\.io|docker\.com|npmjs\.org|npmjs\.com|pypi\.org|pythonhosted\.org)$", re.I
)
RESERVED_TLDS = {"invalid", "example", "test", "local", "localhost", "internal"}
RESERVED_DOMAINS = re.compile(r"(^|\.)example\.(com|org|net)$", re.I)


def is_local(host: str) -> bool:
    h = host.strip("[]").rstrip(".;,").lower()
    if not h or "$" in h or "{" in h:
        return True  # переменная оболочки — не разрешить статически
    if h in ("localhost", "host.docker.internal", "gateway.docker.internal"):
        return True
    try:
        ip = ipaddress.ip_address(h)
        return ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_unspecified
    except ValueError:
        pass
    if "." not in h:
        return True  # сервис compose / имя контейнера
    return h.rsplit(".", 1)[-1] in RESERVED_TLDS or bool(RESERVED_DOMAINS.search(h))


def short(s: str, n: int = 200) -> str:
    s = " ⏎ ".join(s.splitlines())
    return s if len(s) <= n else s[: n - 1] + "…"


def check_transcript(path: Path) -> list:
    findings = []  # (level, what, detail)
    for lineno, line in enumerate(path.open(errors="replace"), 1):
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        content = (rec.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            btype = block.get("type")
            if btype == "tool_use":
                name = block.get("name", "")
                inp = block.get("input") or {}
                text = json.dumps(inp, ensure_ascii=False)
                where = f"стр. {lineno}, {name}"
                if name in WEB_TOOLS:
                    findings.append(("FAIL", f"{where}: вызов веб-инструмента", short(text)))
                if name in SUBAGENT_TOOLS:
                    findings.append(("WARN", f"{where}: субагент — его вызовы могут не попасть в транскрипт",
                                     short(str(inp.get("description") or inp.get("prompt") or text))))
                if STRONG_MARKERS.search(text):
                    findings.append(("FAIL", f"{where}: маркер мета-репозитория во входе инструмента", short(text)))
                if name == "Bash":
                    cmd = inp.get("command", "")
                    external = sorted({h for h in URL.findall(cmd) if not is_local(h)}, key=str.lower)
                    for host in external:
                        if REGISTRIES.search(host.lower()):
                            findings.append(("INFO", f"{where}: реестр {host}", short(cmd)))
                        elif re.search(r"syncbox", cmd, re.I):
                            findings.append(("FAIL", f"{where}: внешний хост {host} и «syncbox» в команде", short(cmd)))
                        else:
                            findings.append(("WARN", f"{where}: внешний хост {host}", short(cmd)))
                    hosting = {m.lower() for m in CODE_HOSTING.findall(cmd)} - {h.lower() for h in external}
                    for host in sorted(hosting):
                        findings.append(("WARN", f"{where}: хостинг кода {host} в команде", short(cmd)))
            elif btype == "tool_result":
                text = json.dumps(block.get("content"), ensure_ascii=False)
                m = STRONG_MARKERS.search(text)
                if m:
                    i = m.start()
                    findings.append(("FAIL", f"стр. {lineno}: маркер мета-репозитория в результате инструмента",
                                     short(text[max(0, i - 100): i + 100])))
    return findings


def collect(paths: list) -> list:
    out = []
    for p in map(Path, paths):
        if p.is_file():
            out.append(p)
        elif p.is_dir():
            out.extend(sorted(p.rglob("transcript.jsonl")))
        else:
            print(f"нет такого пути: {p}", file=sys.stderr)
            sys.exit(2)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--strict", action="store_true", help="WARN тоже даёт exit 1")
    args = ap.parse_args()

    transcripts = collect(args.paths)
    if not transcripts:
        print("transcript.jsonl не найдено", file=sys.stderr)
        return 2

    totals = {"FAIL": 0, "WARN": 0, "INFO": 0}
    for t in transcripts:
        findings = check_transcript(t)
        counts = {lvl: sum(1 for f in findings if f[0] == lvl) for lvl in totals}
        for lvl in totals:
            totals[lvl] += counts[lvl]
        status = "FAIL" if counts["FAIL"] else "WARN" if counts["WARN"] else "OK"
        print(f"[{status:4}] {t.parent}  (FAIL {counts['FAIL']}, WARN {counts['WARN']}, INFO {counts['INFO']})")
        for lvl, what, detail in findings:
            print(f"    {lvl} {what}\n         {detail}")

    print(f"\nтранскриптов: {len(transcripts)}; FAIL {totals['FAIL']}, WARN {totals['WARN']}, INFO {totals['INFO']}")
    if totals["FAIL"] or (args.strict and totals["WARN"]):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
