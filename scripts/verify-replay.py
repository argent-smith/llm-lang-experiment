#!/usr/bin/env python3
"""Компактная проверка архива пилотного прогона — вместо ad-hoc парсинга
транскрипта/гейтов руками после каждого запуска.

    scripts/verify-replay.py <archive-dir> [<out-prefix>|<loop.json>]

<archive-dir>  — docs/pilot-runs/<lang>/ticket-<N>/<session_id>/
<out-prefix>   — префикс, переданный run-pilot-loop.sh (тогда берутся
                 <prefix>.loop.json и последний <prefix>.iterK.gates/gates.json);
                 можно указать сам .loop.json.

Печатает одну сводку и выходит 0 (PASS) / 1 (FAIL). Критерий PASS:
  * transcript.jsonl валиден (есть записи, первая строка — JSON, не NUL);
  * ноль «No suitable shell found»;
  * result.json: is_error=false, api_error_status пуст;
  * если дан loop.json: outcome начинается с «сошл», блокирующие гейты
    (tests, contract) — pass.
smoke не влияет на PASS (локальный флак Docker Desktop — CI авторитетнее),
но показывается. warning из timing-breakdown.json показывается и метит WARN.
"""
import json
import re
import sys
from pathlib import Path


def _load(p):
    try:
        return json.loads(Path(p).read_text())
    except Exception:
        return None


def check_transcript(path: Path):
    """-> (total_lines, valid_json, shell_errors, tool_counts, note)"""
    if not path.exists():
        return (0, 0, 0, {}, "нет transcript.jsonl")
    raw = path.read_text(errors="replace")
    lines = [l.strip("\x00 \t\r\n") for l in raw.splitlines()]
    lines = [l for l in lines if l]
    recs = []
    for l in lines:
        try:
            recs.append(json.loads(l))
        except ValueError:
            pass
    shell_errors = raw.count("No suitable shell found")
    tools = {}
    for r in recs:
        msg = r.get("message")
        if not isinstance(msg, dict):
            continue
        for c in msg.get("content") or []:
            if isinstance(c, dict) and c.get("type") == "tool_use":
                tools[c.get("name")] = tools.get(c.get("name"), 0) + 1
    note = ""
    if not recs:
        note = "НЕЧИТАЕМ (0 валидных записей — вероятно NUL-заполнен)"
    elif len(recs) < 0.5 * len(lines):
        note = f"частично нечитаем ({len(recs)}/{len(lines)})"
    return (len(lines), len(recs), shell_errors, tools, note)


def resolve_loop(arg: str):
    p = Path(arg)
    if p.name.endswith(".loop.json") and p.exists():
        return p
    cand = Path(str(arg) + ".loop.json")
    return cand if cand.exists() else None


def gates_from_loop(loop):
    its = loop.get("iterations") or []
    if not its:
        return None
    g = (its[-1] or {}).get("gates")
    # gates может быть вложен как {"gates": {...}} или сразу {...}
    if isinstance(g, dict) and "gates" in g and isinstance(g["gates"], dict):
        g = g["gates"]
    return g if isinstance(g, dict) else None


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    adir = Path(sys.argv[1].rstrip("/"))
    loop = resolve_loop(sys.argv[2]) if len(sys.argv) > 2 else None
    loop_data = _load(loop) if loop else None

    parts = adir.parts
    lang = parts[parts.index("pilot-runs") + 1] if "pilot-runs" in parts else "?"
    ticket = next((p for p in parts if p.startswith("ticket-")), "?")
    sess = adir.name

    total, valid, sherr, tools, tnote = check_transcript(adir / "transcript.jsonl")
    result = _load(adir / "result.json") or {}
    timing = _load(adir / "timing-breakdown.json") or {}
    htiming = _load(adir / "harness-timing.json") or {}

    is_error = bool(result.get("is_error"))
    api_err = result.get("api_error_status")
    turns = result.get("num_turns")
    cost = result.get("total_cost_usd")
    warning = timing.get("warning")

    fails = []
    if tnote.startswith("НЕЧИТАЕМ") or (total and valid == 0):
        fails.append("транскрипт нечитаем")
    if sherr:
        fails.append(f"{sherr}× «No suitable shell found»")
    if is_error:
        fails.append("result.is_error=true")
    if api_err:
        fails.append(f"api_error_status={api_err}")

    outcome = None
    gates = None
    if loop_data:
        outcome = loop_data.get("outcome", "")
        if not outcome.startswith("сошл"):
            fails.append(f"loop: {outcome or '?'}")
        gates = gates_from_loop(loop_data)
        if gates:
            for k in ("tests", "contract"):
                st = (gates.get(k) or {}).get("status")
                if st and st != "pass":
                    fails.append(f"gate {k}={st}")

    verdict = "FAIL" if fails else ("WARN" if warning else "PASS")

    def s(ms):
        return f"{round(ms / 1000)}s" if isinstance(ms, (int, float)) else "?"

    print(f"{lang} {ticket} {sess[:8]}  {verdict}")
    tstr = f"{valid}/{total} JSON valid" + (f"  [{tnote}]" if tnote else "")
    print(f"  transcript   {tstr}   shell-errors {sherr}")
    if tools:
        print("  tools        " + "  ".join(f"{k} {v}" for k, v in sorted(tools.items())))
    if timing:
        w = timing.get("wall_ms")
        print(f"  timing       wall {s(w)}  model {s(timing.get('model_ms'))}  "
              f"tool {s(timing.get('tool_wall_ms'))}  infra {s(timing.get('infra_ms'))}  "
              f"work {s(timing.get('work_ms'))}"
              + (f"   container_wall {s(htiming.get('container_wall_ms'))}" if htiming else ""))
    cost_str = f"  ${cost:.2f}" if isinstance(cost, (int, float)) else ""
    print(f"  result       {'ERROR' if is_error else 'ok'}  turns {turns}{cost_str}"
          + (f"  api_err {api_err}" if api_err else ""))
    if outcome is not None:
        n_it = len(loop_data.get("iterations") or [])
        print(f"  loop         {outcome}  ({n_it} iter)")
    if gates:
        cells = []
        for k in ("tests", "smoke", "contract"):
            gv = gates.get(k) or {}
            st = gv.get("status", "?")
            extra = ""
            if k == "smoke" and gv.get("failed_steps"):
                nums = [re.match(r"(\d+)", x).group(1) for x in gv["failed_steps"] if re.match(r"\d+", x)]
                extra = f" {gv.get('passed')}/{gv.get('total')} [{','.join(nums)}]"
            cells.append(f"{k} {st.upper()}{extra}")
        print("  gates        " + "  ".join(cells))
    if warning:
        print(f"  ⚠ warning    {warning}")

    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
