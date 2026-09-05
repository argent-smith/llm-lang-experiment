#!/usr/bin/env python3
"""Состояние кампании перепрогона пилота (scripts/run-pilot-replay.sh):
персистентный чекпойнт + парсер времени сброса оконного лимита (429/529).

Чекпойнт — единственный источник правды о том, что уже сделано: после
каждой ячейки (язык × тикет) run-pilot-replay.sh дописывает сюда запись,
поэтому Ctrl-C в любой момент + повторный запуск с --resume безопасны.

Форма файла:

  {
    "schema": 1,
    "campaign": { ...конфиг запуска (языки, тикеты, режимы гейтов)... },
    "started": "<iso8601 UTC>",
    "cells": [
      {"lang": "python", "ticket": "1", "status": "converged|gave_up|...",
       "session": "<uuid>", "outcome": "<строка из .loop.json>",
       "cost_usd": 0.88, "num_turns": 30, "iters": 1, "retries": 0,
       "loop_json": "<путь>", "ts": "<iso8601 UTC>"}
    ],
    "pauses": [
      {"lang": "typescript", "ticket": "5", "detected_at": "<iso>",
       "reset_target": "<iso|null>", "reset_epoch": 1234567890,
       "source": "<путь к iterK.json>", "retry": 1}
    ],
    "stopped": null | {"reason": "<строка>", "lang": "...", "ticket": "..."}
  }

Подкоманды:
  init         <ckpt> --config <json>        создать (или не трогать, если есть и не --force)
  is-done      <ckpt> <lang> <ticket>        exit 0, если ячейка status=converged
  record-cell  <ckpt> <lang> <ticket> --loop-json <f> --status <s> --retries <n>
  record-pause <ckpt> <lang> <ticket> --reset-epoch <n|-> --reset-target <iso|-> --source <f> --retry <n>
  set-stopped  <ckpt> --reason <s> [--lang <l>] [--ticket <t>]
  clear-stopped <ckpt>
  summary      <ckpt>                        человекочитаемая таблица + суммы
  parse-reset  <iterK.json>                  печатает epoch-секунды времени сброса или ничего
"""
import argparse
import datetime as dt
import json
import re
import sys


def _utcnow_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def _load(path: str) -> dict:
    with open(path) as fh:
        return json.load(fh)


def _save(path: str, data: dict) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    import os

    os.replace(tmp, path)


# ---------------------------------------------------------------- parse-reset

_RESET_PATTERNS = [
    # ISO8601 с датой: "resets 2026-09-04T22:00:00Z" / "... 22:00 UTC"
    (re.compile(r"(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?\s*(?:Z|UTC|\+00:?00)?", re.I),
     "iso"),
    # "resets at 5:30pm (UTC)" / "resets 10pm UTC" / "resets 17:30 (UTC)"
    (re.compile(r"resets?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*\(?\s*UTC\s*\)?", re.I),
     "wallclock"),
    # относительное: "resets in 2 hours" / "in 45 minutes"
    (re.compile(r"in\s+(\d+)\s*hours?", re.I), "rel_hours"),
    (re.compile(r"in\s+(\d+)\s*minutes?", re.I), "rel_minutes"),
]


def _epoch(d: dt.datetime) -> int:
    return int(d.timestamp())


def parse_reset_text(text: str):
    """text -> (epoch_seconds, iso_string) времени сброса, либо (None, None)."""
    now = dt.datetime.now(dt.timezone.utc)
    for rx, kind in _RESET_PATTERNS:
        m = rx.search(text)
        if not m:
            continue
        if kind == "iso":
            y, mo, da, hh, mm, ss = m.groups()
            tgt = dt.datetime(int(y), int(mo), int(da), int(hh), int(mm),
                              int(ss or 0), tzinfo=dt.timezone.utc)
            if tgt <= now:
                continue
            return _epoch(tgt), tgt.isoformat()
        if kind == "wallclock":
            hh = int(m.group(1))
            mm = int(m.group(2) or 0)
            ampm = (m.group(3) or "").lower()
            if ampm == "pm" and hh != 12:
                hh += 12
            elif ampm == "am" and hh == 12:
                hh = 0
            if not (0 <= hh <= 23):
                continue
            tgt = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
            if tgt <= now:
                # Оконный лимит Anthropic обычно сбрасывается в фиксированное
                # время суток (UTC). Если это время только что прошло —
                # сообщение почти наверняка про ближайший сброс с небольшим
                # запаздыванием, не про завтрашний: подождать немного.
                # Если прошло давно — вероятно всё-таки следующие сутки.
                # Итоговое ожидание в любом случае урезано --max-pause-sec
                # в run-pilot-replay.sh.
                if now - tgt < dt.timedelta(hours=2):
                    tgt = now + dt.timedelta(minutes=10)
                else:
                    tgt += dt.timedelta(days=1)
            return _epoch(tgt), tgt.isoformat()
        if kind == "rel_hours":
            tgt = now + dt.timedelta(hours=int(m.group(1)))
            return _epoch(tgt), tgt.isoformat()
        if kind == "rel_minutes":
            tgt = now + dt.timedelta(minutes=int(m.group(1)))
            return _epoch(tgt), tgt.isoformat()
    return None, None


def cmd_parse_reset(args) -> int:
    try:
        d = _load(args.iter_json)
    except (OSError, ValueError):
        return 0
    haystack = " ".join(
        str(d.get(k, "")) for k in ("result", "error", "message")
    )
    if not haystack.strip():
        haystack = json.dumps(d, ensure_ascii=False)
    epoch, iso = parse_reset_text(haystack)
    if epoch is not None:
        print(epoch)
        print(iso, file=sys.stderr)
    return 0


# ---------------------------------------------------------------- checkpoint ops


def cmd_init(args) -> int:
    import os

    if os.path.exists(args.ckpt) and not args.force:
        return 0
    data = {
        "schema": 1,
        "campaign": json.loads(args.config) if args.config else {},
        "started": _utcnow_iso(),
        "cells": [],
        "pauses": [],
        "stopped": None,
    }
    _save(args.ckpt, data)
    return 0


def _find_cell(data: dict, lang: str, ticket: str):
    for c in data["cells"]:
        if c["lang"] == lang and str(c["ticket"]) == str(ticket):
            return c
    return None


def cmd_is_done(args) -> int:
    try:
        data = _load(args.ckpt)
    except (OSError, ValueError):
        return 1
    c = _find_cell(data, args.lang, args.ticket)
    return 0 if (c and c.get("status") == "converged") else 1


def cmd_lang_started(args) -> int:
    """exit 0, если у языка есть ХОТЯ БЫ одна записанная ячейка (любой статус).
    Нужно run-pilot-replay.sh, чтобы под --resume отличить язык в процессе
    (не вайпать накопленный код) от ещё не начатого (вайпать/отказать)."""
    try:
        data = _load(args.ckpt)
    except (OSError, ValueError):
        return 1
    return 0 if any(c["lang"] == args.lang for c in data["cells"]) else 1


_STATUS_FROM_OUTCOME = [
    (re.compile(r"^сошлось"), "converged"),
    (re.compile(r"rate-limit\s+(429|529)"), "rate_limited"),
    (re.compile(r"api_error_status=(429|529)"), "rate_limited"),
    (re.compile(r"харнесс неисправен"), "harness_invalid"),
    (re.compile(r"правил спецификацию"), "spec_level_giveup"),
    (re.compile(r"не сошлись за \d+ итераций"), "did_not_converge"),
    (re.compile(r"^сдался \(инфра"), "infra_failure"),
]


def status_from_outcome(outcome: str) -> str:
    for rx, st in _STATUS_FROM_OUTCOME:
        if rx.search(outcome or ""):
            return st
    return "unknown"


def cmd_record_cell(args) -> int:
    data = _load(args.ckpt)
    loop = _load(args.loop_json)
    outcome = loop.get("outcome", "")
    iters = loop.get("iterations", []) or []

    def _num(v):
        try:
            return float(v)
        except (TypeError, ValueError):
            return 0.0

    cost = round(sum(_num(it.get("cost_usd")) for it in iters), 4)
    turns = int(sum(_num(it.get("num_turns")) for it in iters))
    last_session = ""
    for it in iters:
        if it.get("session"):
            last_session = it["session"]

    status = args.status or status_from_outcome(outcome)
    cell = {
        "lang": args.lang,
        "ticket": str(args.ticket),
        "status": status,
        "session": last_session,
        "outcome": outcome,
        "cost_usd": cost,
        "num_turns": turns,
        "iters": len(iters),
        "retries": int(args.retries),
        "api_error_status": str(loop.get("api_error_status", "") or ""),
        "loop_json": args.loop_json,
        "ts": _utcnow_iso(),
    }
    # перезаписать прежнюю запись той же ячейки (ретрай после паузы), не плодить
    data["cells"] = [
        c for c in data["cells"]
        if not (c["lang"] == args.lang and str(c["ticket"]) == str(args.ticket))
    ]
    data["cells"].append(cell)
    _save(args.ckpt, data)
    print(status)
    return 0


def cmd_record_pause(args) -> int:
    data = _load(args.ckpt)
    data["pauses"].append({
        "lang": args.lang,
        "ticket": str(args.ticket),
        "detected_at": _utcnow_iso(),
        "reset_epoch": None if args.reset_epoch in ("", "-", None) else int(args.reset_epoch),
        "reset_target": None if args.reset_target in ("", "-", None) else args.reset_target,
        "source": args.source,
        "retry": int(args.retry),
    })
    _save(args.ckpt, data)
    return 0


def cmd_set_stopped(args) -> int:
    data = _load(args.ckpt)
    data["stopped"] = {
        "reason": args.reason,
        "lang": args.lang or None,
        "ticket": args.ticket or None,
        "ts": _utcnow_iso(),
    }
    _save(args.ckpt, data)
    return 0


def cmd_clear_stopped(args) -> int:
    data = _load(args.ckpt)
    data["stopped"] = None
    _save(args.ckpt, data)
    return 0


def cmd_summary(args) -> int:
    data = _load(args.ckpt)
    camp = data.get("campaign", {})
    langs = camp.get("languages") or sorted({c["lang"] for c in data["cells"]})
    tickets = [str(t) for t in (camp.get("tickets") or [])]
    if not tickets:
        tickets = sorted({str(c["ticket"]) for c in data["cells"]}, key=lambda x: (len(x), x))

    mark = {
        "converged": "ok",
        "rate_limited": "429",
        "harness_invalid": "HARNESS",
        "spec_level_giveup": "spec-giveup",
        "did_not_converge": "no-converge",
        "infra_failure": "INFRA",
        "unknown": "?",
    }
    print(f"кампания начата: {data.get('started')}")
    print(f"языки: {' '.join(langs)}    тикеты: {' '.join(tickets)}")
    print()
    header = "тикет  | " + " | ".join(f"{l:>10}" for l in langs)
    print(header)
    print("-" * len(header))
    total_cost = 0.0
    total_turns = 0
    for t in tickets:
        row = [f"{t:>5}  "]
        for l in langs:
            c = _find_cell(data, l, t)
            if not c:
                row.append(f"{'—':>10}")
            else:
                total_cost += c.get("cost_usd", 0.0)
                total_turns += c.get("num_turns", 0)
                tag = mark.get(c["status"], c["status"])
                row.append(f"{tag:>10}")
        print(" | ".join(row))
    print("-" * len(header))
    done = sum(1 for c in data["cells"] if c["status"] == "converged")
    print(f"\nсошлось ячеек: {done}/{len(langs) * len(tickets)}")
    print(f"суммарно $ (по записанным ячейкам): {total_cost:.2f}")
    print(f"суммарно num_turns: {total_turns}")
    if data.get("pauses"):
        print(f"пауз по лимиту (429/529): {len(data['pauses'])}")
        for p in data["pauses"]:
            print(f"  - {p['lang']} тикет {p['ticket']}: до {p.get('reset_target') or '?'} "
                  f"(retry {p['retry']})")
    if data.get("stopped"):
        s = data["stopped"]
        print(f"\nОСТАНОВЛЕНО: {s['reason']} "
              f"({s.get('lang') or '-'} тикет {s.get('ticket') or '-'})")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("parse-reset")
    p.add_argument("iter_json")
    p.set_defaults(fn=cmd_parse_reset)

    p = sub.add_parser("init")
    p.add_argument("ckpt")
    p.add_argument("--config", default="")
    p.add_argument("--force", action="store_true")
    p.set_defaults(fn=cmd_init)

    p = sub.add_parser("is-done")
    p.add_argument("ckpt")
    p.add_argument("lang")
    p.add_argument("ticket")
    p.set_defaults(fn=cmd_is_done)

    p = sub.add_parser("lang-started")
    p.add_argument("ckpt")
    p.add_argument("lang")
    p.set_defaults(fn=cmd_lang_started)

    p = sub.add_parser("record-cell")
    p.add_argument("ckpt")
    p.add_argument("lang")
    p.add_argument("ticket")
    p.add_argument("--loop-json", required=True)
    p.add_argument("--status", default="")
    p.add_argument("--retries", default="0")
    p.set_defaults(fn=cmd_record_cell)

    p = sub.add_parser("record-pause")
    p.add_argument("ckpt")
    p.add_argument("lang")
    p.add_argument("ticket")
    p.add_argument("--reset-epoch", default="-")
    p.add_argument("--reset-target", default="-")
    p.add_argument("--source", default="")
    p.add_argument("--retry", default="0")
    p.set_defaults(fn=cmd_record_pause)

    p = sub.add_parser("set-stopped")
    p.add_argument("ckpt")
    p.add_argument("--reason", required=True)
    p.add_argument("--lang", default="")
    p.add_argument("--ticket", default="")
    p.set_defaults(fn=cmd_set_stopped)

    p = sub.add_parser("clear-stopped")
    p.add_argument("ckpt")
    p.set_defaults(fn=cmd_clear_stopped)

    p = sub.add_parser("summary")
    p.add_argument("ckpt")
    p.set_defaults(fn=cmd_summary)

    args = ap.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
