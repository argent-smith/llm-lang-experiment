#!/usr/bin/env python3
"""Живой статус кампании run-pilot-replay.sh в виде статической HTML-страницы.

    scripts/campaign-status.py --html <file> [--out-root <dir>] [--watch <сек>]
        [--agterm-session <id> --agterm-socket <path> [--agterm-pane left|right]]

Читает только файлы кампании и ничего не меняет в ней:
  <out-root>/checkpoint.json                   — завершённые ячейки, паузы, стоп;
  <out-root>/<lang>/ticket-<N>.iterK.json      — идёт ли вызов модели (файл пуст);
  <out-root>/<lang>/ticket-<N>.iterK.gates/    — идут ли гейты / их результат;
  $TMPDIR/syncbox-claude-home.*/projects/*/*.jsonl — транскрипт текущего вызова.

Без --out-root берётся самая свежая pilot-runs-live/.replay-*. С --watch
страница пересобирается каждые N секунд; если заданы --agterm-*, после
каждой пересборки HTML-оверлей agterm перезагружается (страница без JS).
"""
import argparse
import glob
import html
import json
import os
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
e = html.escape


def load(p):
    try:
        return json.loads(Path(p).read_text())
    except (OSError, ValueError):
        return None


def mins(sec):
    sec = int(max(sec, 0))
    return f"{sec // 3600}ч {sec % 3600 // 60:02d}м" if sec >= 3600 else f"{sec // 60}м {sec % 60:02d}с"


def live_transcript():
    """Свежайший транскрипт идущего вызова: (число вызовов инструментов, последние действия)."""
    files = glob.glob(os.path.join(tempfile.gettempdir(), "syncbox-claude-home.*", "projects", "*", "*.jsonl"))
    if not files:
        return None
    path = max(files, key=os.path.getmtime)
    n, last = 0, []
    for line in open(path, errors="replace"):
        try:
            content = (json.loads(line).get("message") or {}).get("content")
        except ValueError:
            continue
        for b in content if isinstance(content, list) else []:
            if b.get("type") == "tool_use":
                n += 1
                i = b.get("input") or {}
                detail = i.get("description") or i.get("command") or i.get("file_path") or ""
                last.append((b.get("name", ""), " ".join(str(detail).replace("/workspace/", "").split())[:110]))
    return n, last[-6:], time.time() - os.path.getmtime(path)


def collect(out_root):
    ck = load(out_root / "checkpoint.json") or {}
    camp = ck.get("campaign") or {}
    langs = camp.get("languages") or sorted(p.name for p in out_root.iterdir() if p.is_dir())
    tickets = camp.get("tickets") or [str(i) for i in range(1, 12)]
    cells = {}
    for c in ck.get("cells", []):
        loop = load(c.get("loop_json", "")) or {}
        its = loop.get("iterations", [])
        cells[(c["lang"], str(c["ticket"]))] = dict(
            state="done" if c.get("status") == "converged" else "failed", status=c.get("status"),
            outcome=c.get("outcome", ""), cost=float(c.get("cost_usd") or 0), turns=int(c.get("num_turns") or 0),
            iters=len(its) or c.get("iters") or 1, sec=sum(int(i.get("duration_ms") or 0) for i in its) / 1000)
    running = None
    for lang in langs:
        for n in tickets:
            if (lang, n) in cells:
                continue
            its = sorted(glob.glob(str(out_root / lang / f"ticket-{n}.iter*.json")),
                         key=lambda p: int(p.rsplit(".iter", 1)[1].split(".")[0]))
            if not its:
                continue
            k = len(its)
            cur = Path(its[-1])
            st = cur.stat()
            gdir = out_root / lang / f"ticket-{n}.iter{k}.gates"
            if st.st_size == 0:
                phase, since = "модель работает", getattr(st, "st_birthtime", st.st_mtime)
            elif gdir.exists() and not (gdir / "gates.json").exists():
                phase, since = "идут проверки", st.st_mtime
            else:
                phase, since = "между итерациями", st.st_mtime
            prev = []
            for j in range(1, k + (0 if st.st_size == 0 else 1)):
                g = (load(out_root / lang / f"ticket-{n}.iter{j}.gates" / "gates.json") or {}).get("gates", {})
                r = load(out_root / lang / f"ticket-{n}.iter{j}.json") or {}
                prev.append(dict(j=j, cost=float(r.get("total_cost_usd") or 0), sec=int(r.get("duration_ms") or 0) / 1000,
                                 gates={x: g.get(x, {}).get("status", "?") for x in ("tests", "contract", "smoke")},
                                 fails=[f"{f['method']} {f['path']} → {f['received']}" for f in g.get("contract", {}).get("failures", [])]))
            running = dict(lang=lang, ticket=n, iter=k, phase=phase, since=since, prev=prev)
            cells[(lang, n)] = dict(state="running", iters=k)
    alive = subprocess.run(["pgrep", "-f", "run-pilot-replay.sh"], capture_output=True).returncode == 0
    return dict(ck=ck, langs=langs, tickets=tickets, cells=cells, running=running, alive=alive)


CSS = """
body{background:var(--agterm-background,Canvas);color:var(--agterm-foreground,CanvasText);font:13px/1.45 -apple-system,BlinkMacSystemFont,sans-serif;margin:0}
.page{--fg:var(--agterm-foreground,CanvasText);--ok:var(--agterm-color-2,#2e9e4f);--bad:var(--agterm-color-1,#d0443c);--run:var(--agterm-color-4,#2a78d6);--warn:var(--agterm-color-3,#c08a12);
--muted:color-mix(in srgb,var(--fg) 60%,transparent);--line:color-mix(in srgb,var(--fg) 15%,transparent);--panel:color-mix(in srgb,var(--fg) 5%,transparent);padding:16px 18px 30px;max-width:900px;margin:0 auto}
h1{font-size:17px;margin:0 0 2px} h2{font-size:13px;margin:20px 0 6px} .muted{color:var(--muted)} .small{font-size:11.5px}
.state{display:inline-block;border-radius:4px;padding:1px 8px;font-weight:600;border:1px solid var(--line)}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:6px;vertical-align:baseline}
.bar{height:8px;border-radius:4px;background:var(--panel);border:1px solid var(--line);overflow:hidden;margin:8px 0 4px} .bar i{display:block;height:100%;background:var(--ok)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:8px;margin:10px 0}
.tile{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:8px 10px} .tile b{display:block;font-size:19px;font-variant-numeric:tabular-nums;line-height:1.2}
table{border-collapse:collapse;width:100%;font-size:12px} th,td{padding:4px 8px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
th{color:var(--muted);font-weight:500} td.c{white-space:nowrap;font-variant-numeric:tabular-nums} .n{text-align:right;font-variant-numeric:tabular-nums}
.box{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:10px 12px} code{font:11.5px ui-monospace,Menlo,monospace}
.act{margin:2px 0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis} tr.sum td{font-weight:600}
"""
DOT = {"done": "ok", "failed": "bad", "running": "run", "paused": "warn"}


def render(d, out_root):
    ck, langs, tickets, cells, run = d["ck"], d["langs"], d["tickets"], d["cells"], d["running"]
    now = time.time()
    total = len(langs) * len(tickets)
    done = [c for c in cells.values() if c["state"] == "done"]
    failed = [c for c in cells.values() if c["state"] == "failed"]
    finished = len(done) + len(failed)
    started = datetime.fromisoformat(ck["started"]).timestamp() if ck.get("started") else None
    pauses = ck.get("pauses") or []
    if ck.get("stopped"):
        state, cls = "остановлена: " + str(ck["stopped"].get("reason", "")), "bad"
    elif finished == total and total:
        state, cls = "завершена", "ok"
    elif not d["alive"]:
        state, cls = "процесс кампании не запущен", "bad"
    elif not run and pauses and finished < total:
        state, cls = "пауза или переход между ячейками", "warn"
    else:
        state, cls = "идёт", "run"
    spent = sum(c.get("sec", 0) for c in done + failed)
    eta = (spent / finished) * (total - finished) if finished else None

    h = [f'<!doctype html><html lang="ru"><head><meta charset="utf-8"><title>Статус кампании</title><style>{CSS}</style></head><body><div class="page">']
    h.append(f'<h1>Кампания: {e(" · ".join(langs))}</h1>')
    h.append(f'<div class="muted small">{e(out_root.name)} · обновлено {datetime.now().strftime("%H:%M:%S")}</div>')
    h.append(f'<p><span class="state"><span class="dot" style="background:var(--{cls})"></span>{e(state)}</span></p>')
    h.append(f'<div class="bar"><i style="width:{finished / total * 100 if total else 0:.1f}%"></i></div>')
    h.append('<div class="tiles">')
    h.append(f'<div class="tile"><b>{finished} / {total}</b><span class="muted small">ячеек готово</span></div>')
    h.append(f'<div class="tile"><b>{len(failed)}</b><span class="muted small">не сошлось</span></div>')
    h.append(f'<div class="tile"><b>${sum(c.get("cost", 0) for c in done + failed):.2f}</b><span class="muted small">по ценам API</span></div>')
    h.append(f'<div class="tile"><b>{mins(now - started) if started else "—"}</b><span class="muted small">с запуска</span></div>')
    h.append(f'<div class="tile"><b>{"~" + mins(eta) if eta else "—"}</b><span class="muted small">осталось (оценка)</span></div>')
    h.append(f'<div class="tile"><b>{len(pauses)}</b><span class="muted small">пауз из-за лимита</span></div></div>')

    h.append("<h2>Сейчас</h2><div class='box'>")
    if run:
        h.append(f'<b>{e(run["lang"])} · тикет {e(run["ticket"])}</b> — итерация {run["iter"]}, {e(run["phase"])} {mins(now - run["since"])}')
        for p in run["prev"]:
            g = p["gates"]
            fails = (" — " + "; ".join(p["fails"])) if p["fails"] else ""
            h.append(f'<div class="small muted">итерация {p["j"]}: ${p["cost"]:.2f}, {mins(p["sec"])} · тесты {e(g["tests"])}, контракт {e(g["contract"])}, smoke {e(g["smoke"])}{e(fails)}</div>')
        tr = live_transcript() if run["phase"] == "модель работает" else None
        if tr:
            n, last, idle = tr
            h.append(f'<div class="small" style="margin-top:6px">вызовов инструментов: <b>{n}</b>, последняя запись {mins(idle)} назад</div>')
            h += [f'<div class="act small"><code>{e(name)}</code> <span class="muted">{e(det)}</span></div>' for name, det in last]
    else:
        h.append('<span class="muted">активной ячейки нет</span>')
    h.append("</div>")

    h.append("<h2>Ячейки</h2><table><tr><th>Тикет</th>" + "".join(f"<th>{e(l)}</th>" for l in langs) + "</tr>")
    for n in tickets:
        h.append(f"<tr><td>т{e(n)}</td>")
        for l in langs:
            c = cells.get((l, n))
            if not c:
                h.append('<td class="c muted">·</td>')
            elif c["state"] == "running":
                h.append(f'<td class="c"><span class="dot" style="background:var(--run)"></span>идёт, итерация {c["iters"]}</td>')
            else:
                mark = "готово" if c["state"] == "done" else e(c.get("status") or "не сошлось")
                it = f' · ×{c["iters"]}' if c["iters"] > 1 else ""
                h.append(f'<td class="c" title="{e(c.get("outcome", ""))}"><span class="dot" style="background:var(--{DOT[c["state"]]})"></span>{mark} · ${c["cost"]:.2f} · {mins(c["sec"])}{it}</td>')
        h.append("</tr>")
    h.append('<tr class="sum"><td>Σ</td>')
    for l in langs:
        cs = [c for (ll, _), c in cells.items() if ll == l and c["state"] != "running"]
        h.append(f'<td class="c">{len(cs)}/{len(tickets)} · ${sum(c["cost"] for c in cs):.2f} · {sum(c["turns"] for c in cs)} ходов · {mins(sum(c["sec"] for c in cs))}</td>')
    h.append("</tr></table>")
    h.append('<p class="muted small">×N — число вызовов модели на тикет. Время — сумма вызовов модели, без проверок между ними.</p>')

    if pauses:
        h.append("<h2>Паузы из-за лимита</h2><table>")
        for p in pauses:
            h.append(f'<tr><td>{e(str(p.get("lang")))} т{e(str(p.get("ticket")))}</td><td>замечено {e(str(p.get("detected_at", "")))}</td><td>до {e(str(p.get("reset_target") or "?"))}</td></tr>')
        h.append("</table>")
    h.append("</div></body></html>")
    return "".join(h)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--html", required=True)
    ap.add_argument("--out-root")
    ap.add_argument("--watch", type=int, default=0)
    ap.add_argument("--agterm-session")
    ap.add_argument("--agterm-socket")
    ap.add_argument("--agterm-pane")
    args = ap.parse_args()
    while True:
        roots = [Path(args.out_root)] if args.out_root else sorted((REPO_ROOT / "pilot-runs-live").glob(".replay-*"))
        if roots and roots[-1].is_dir():
            page = render(collect(roots[-1]), roots[-1])
            tmp = args.html + ".tmp"
            Path(tmp).write_text(page)
            os.replace(tmp, args.html)
            if args.agterm_session and args.agterm_socket:
                cmd = ["agtermctl", "session", "overlay", "reload", "--target", args.agterm_session, "--socket", args.agterm_socket]
                if args.agterm_pane:
                    cmd += ["--pane", args.agterm_pane]
                subprocess.run(cmd, capture_output=True)
        if not args.watch:
            return
        time.sleep(args.watch)


if __name__ == "__main__":
    main()
