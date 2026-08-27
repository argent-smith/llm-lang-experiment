#!/usr/bin/env python3
"""Разбирает архив одной попытки тикета (transcript.jsonl + result.json) на
три составляющих времени: модель (API), инфраструктура (загрузка/установка
зависимостей), работа (всё остальное — сборка/тесты написанного агентом
кода, отладочные команды, правки файлов).

Не эксперимент про "какой язык лучше" — это разбор самой метрики
"время"/"стоимость" (CLAUDE.md, раздел «Лог»): она включает локальное
выполнение инструментов внутри вызова `claude -p`, и без разбивки нельзя
отличить холодную загрузку Docker-образа/пакетов от того, что модель
реально сделала.

Метод:
  - `duration_api_ms` из result.json — уже готовое, официальное время
    модели (сумма по всем турнам вызова, не наша оценка).
  - Инструментальное время (duration_ms - duration_api_ms) разбирается по
    transcript.jsonl: для каждой пары tool_use/tool_result считается
    wall-time (timestamp tool_result минус timestamp tool_use).
  - Bash-команды классифицируются по паттерну: `docker pull`/`docker
    build`/`docker compose build` — разбираются ДОПОЛНИТЕЛЬНО построчно
    по BuildKit-выводу (`#N [stage step] INSTRUCTION` + `#N DONE X.Ys`/
    `#N CACHED`) — каждый шаг сборки классифицируется отдельно
    (apt-get/opam install/bundle install/npm install/gem install/pip
    install/sbt update/go mod download/базовый образ — инфраструктура;
    COPY исходников, компиляция/тесты агента — работа). Остальные
    Bash-команды (grep/cat/sed/curl/git/ls/docker ps/rm и т.п.) и любые
    не-Bash инструменты (Read/Write/Edit) — работа.
  - Голый `docker build` (не через compose) в части прогонов шёл через
    classic builder, не BuildKit (`Step N/M : INSTRUCTION` + `--->
    <hash>`, без секунд на шаг вообще — подтверждено эмпирически на
    OCaml, тикет 2: `docker build --no-cache` дал именно такой формат).
    Раз таймингов по шагам нет, точную пропорцию внутри такого вызова
    посчитать нельзя — грубый fallback: если хотя бы один шаг содержит
    install/pull-паттерн, весь вызов целиком считается инфраструктурой
    (`classification: "build-legacy (heuristic: infra)"`), иначе —
    работой. Более грубо, чем BuildKit-разбор, но точнее, чем "работа"
    по умолчанию на вызове, где 9 из 14 шагов — `opam install`
    полусотни транзитивных пакетов Dream.
  - `инфра_ms` = сумма классифицированных инфраструктурных кусков.
    `работа_ms` = (duration_ms - duration_api_ms) - инфра_ms — не
    независимая сумма, а остаток от уже известного (из result.json)
    инструментального времени, чтобы не накапливать дрейф от
    построчного тайминга транскрипта.

Ограничение метода: классификация — эвристика по ключевым словам, не
парсинг AST Dockerfile. Не проверялась на языках вне уже прогнанных
семи (novel фреймворки/менеджеры пакетов потребуют расширения списка
паттернов) — при добавлении нового языка стоит сверить вручную хотя бы
один тикет, как это сделано для Scala/Ruby/OCaml при разработке скрипта.

Использование:
  scripts/analyze-timing-breakdown.py <archive-dir> [--verbose]

<archive-dir> — docs/pilot-runs/<язык>/ticket-<N>/<session_id>/, должен
содержать transcript.jsonl и result.json (result.json без него ничего не
даёт).

Пишет:
  <archive-dir>/timing-breakdown.json
"""
import json
import re
import sys
from pathlib import Path
from datetime import datetime, timezone

INFRA_RUN_KEYWORDS = re.compile(
    r"\bapt-get\b|\bapk (add|update)\b|\bopam (install|update)\b|"
    r"\bbundle install\b|\bnpm (install|ci)\b|\byarn install\b|"
    r"\bpip install\b|\bgem install\b|\bmix deps\.get\b|\bcargo fetch\b|"
    r"\bsbt update\b|\bgo mod (download|tidy)\b",
    re.IGNORECASE,
)
# Топ-уровневые Bash-команды, которые сами по себе — инфраструктура (не
# сборка, не собираются в докер-шаги: голая загрузка образа/пакета).
INFRA_TOPLEVEL_RE = re.compile(
    r"^\s*docker (image )?pull\b|^\s*opam (install|update)\b|"
    r"^\s*bundle install\b|^\s*npm (install|ci)\b|^\s*gem install\b|"
    r"^\s*pip install\b|^\s*apt-get\b",
    re.IGNORECASE,
)
BUILD_TOPLEVEL_RE = re.compile(
    r"docker (compose )?build\b|docker compose up[^\n]*--build",
    re.IGNORECASE,
)
BUILDKIT_STEP_RE = re.compile(r"^#(\d+) \[([^\]]+)\] (.+)$")
BUILDKIT_DONE_RE = re.compile(r"^#(\d+) DONE ([\d.]+)s$")
BUILDKIT_CACHED_RE = re.compile(r"^#(\d+) CACHED$")

# Внутри BuildKit-шага классифицируем по тексту самой инструкции
# Dockerfile (после "[stage N/M] "), не по номеру стадии — RUN может быть
# и install, и build в одном и том же Dockerfile.
INFRA_STEP_RE = re.compile(
    r"^FROM\b|apt-get|apk (add|update)|opam (install|update)|"
    r"bundle install|npm (install|ci)|yarn install|pip install|"
    r"gem install|mix deps\.get|cargo fetch|sbt update|"
    r"go mod (download|tidy)",
    re.IGNORECASE,
)


def parse_ts(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def classify_buildkit_output(stdout):
    """Возвращает (infra_seconds, work_seconds, unclassified_seconds) по
    построчному разбору вывода BuildKit одного docker build.

    BuildKit — не построчный лог, а перерисовываемый прогресс: строка
    `#N [stage] INSTRUCTION` и финальная `#N DONE X.Ys` могут повторяться
    несколько раз по ходу сборки (перепечатка при каждом обновлении
    прогресса) — без дедупликации по номеру шага секунды считаются
    кратно (проверено эмпирически на Scala, тикет 1: без дедупликации
    сумма классифицированных секунд получалась вдвое больше реального
    wall-time вызова). Берём последнее значение DONE на каждый номер
    шага, не сумму встреч.

    Секунды по шагам всё равно не обязаны совпадать с wall-time самого
    Bash-вызова даже после дедупликации — стадии `build`/`runtime`
    Dockerfile выполняются параллельно (пока качается финальный образ
    рантайма, параллельно резолвятся зависимости sbt/opam/etc.), так
    что сумма по шагам может занижать или (чаще) завышать реальное
    время. Поэтому наружу отдаём не абсолютные секунды, а ПРОПОРЦИЮ
    инфраструктуры к общей классифицированной сумме — вызывающий код
    масштабирует её на реальный wall-time Bash-вызова, а не полагается
    на абсолютные значения BuildKit."""
    step_instruction = {}  # step_num -> instruction text (последнее упоминание)
    step_done_s = {}  # step_num -> секунды (последнее упоминание DONE)
    for line in stdout.splitlines():
        m = BUILDKIT_STEP_RE.match(line)
        if m:
            step_instruction[m.group(1)] = m.group(3)
            continue
        m = BUILDKIT_DONE_RE.match(line)
        if m:
            step_done_s[m.group(1)] = float(m.group(2))
    infra_s = 0.0
    work_s = 0.0
    unclassified_s = 0.0
    for step_num, secs in step_done_s.items():
        instruction = step_instruction.get(step_num, "")
        if INFRA_STEP_RE.search(instruction):
            infra_s += secs
        elif instruction:
            work_s += secs
        else:
            unclassified_s += secs
    return infra_s, work_s, unclassified_s


LEGACY_STEP_RE = re.compile(r"^Step \d+/\d+ : (.+)$")
# Прямые следы работы пакетного менеджера — ловят install-активность,
# даже если сама строка "Step N/M : RUN ..." срезана `tail -N` в
# команде агента (подтверждено эмпирически: OCaml, тикет 2 — два из
# трёх вызовов `docker build ... | tail -30`/`| tail -150` обрезали
# строку объявления шага, но не построчный вывод самой установки).
PACKAGE_INSTALL_EVIDENCE_RE = re.compile(
    r"^-> installed |^Fetching gem |^Installing \S+ \S|"
    r"added \d+ packages? in|^Collecting |^Get:\d+ ",
    re.MULTILINE,
)


def classify_legacy_build_output(stdout):
    """Fallback для classic (не-BuildKit) вывода `docker build`
    (`Step N/M : INSTRUCTION` + `---> <hash>`, без секунд на шаг).
    Без таймингов пропорцию внутри вызова посчитать нельзя — возвращает
    True, если хотя бы один шаг похож на install/pull, или если в
    выводе есть прямые следы работы пакетного менеджера (см.
    PACKAGE_INSTALL_EVIDENCE_RE — подстраховка на случай, если сама
    строка "Step N/M :" обрезана `tail -N` в команде агента, а вывод
    самой установки — нет). Весь вызов тогда считается инфраструктурой
    целиком. False, если ни то ни другое не найдено. None, если в
    выводе вообще нет `Step N/M :` строк (не этот формат — например,
    сборка не запускалась, ошибка раньше первого шага)."""
    if PACKAGE_INSTALL_EVIDENCE_RE.search(stdout):
        return True
    found_step = False
    for line in stdout.splitlines():
        m = LEGACY_STEP_RE.match(line)
        if m:
            found_step = True
            if INFRA_STEP_RE.search(m.group(1)):
                return True
    return False if found_step else None


def analyze(archive_dir: Path, verbose=False):
    result_path = archive_dir / "result.json"
    transcript_path = archive_dir / "transcript.jsonl"
    if not result_path.exists():
        raise SystemExit(f"нет result.json в {archive_dir}")
    result = json.loads(result_path.read_text())
    duration_ms = result["duration_ms"]
    duration_api_ms = result["duration_api_ms"]
    tool_ms_total = duration_ms - duration_api_ms

    infra_ms = 0.0
    events = []

    if transcript_path.exists():
        lines = transcript_path.read_text().splitlines()
        records = [json.loads(l) for l in lines if l.strip()]
        # индекс: tool_use_id -> (command/name, timestamp вызова)
        pending = {}
        for rec in records:
            msg = rec.get("message")
            if not isinstance(msg, dict):
                continue
            content = msg.get("content")
            if not isinstance(content, list):
                continue
            for c in content:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "tool_use":
                    pending[c.get("id")] = {
                        "name": c.get("name"),
                        "input": c.get("input", {}),
                        "ts": rec.get("timestamp"),
                    }
                elif c.get("type") == "tool_result":
                    tid = c.get("tool_use_id")
                    call = pending.pop(tid, None)
                    if not call or not call.get("ts") or not rec.get("timestamp"):
                        continue
                    try:
                        t0 = parse_ts(call["ts"])
                        t1 = parse_ts(rec["timestamp"])
                    except (ValueError, TypeError):
                        continue
                    elapsed = (t1 - t0).total_seconds()
                    if elapsed <= 0:
                        continue
                    name = call["name"]
                    classification = "work"
                    detail = ""
                    if name == "Bash":
                        command = call["input"].get("command", "")
                        if BUILD_TOPLEVEL_RE.search(command):
                            stdout = (rec.get("toolUseResult") or {}).get("stdout", "")
                            i_s, w_s, u_s = classify_buildkit_output(stdout)
                            classified_sum = i_s + w_s + u_s
                            if classified_sum > 0:
                                # переносим пропорцию инфра/работа BuildKit-разбора
                                # на реальный wall-time этого Bash-вызова (elapsed) —
                                # BuildKit печатает свои собственные секунды заново
                                # от старта каждого шага, они не обязаны идеально
                                # совпадать с elapsed (буферизация вывода и т.п.).
                                infra_frac = i_s / classified_sum
                                infra_ms += elapsed * 1000 * infra_frac
                                classification = f"build (infra {i_s:.1f}s / work {w_s:.1f}s / unclassified {u_s:.1f}s of {elapsed:.1f}s wall)"
                            else:
                                # Не BuildKit-формат — часть прогонов (голый
                                # `docker build`, не через compose) шла через
                                # classic builder без секунд на шаг вообще
                                # (подтверждено эмпирически на OCaml, тикет 2).
                                legacy = classify_legacy_build_output(stdout)
                                if legacy is True:
                                    infra_ms += elapsed * 1000
                                    classification = "build-legacy (heuristic: infra — есть install/pull среди шагов)"
                                elif legacy is False:
                                    classification = "build-legacy (heuristic: work — install/pull среди шагов не найден)"
                                else:
                                    classification = "build (не распознан ни BuildKit, ни classic формат)"
                        elif INFRA_TOPLEVEL_RE.search(command) or INFRA_RUN_KEYWORDS.search(command):
                            infra_ms += elapsed * 1000
                            classification = "infra"
                        detail = command[:100]
                    if verbose:
                        events.append({
                            "tool": name,
                            "elapsed_s": round(elapsed, 2),
                            "classification": classification,
                            "detail": detail,
                        })

    work_ms = tool_ms_total - infra_ms
    breakdown = {
        "session_id": result.get("session_id"),
        "duration_ms": duration_ms,
        "duration_api_ms": duration_api_ms,
        "tool_ms_total": tool_ms_total,
        "infra_ms": round(infra_ms),
        "work_ms": round(work_ms),
        "note": "work_ms = tool_ms_total - infra_ms (остаток от официального duration_ms - duration_api_ms, не независимая сумма по транскрипту)",
    }
    if verbose:
        breakdown["events"] = events

    out_path = archive_dir / "timing-breakdown.json"
    out_path.write_text(json.dumps(breakdown, ensure_ascii=False, indent=2))
    return breakdown


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    verbose = "--verbose" in sys.argv
    archive_dir = Path([a for a in sys.argv[1:] if not a.startswith("--")][0])
    b = analyze(archive_dir, verbose=verbose)
    total_s = b["duration_ms"] / 1000
    print(
        f"{archive_dir.name}: total={total_s:.1f}s "
        f"api={b['duration_api_ms']/1000:.1f}s "
        f"infra={b['infra_ms']/1000:.1f}s "
        f"work={b['work_ms']/1000:.1f}s"
    )
