#!/usr/bin/env python3
"""Сводный HTML-отчёт: основная кампания (Sonnet 5, четыре языка) и кампании
Opus 5.5 (Python, JavaScript, TypeScript, Ruby 3.3.12, Ruby 4.0.7).

    scripts/make-opus-report.py [--out docs/opus-langs/report.html]

Данные основной кампании берутся из архива docs/pilot-runs/ (канон из
manifest.json плюс первая итерация тикета 1 реплей-кампании) и сверяются с
итогами из docs/PILOT-COMPARISON-talk-languages.md. Данные кампаний Opus —
из чекпойнтов pilot-runs-live/.replay-*/ и архива. Страница статическая,
без JS; цвета — из темы терминала agterm с запасными значениями.
"""
import argparse
import glob
import html
import json
import os
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
os.chdir(REPO)
TICKETS = [str(i) for i in range(1, 12)]
e = html.escape
num = lambda v: f"{v:,.0f}".replace(",", " ")

# Итоги из отчёта автора — для сверки реконструкции: ($, ходы).
AUTHOR_TOTALS = {"python": (16.42, 423), "javascript": (16.24, 469), "typescript": (18.60, 501), "ruby": (15.22, 451)}
AUTHOR_T1 = {"python": 6.08, "javascript": 2.73, "typescript": 2.69, "ruby": 3.94}


def sess(d):
    d = str(d).rstrip("/")
    r = json.load(open(f"{d}/result.json"))
    u = r.get("usage") or {}
    ht = json.load(open(f"{d}/harness-timing.json")) if os.path.exists(f"{d}/harness-timing.json") else {}
    tb = json.load(open(f"{d}/timing-breakdown.json")) if os.path.exists(f"{d}/timing-breakdown.json") else {}
    turns = r.get("num_turns", 0)
    tools, monitor = 0, False
    mix = dict(bash=0, edit=0, read=0, write=0, docker=0, curl=0, bg=0)
    if os.path.exists(f"{d}/transcript.jsonl"):
        for line in open(f"{d}/transcript.jsonl", errors="replace"):
            try:
                x = json.loads(line)
            except ValueError:
                continue
            c = (x.get("message") or {}).get("content")
            if x.get("type") == "assistant" and isinstance(c, list):
                for b in c:
                    if b.get("type") == "tool_use":
                        tools += 1
                        monitor = monitor or b.get("name") == "Monitor"
                        nm = b.get("name")
                        if nm == "Bash":
                            mix["bash"] += 1
                            cmd = (b.get("input") or {}).get("command", "")
                            mix["docker"] += 1 if re.search(r"\bdocker\b|run-server|run-tests|run-client", cmd) else 0
                            mix["curl"] += 1 if re.search(r"\bcurl\b|wget\b", cmd) else 0
                            mix["bg"] += 1 if (b.get("input") or {}).get("run_in_background") else 0
                        elif nm in ("Edit", "Read", "Write"):
                            mix[nm.lower()] += 1
    # num_turns = вызовы инструментов + 1; после фонового ожидания (Monitor)
    # result.json считает только последний отрезок сессии — берём транскрипт.
    fixed = tools + 1 > turns
    return dict(cost=r.get("total_cost_usd", 0), turns=max(turns, tools + 1) if tools else turns,
                wall=(ht.get("container_wall_ms") or r.get("duration_ms", 0)) / 60000,
                model=tb.get("model_ms", 0) / 60000, infra=tb.get("infra_ms", 0) / 60000, work=tb.get("work_ms", 0) / 60000,
                tin=u.get("input_tokens", 0), cw=u.get("cache_creation_input_tokens", 0),
                cr=u.get("cache_read_input_tokens", 0), out=u.get("output_tokens", 0), fixed=int(fixed), **mix)


def agg(ss):
    o = {k: sum(s[k] for s in ss) for k in ss[0]}
    o["iters"] = len(ss)
    return o


SRC_EXT = (".rb", ".py", ".js", ".mjs", ".cjs", ".ts")
TEST_RE = re.compile(r"(^|/)(tests?|spec|__tests__)/|(^|/)test_[^/]*\.py$|[._](test|spec)\.[cm]?[jt]s$|_test\.(py|rb)$|_spec\.rb$")
SKIP_RE = re.compile(r"(^|/)(node_modules|dist|build|\.venv|__pycache__|\.git)/")


def codestats(code):
    files = [f for f in glob.glob(code + "/**/*", recursive=True) if os.path.isfile(f)]
    rel = {f: f[len(code) + 1:] for f in files}
    files = [f for f in files if not SKIP_RE.search(rel[f])]
    loc = lambda fs: sum(sum(1 for l in open(f, errors="replace") if l.strip()) for f in fs)
    code_files = [f for f in files if f.endswith(SRC_EXT) or re.search(r"(^|/)(bin|exe)/[^/.]+$", rel[f])]
    test = [f for f in code_files if TEST_RE.search(rel[f])]
    src = [f for f in code_files if f not in test]
    deps = []
    for f in files:
        name = os.path.basename(f)
        txt = open(f, errors="replace").read()
        if name == "Gemfile":
            deps += re.findall(r"^\s*gem\s+[\"']([^\"']+)", txt, re.M)
        elif re.fullmatch(r"requirements.*\.txt", name):
            deps += [re.split(r"[<>=~!\[ ]", l.strip())[0] for l in txt.splitlines() if l.strip() and not l.startswith(("#", "-"))]
        elif name == "package.json":
            p = json.loads(txt)
            deps += list((p.get("dependencies") or {})) + list((p.get("devDependencies") or {}))
    frm = sorted({l.split()[1] for f in files if os.path.basename(f).startswith("Dockerfile")
                  for l in open(f) if l.startswith("FROM") and ":" in l.split()[1]})
    return dict(src=loc(src), test=loc(test), nsrc=len(src), ntest=len(test),
                deps=sorted(set(d.lower() for d in deps if d)), image=", ".join(frm))


def ntests(log):
    try:
        t = open(log, errors="replace").read()
    except OSError:
        return None
    for pat in (r"(\d+) runs,", r"(\d+) passed", r"tests (\d+)", r"(\d+) examples"):
        m = re.findall(pat, t)
        if m:
            return int(m[-1])
    return None


def opus_run(lang):
    roots = [r for r in sorted(glob.glob("pilot-runs-live/.replay-*")) if os.path.exists(f"{r}/checkpoint.json")
             and lang in (json.load(open(f"{r}/checkpoint.json")).get("campaign") or {}).get("languages", [])]
    root = roots[-1]
    ck = json.load(open(f"{root}/checkpoint.json"))
    T = {}
    for c in ck["cells"]:
        if c["lang"] != lang:
            continue
        n = str(c["ticket"])
        L = json.load(open(c["loop_json"]))
        a = agg([sess(f"docs/pilot-runs/{lang}/ticket-{n}/{it['session']}") for it in L["iterations"]])
        g = [(it.get("gates") or {}).get("gates") or {} for it in L["iterations"]]
        sm = g[-1].get("smoke", {})
        a["smoke"] = "—" if sm.get("status") in (None, "skip") else f"{sm.get('passed', 0)}/{sm.get('total', 0)}"
        a["why"] = ""
        if len(g) > 1:
            fails = [f"{f['method']} {f['path']} → {f['received']}" for f in g[0].get("contract", {}).get("failures", [])]
            a["why"] = "контракт: " + "; ".join(fails) if fails else "штатные тесты не прошли"
        a["ntests"] = ntests(f"{root}/{lang}/ticket-{n}.iter{len(g)}.gates/gate-tests.log")
        a["last"] = L["iterations"][-1]["session"]
        a["code"] = codestats(f"docs/pilot-runs/{lang}/ticket-{n}/{a['last']}/code")
        T[n] = a
    return dict(t=T, code=codestats(f"docs/pilot-runs/{lang}/ticket-11/{T['11']['last']}/code"), pauses=len(ck.get("pauses") or []))


def sonnet_run(lang):
    man = json.load(open("docs/pilot-runs/manifest.json"))["languages"][lang]["tickets"]
    T = {}
    for n in TICKETS:
        ds = [man[n]]
        if n == "1":  # первая итерация реплея: её цена + цена канона = цена тикета 1 в отчёте автора
            cc = json.load(open(man[n] + "/result.json"))["total_cost_usd"]
            for d in glob.glob(f"docs/pilot-runs/{lang}/ticket-1/*/"):
                d = d.rstrip("/")
                if d != man[n] and os.path.exists(d + "/result.json") and \
                        abs(json.load(open(d + "/result.json"))["total_cost_usd"] + cc - AUTHOR_T1[lang]) < 0.006:
                    ds = [d] + ds
        T[n] = agg([sess(d) for d in ds])
        T[n]["code"] = codestats(man[n] + "/code")
    cost, turns = sum(t["cost"] for t in T.values()), sum(t["turns"] for t in T.values())
    exp = AUTHOR_TOTALS[lang]
    if abs(cost - exp[0]) > 0.02 or turns != exp[1]:
        sys.exit(f"реконструкция {lang} не сходится с отчётом автора: ${cost:.2f}/{turns} против ${exp[0]}/{exp[1]}")
    return dict(t=T, code=codestats(man["11"] + "/code"), pauses=None)


# ключ, язык, модель, подпись версии, css-класс, группа
RUNS = [
    ("py-s", "Python", "Sonnet 5", "", "s", lambda: sonnet_run("python")),
    ("py-o", "Python", "Opus 5.5", "", "o", lambda: opus_run("python-opus")),
    ("js-s", "JavaScript", "Sonnet 5", "", "s", lambda: sonnet_run("javascript")),
    ("js-o", "JavaScript", "Opus 5.5", "", "o", lambda: opus_run("javascript-opus")),
    ("ts-s", "TypeScript", "Sonnet 5", "", "s", lambda: sonnet_run("typescript")),
    ("ts-o", "TypeScript", "Opus 5.5", "", "o", lambda: opus_run("typescript-opus")),
    ("rb-s", "Ruby", "Sonnet 5", "3.3", "s", lambda: sonnet_run("ruby")),
    ("rb3-o", "Ruby", "Opus 5.5", "3.3.12", "o", lambda: opus_run("ruby3-opus")),
    ("rb4-o", "Ruby", "Opus 5.5", "4.0.7", "o4", lambda: opus_run("ruby4-opus")),
    ("rb3-f", "Ruby", "Fable 5.1", "3.3.12", "f", lambda: opus_run("ruby3-fable")),
    ("rb4-f", "Ruby", "Fable 5.1", "4.0.7", "f4", lambda: opus_run("ruby4-fable")),
]
D = {k: f() for k, *_, f in RUNS}
META = {k: dict(lang=l, model=m, ver=v, cls=c) for k, l, m, v, c, _ in RUNS}
tot = lambda k, f: sum(x[f] for x in D[k]["t"].values())
name = lambda k: META[k]["lang"] + (f" {META[k]['ver']}" if META[k]["ver"] else "")
full = lambda k: f"{name(k)} · {META[k]['model']}"
SONNET4 = ["py-s", "js-s", "ts-s", "rb-s"]
OPUS4 = ["py-o", "js-o", "ts-o", "rb3-o"]
OPUS5 = OPUS4 + ["rb4-o"]
FABLE = ["rb3-f", "rb4-f"]
OURS = OPUS5 + FABLE
RUBY3 = ["rb-s", "rb3-o", "rb3-f"]
RUBY4 = ["rb4-o", "rb4-f"]
PAIRS = [("py-s", "py-o"), ("js-s", "js-o"), ("ts-s", "ts-o"), ("rb-s", "rb3-o")]


def ranks(keys, field):
    out = {k: [] for k in keys}
    for n in TICKETS:
        vals = sorted(D[k]["t"][n][field] for k in keys)
        for k in keys:
            v = D[k]["t"][n][field]
            out[k].append(sum(i + 1 for i, x in enumerate(vals) if x == v) / vals.count(v))
    return {k: sum(v) / len(v) for k, v in out.items()}, {k: sum(1 for r in v if r == 1) for k, v in out.items()}


def hbars(title, field, fmt, note=""):
    mx = max(tot(k, field) for k in D)
    out = [f'<div class="card"><h3>{e(title)}</h3>']
    prev = None
    for k in D:
        v = tot(k, field)
        gap = ' style="margin-top:12px"' if prev and prev != META[k]["lang"] else ""
        prev = META[k]["lang"]
        out.append(f'<div class="hb"{gap} title="{e(full(k))}: {fmt(v)}"><span class="hl">{e(name(k))}<i>{META[k]["model"]}</i></span>'
                   f'<span class="ht"><span class="hf {META[k]["cls"]}" style="width:{v / mx * 100:.1f}%"></span></span>'
                   f'<span class="hv">{fmt(v)}</span></div>')
    if note:
        out.append(f'<p class="note">{note}</p>')
    return "".join(out) + "</div>"


def grouped(title, keys, field, fmt, top, step):
    W, H, L, B, TOP = 560, 200, 34, 24, 14
    ph = H - B - TOP
    gw = (W - L) / 11
    bw = gw * (0.6 / len(keys))
    s = [f'<div class="card"><h3>{e(title)}</h3><svg viewBox="0 0 {W} {H}" role="img" aria-label="{e(title)}">']
    v = 0
    while v <= top + 1e-9:
        y = TOP + ph - v / top * ph
        s.append(f'<line class="grid" x1="{L}" x2="{W}" y1="{y:.1f}" y2="{y:.1f}"/><text class="ax" x="{L - 5}" y="{y + 3.5:.1f}" text-anchor="end">{fmt(v)}</text>')
        v += step
    for n in range(1, 12):
        x0 = L + (n - 1) * gw + gw * 0.17
        for i, k in enumerate(keys):
            t = D[k]["t"][str(n)]
            h = max(min(t[field], top) / top * ph, 1.5)
            x = x0 + i * (bw + 2)
            s.append(f'<path class="{META[k]["cls"]}" d="M{x:.1f},{TOP + ph} v{-(h - 2):.1f} q0,-2 2,-2 h{bw - 4:.1f} q2,0 2,2 v{h - 2:.1f} z">'
                     f'<title>Тикет {n} · {e(full(k))}: {fmt(t[field])}, вызовов модели: {t["iters"]}</title></path>')
            if t["iters"] > 1:
                s.append(f'<text class="it" x="{x + bw / 2:.1f}" y="{TOP + ph - h - 3:.1f}" text-anchor="middle">×{t["iters"]}</text>')
        s.append(f'<text class="ax" x="{L + (n - 0.5) * gw:.1f}" y="{H - 7}" text-anchor="middle">т{n}</text>')
    s.append(f'<line class="base" x1="{L}" x2="{W}" y1="{TOP + ph}" y2="{TOP + ph}"/></svg></div>')
    return "".join(s)


sw = lambda k: f'<b class="sw {META[k]["cls"]}"></b>'
legend = ('<div class="legend"><span><b class="sw s"></b>Sonnet 5, effort xhigh (кампания автора)</span>'
          '<span><b class="sw o"></b>Opus 5.5, effort high</span><span><b class="sw o4"></b>Opus 5.5 на Ruby 4.0.7</span>'
          '<span><b class="sw f"></b>Fable 5.1, effort high</span><span><b class="sw f4"></b>Fable 5.1 на Ruby 4.0.7</span></div>')

tot_rows = "".join(
    f'<tr><td>{sw(k)}{e(name(k))}</td><td>{META[k]["model"]}</td><td class="n">{tot(k, "cost"):.2f}</td><td class="n">{tot(k, "turns")}</td>'
    f'<td class="n">{tot(k, "wall"):.1f}</td><td class="n">{tot(k, "model"):.1f} / {tot(k, "infra"):.1f} / {tot(k, "work"):.1f}</td>'
    f'<td class="n">{num(tot(k, "tin"))}</td><td class="n">{num(tot(k, "cw"))}</td><td class="n">{num(tot(k, "cr"))}</td><td class="n">{num(tot(k, "out"))}</td></tr>'
    for k in D)

ratio_rows = "".join(
    f'<tr><td>{sw(o)}{e(full(o))} к {e(full(s))}</td>' + "".join(f'<td class="n">×{tot(o, f) / tot(s, f):.2f}</td>' for f in ("cost", "turns", "out", "cr", "wall", "model", "work")) + "</tr>"
    for s, o in PAIRS + [("rb-s", "rb3-f"), ("rb3-o", "rb3-f"), ("rb3-o", "rb4-o"), ("rb3-f", "rb4-f")])


def rel_table(keys, title):
    base = keys[0]
    rows = "".join(f'<tr><td>{lab}</td>' + "".join(f'<td class="n">×{tot(k, f) / tot(base, f):.2f}</td>' for k in keys[1:]) + "</tr>"
                   for lab, f in (("$", "cost"), ("Ходы", "turns"), ("out-токены", "out"), ("Время", "wall")))
    return (f'<div class="card"><h3>{e(title)}</h3><table><tr><th>Метрика</th>' +
            "".join(f'<th class="n">{e(name(k))}</th>' for k in keys[1:]) + f"</tr>{rows}</table></div>")


def rank_table(keys, title):
    ro, wo = ranks(keys, "out")
    rt, _ = ranks(keys, "turns")
    rc, _ = ranks(keys, "cost")
    row = lambda lab, r, f: f"<tr><td>{lab}</td>" + "".join(f'<td class="n">{f(r[k])}</td>' for k in keys) + "</tr>"
    return (f'<div class="card"><h3>{e(title)}</h3><table><tr><th>Средний ранг (1 — меньше всех)</th>' +
            "".join(f'<th class="n">{e(name(k))}</th>' for k in keys) + "</tr>" +
            row("по out-токенам", ro, lambda v: f"{v:.2f}") + row("по ходам", rt, lambda v: f"{v:.2f}") +
            row("по $", rc, lambda v: f"{v:.2f}") + row("побед по out-токенам", wo, str) + "</table></div>")


def grid_table(keys):
    head = "<tr><th>Тикет</th>" + "".join(f'<th class="n">{e(full(k))}</th>' for k in keys) + "</tr>"
    rows = ""
    for n in TICKETS:
        rows += f"<tr><td>т{n}</td>"
        for k in keys:
            t = D[k]["t"][n]
            it = f' <span class="tag">×{t["iters"]}</span>' if t["iters"] > 1 else ""
            rows += f'<td class="n">${t["cost"]:.2f} · {t["turns"]}т · {t["wall"]:.1f}м{it}</td>'
        rows += "</tr>"
    rows += '<tr class="sum"><td>Σ</td>' + "".join(
        f'<td class="n">${tot(k, "cost"):.2f} · {tot(k, "turns")}т · {tot(k, "wall"):.1f}м</td>' for k in keys) + "</tr>"
    return f'<div class="tw"><table>{head}{rows}</table></div>'


conv_rows = ""
for k in D:
    t = D[k]["t"]
    multi = [n for n in TICKETS if t[n]["iters"] > 1]
    why = "; ".join(f"т{n}: {t[n].get('why') or 'контракт на первом тикете'}" for n in multi)
    smoke = t["11"].get("smoke", "4/13 локально, 13/13 в CI")
    nt = t["11"].get("ntests")
    p = D[k]["pauses"]
    conv_rows += (f'<tr><td>{sw(k)}{e(full(k))}</td><td class="n">11/11</td><td class="n">{sum(x["iters"] for x in t.values())}</td>'
                  f'<td>{e(why)}</td><td class="n">{e(smoke)}</td><td class="n">{nt if nt else "—"}</td></tr>')

code_rows = "".join(
    f'<tr><td>{sw(k)}{e(full(k))}</td><td><code>{e(D[k]["code"]["image"])}</code></td><td class="n">{num(D[k]["code"]["src"])}</td>'
    f'<td class="n">{num(D[k]["code"]["test"])}</td><td class="n">{D[k]["code"]["test"] / max(D[k]["code"]["src"], 1):.1f}</td>'
    f'<td>{e(", ".join(D[k]["code"]["deps"]) or "нет")}</td></tr>' for k in D)

def md_to_html(text):
    """Минимальный markdown -> HTML: заголовки, таблицы, списки, абзацы, **жирный**, `код`."""
    def inline(t):
        t = e(t)
        t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
        t = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", t)
        return t
    out, para, table, lst = [], [], [], None
    def flush():
        nonlocal para, table, lst
        if para:
            out.append("<p>" + inline(" ".join(para)) + "</p>"); para = []
        if table:
            rows = [r for r in table if not re.match(r"^\|?\s*:?-{2,}", r)]
            cells = [[c.strip() for c in r.strip().strip("|").split("|")] for r in rows]
            if cells:
                out.append('<div class="tw"><table><tr>' + "".join(f"<th>{inline(c)}</th>" for c in cells[0]) + "</tr>" +
                           "".join("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>" for r in cells[1:]) + "</table></div>")
            table = []
        if lst:
            out.append(f"<{lst[0]}>" + "".join(f"<li>{inline(i)}</li>" for i in lst[1]) + f"</{lst[0]}>"); lst = None
    for line in text.splitlines():
        if line.startswith("|"):
            if para or lst: flush()
            table.append(line); continue
        m = re.match(r"^(#{1,4})\s+(.*)", line)
        if m:
            flush(); lvl = min(len(m.group(1)) + 2, 4)
            out.append(f"<h{lvl}>{inline(m.group(2))}</h{lvl}>"); continue
        m = re.match(r"^\s*(?:[-*]|\d+[.)])\s+(.*)", line)
        if m:
            if para or table: flush()
            kind = "ol" if re.match(r"^\s*\d", line) else "ul"
            if lst and lst[0] != kind: flush()
            lst = lst or (kind, []); lst[1].append(m.group(1)); continue
        if not line.strip():
            flush(); continue
        if table or lst: flush()
        para.append(line.strip())
    flush()
    return "\n".join(out)


IMPL_MD = REPO / "docs/fable-ruby/IMPLEMENTATION-COMPARISON.md"
impl_html = md_to_html(IMPL_MD.read_text()) if IMPL_MD.exists() else "<p class='note'>Файл docs/fable-ruby/IMPLEMENTATION-COMPARISON.md не найден.</p>"


def loc_table(keys):
    head = "<tr><th>Тикет</th>" + "".join(f'<th class="n" colspan="2">{e(full(k))}</th>' for k in keys) + "</tr><tr><th></th>" + \
        "".join('<th class="n">код</th><th class="n">тесты</th>' for _ in keys) + "</tr>"
    rows = ""
    for n in TICKETS:
        rows += f"<tr><td>т{n}</td>" + "".join(
            f'<td class="n">{num(D[k]["t"][n]["code"]["src"])}</td><td class="n">{num(D[k]["t"][n]["code"]["test"])}</td>' for k in keys) + "</tr>"
    return f'<div class="tw"><table>{head}{rows}</table></div>'


def mix_table(keys):
    cols = [("bash", "Bash"), ("edit", "Edit"), ("read", "Read"), ("write", "Write"), ("docker", "из них Docker / run-*"), ("curl", "curl"), ("bg", "фоновые команды")]
    head = "<tr><th>Прогон</th>" + "".join(f'<th class="n">{c}</th>' for _, c in cols) + '<th class="n">правок на вызов Bash</th></tr>'
    rows = ""
    for k in keys:
        t = D[k]["t"]
        v = {c: sum(t[n][c] for n in TICKETS) for c, _ in cols}
        rows += f"<tr><td>{sw(k)}{e(full(k))}</td>" + "".join(f'<td class="n">{v[c]}</td>' for c, _ in cols) + \
            f'<td class="n">{(v["edit"] + v["write"]) / max(v["bash"], 1):.2f}</td></tr>'
    return f'<div class="tw"><table>{head}{rows}</table></div>'


o_cost = sum(tot(k, "cost") for k in OPUS5)
f_cost = sum(tot(k, "cost") for k in FABLE)
s_cost = sum(tot(k, "cost") for k in SONNET4)
ro_s, _ = ranks(SONNET4, "out")
ro_o, _ = ranks(OPUS4, "out")
cheapest = lambda keys: min(keys, key=lambda k: tot(k, "cost"))
priciest = lambda keys: max(keys, key=lambda k: tot(k, "cost"))
top_cost = int(max(D[k]["t"][n]["cost"] for k in D for n in TICKETS) / 2 + 1) * 2
top_turns = int(max(D[k]["t"][n]["turns"] for k in D for n in TICKETS) / 20 + 1) * 20
fixed_cells = [f"{full(k)}, тикет {n}" for k in D for n in TICKETS if D[k]["t"][n].get("fixed")]

PAGE = f"""<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Syncbox: Sonnet 5 и Opus 5.5</title><style>
body{{background:var(--agterm-background,Canvas);color:var(--agterm-foreground,CanvasText);font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;margin:0}}
.page{{--fg:var(--agterm-foreground,CanvasText);--s:var(--agterm-color-4,#2a78d6);--o:var(--agterm-color-5,#a44fc4);--o4:var(--agterm-color-3,#c08a12);--f:var(--agterm-color-6,#1a8f9c);--f4:var(--agterm-color-14,#4fb3bf);
--muted:color-mix(in srgb,var(--fg) 62%,transparent);--line:color-mix(in srgb,var(--fg) 15%,transparent);--panel:color-mix(in srgb,var(--fg) 5%,transparent);
max-width:1180px;margin:0 auto;padding:28px 24px 60px}}
h1{{font-size:24px;margin:0 0 4px;line-height:1.25}} h2{{font-size:17px;margin:38px 0 6px;padding-top:18px;border-top:1px solid var(--line)}} h3{{font-size:13px;margin:0 0 10px;font-weight:600}}
p{{margin:6px 0;max-width:88ch}} .sub,.note{{color:var(--muted)}} .note{{font-size:12px;margin-top:8px}} code{{font:12px ui-monospace,Menlo,monospace}}
.tiles{{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin:18px 0}}
.tile,.card{{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:14px 16px}}
.tile b{{display:block;font-size:26px;line-height:1.15;font-variant-numeric:tabular-nums}} .tile span{{color:var(--muted);font-size:12px}}
.grid2{{display:grid;grid-template-columns:repeat(auto-fit,minmax(420px,1fr));gap:12px;margin:10px 0}}
.hb{{display:grid;grid-template-columns:130px 1fr 76px;gap:10px;align-items:center;margin:4px 0}} .hl i{{display:block;font-style:normal;font-size:11px;color:var(--muted);line-height:1.1}}
.ht{{height:12px}} .hf{{display:block;height:12px;border-radius:0 4px 4px 0;min-width:2px}} .hv{{text-align:right;font-variant-numeric:tabular-nums}}
.s{{background:var(--s);fill:var(--s)}} .o{{background:var(--o);fill:var(--o)}} .o4{{background:var(--o4);fill:var(--o4)}} .f{{background:var(--f);fill:var(--f)}} .f4{{background:var(--f4);fill:var(--f4)}}
.legend{{display:flex;flex-wrap:wrap;gap:6px 18px;margin:12px 0;font-size:12px}} .sw{{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:6px}}
svg{{width:100%;height:auto;display:block}} .grid{{stroke:var(--line);stroke-width:1}} .base{{stroke:var(--muted);stroke-width:1}} .ax{{fill:var(--muted);font-size:10px}} .it{{fill:var(--fg);font-size:9px}}
svg path:hover{{opacity:.75}}
.tw{{overflow-x:auto;margin:10px 0}} table{{border-collapse:collapse;width:100%;font-size:12.5px}} th,td{{padding:5px 9px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}}
th{{color:var(--muted);font-weight:500}} td.n,th.n{{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}}
tr.sum td{{font-weight:600;border-top:1px solid var(--muted)}} .tag{{font-size:10px;border:1px solid var(--line);border-radius:3px;padding:0 3px;color:var(--muted)}}
ul{{margin:6px 0;padding-left:20px;max-width:88ch}} li{{margin:3px 0}}
</style></head><body><div class="page">
<h1>Syncbox: Sonnet 5 у автора, Opus 5.5 и Fable 5.1 у нас</h1>
<p class="sub">Эксперимент llm-lang-experiment: один проект, 11 тикетов с нуля на каждом языке, цикл «реализация → проверки → исправление». Кампания автора — 4–6 сентября 2026 (Sonnet 5, effort xhigh). Наши кампании: 3–4 октября 2026 — Opus 5.5 (effort high) на Ruby 3.3.12 и 4.0.7, затем на Python, JavaScript и TypeScript; 6 октября — Fable 5.1 (effort high) на Ruby 3.3.12 и 4.0.7.</p>

<div class="tiles">
<div class="tile"><b>{11 * len(OURS)} / {11 * len(OURS)}</b><span>ячеек сошлось у нас: 5 прогонов Opus 5.5 и 2 прогона Fable 5.1; у автора на Sonnet 5 — 44 / 44</span></div>
<div class="tile"><b>${o_cost:.2f} · ${f_cost:.2f}</b><span>Opus 5.5 (5 прогонов) · Fable 5.1 (2 прогона) по ценам API; Sonnet 5 у автора — ${s_cost:.2f}</span></div>
<div class="tile"><b>{e(name(cheapest(OPUS4)))}</b><span>самый дешёвый язык на Opus 5.5 (${tot(cheapest(OPUS4), "cost"):.2f}); у автора на Sonnet 5 — {e(name(cheapest(SONNET4)))} (${tot(cheapest(SONNET4), "cost"):.2f})</span></div>
<div class="tile"><b>{e(name(cheapest(RUBY3)))}: ${tot(cheapest(RUBY3), "cost"):.2f}</b><span>Ruby 3 дешевле всего на {e(META[cheapest(RUBY3)]["model"])}; Fable 5.1 — ${tot("rb3-f", "cost"):.2f}, в {tot("rb3-f", "cost") / tot("rb3-o", "cost"):.1f} раза дороже Opus 5.5</span></div>
</div>
<p>На всех трёх моделях агент закрыл весь бэклог, так что различия — только в цене успеха и в том, как написан код (см. раздел «Реализация»). На Ruby 3 Fable 5.1 обошёлся в {tot("rb3-f", "cost") / tot("rb3-o", "cost"):.1f} раза дороже Opus 5.5 при сопоставимом числе ходов ({tot("rb3-f", "turns")} против {tot("rb3-o", "turns")}) и написал ещё больше кода и тестов. На Opus 5.5 порядок языков по стоимости: {", ".join(f"{e(name(k))} ${tot(k, 'cost'):.2f}" for k in sorted(OPUS4, key=lambda k: tot(k, "cost")))}. У автора на Sonnet 5: {", ".join(f"{e(name(k))} ${tot(k, 'cost'):.2f}" for k in sorted(SONNET4, key=lambda k: tot(k, "cost")))}. Это по одному прогону на ячейку (n = 1): наблюдения, а не выводы.</p>

<h2>Конфигурация</h2>
<div class="tw"><table><tr><th></th><th>Кампания автора</th><th>Наши кампании</th></tr>
<tr><td>Модель / effort</td><td><code>claude-sonnet-5</code> / xhigh</td><td><code>claude-opus-5-5</code> / high (четыре языка и Ruby 4); <code>claude-fable-5-1</code> / high (Ruby 3 и Ruby 4, промпты побайтно те же)</td></tr>
<tr><td>Claude Code в харнессе</td><td>2.1.238</td><td>2.1.288 (новые модели требуют от 2.1.280)</td></tr>
<tr><td>Версии и образы</td><td>в промпте не заданы; агент выбрал <code>python:3.12-slim</code>, <code>node:20-alpine</code>, <code>node:20-bookworm-slim</code>, <code>ruby:3.3</code></td><td>те же образы закреплены абзацем в конце каждого промпта; Ruby — точно <code>ruby:3.3.12</code>, плюс отдельный прогон на <code>ruby:4.0.7</code></td></tr>
<tr><td>Предзагрузка образов</td><td>для Node 20 и Ruby образ скачивался во время прогона</td><td>все образы предзагружены</td></tr>
<tr><td>Веб-инструменты агента</td><td>открыты (репозиторий был приватным)</td><td>WebFetch и WebSearch закрыты; сеть контейнера открыта, проверено по транскриптам</td></tr>
<tr><td>Проверки</td><td colspan="2">штатные тесты и контрактный тест блокирующие, smoke информационный; до 4 вызовов модели на тикет</td></tr>
</table></div>

<h2>Итоги по 11 тикетам</h2>
{legend}
<div class="grid2">
{hbars("Стоимость по ценам API, $", "cost", lambda v: f"{v:.2f}", "Цена токена: Sonnet 5 — $2/$10, Opus 5.5 — $4/$20, Fable 5.1 — $10/$50 за 1M входных/выходных. На подписке стоимость условная.")}
{hbars("Ходы модели", "turns", lambda v: f"{v:.0f}")}
{hbars("Выходные токены", "out", num)}
{hbars("Время, минуты", "wall", lambda v: f"{v:.1f}", "Полное время всех вызовов модели по тикету. В отчёте автора суммы времени меньше: по тикету 1 он учитывал только последнюю итерацию.")}
</div>
<div class="tw"><table><tr><th>Язык</th><th>Модель</th><th class="n">$</th><th class="n">Ходы</th><th class="n">Время, мин</th><th class="n">модель / инфра / работа, мин</th><th class="n">in</th><th class="n">cache-write</th><th class="n">cache-read</th><th class="n">out</th></tr>
{tot_rows}</table></div>
<p class="note">«Модель / инфра / работа» — разбивка времени по транскрипту: генерация модели, загрузка образов и зависимостей, сборка и тесты.</p>

<h3 style="margin-top:20px">Отношения между прогонами на одном языке</h3>
<div class="tw"><table><tr><th></th><th class="n">$</th><th class="n">Ходы</th><th class="n">out-токены</th><th class="n">cache-read</th><th class="n">Время</th><th class="n">время модели</th><th class="n">время работы</th></tr>{ratio_rows}</table></div>

<h2>Эффект языка: сравнение внутри каждой модели</h2>
<p>Гипотеза автора: агенту легче на Python и JavaScript/TypeScript, чем на Ruby. Ниже те же срезы, что в отчёте автора, посчитанные для обеих моделей.</p>
<div class="grid2">
{rel_table(SONNET4, "Sonnet 5: относительно Python")}
{rel_table(OPUS4, "Opus 5.5: относительно Python")}
{rank_table(SONNET4, "Sonnet 5: ранги по тикетам")}
{rank_table(OPUS4, "Opus 5.5: ранги по тикетам")}
</div>
<p class="note">Ранг — место языка внутри одного тикета, усреднённое по 11 тикетам. Для Opus 5.5 в сетке участвует Ruby 3.3.12. Ранги Sonnet 5 по out-токенам совпадают с опубликованными автором; по ходам расходятся в сотых из-за учёта равных значений (здесь им даётся средний ранг).</p>

<h2>По тикетам: Sonnet 5 против Opus 5.5</h2>
{legend}
<div class="grid2">
{grouped("Python: стоимость по тикетам, $", ["py-s", "py-o"], "cost", lambda v: f"{v:g}", top_cost, 2)}
{grouped("JavaScript: стоимость по тикетам, $", ["js-s", "js-o"], "cost", lambda v: f"{v:g}", top_cost, 2)}
{grouped("TypeScript: стоимость по тикетам, $", ["ts-s", "ts-o"], "cost", lambda v: f"{v:g}", top_cost, 2)}
{grouped("Ruby 3: стоимость по тикетам, $", RUBY3, "cost", lambda v: f"{v:g}", top_cost, 2)}
{grouped("Ruby 4: стоимость по тикетам, $", RUBY4, "cost", lambda v: f"{v:g}", top_cost, 2)}
{grouped("Python: ходы по тикетам", ["py-s", "py-o"], "turns", lambda v: f"{v:.0f}", top_turns, 20)}
{grouped("JavaScript: ходы по тикетам", ["js-s", "js-o"], "turns", lambda v: f"{v:.0f}", top_turns, 20)}
{grouped("TypeScript: ходы по тикетам", ["ts-s", "ts-o"], "turns", lambda v: f"{v:.0f}", top_turns, 20)}
{grouped("Ruby 3: ходы по тикетам", RUBY3, "turns", lambda v: f"{v:.0f}", top_turns, 20)}
{grouped("Ruby 4: ходы по тикетам", RUBY4, "turns", lambda v: f"{v:.0f}", top_turns, 20)}
</div>
<p class="note">Шкалы одинаковые во всех панелях одной метрики. ×N над столбцом — число вызовов модели на тикет. Точные значения — по наведению и в таблицах ниже.</p>
<h3 style="margin-top:18px">Opus 5.5 и Fable 5.1: $ · ходы · минуты</h3>
{grid_table(OURS)}
<h3 style="margin-top:18px">Sonnet 5 (автор): $ · ходы · минуты</h3>
{grid_table(SONNET4)}

<h2>Реализация: как модели решали тикеты</h2>
<p>Ниже — качественное сравнение трёх реализаций на Ruby 3 (Sonnet 5, Opus 5.5, Fable 5.1) по снимкам кода после тикетов 1, 5, 6, 7 и 11, а затем числа: рост кода и тестов по тикетам и то, как агент работал с инструментами.</p>
{impl_html}
<h3 style="margin-top:18px">Строк кода и тестов после каждого тикета (Ruby)</h3>
{loc_table(RUBY3 + RUBY4)}
<h3 style="margin-top:18px">Как агент работал: вызовы инструментов за 11 тикетов</h3>
{mix_table(list(D))}
<p class="note">«Docker / run-*» — команды Bash, в которых агент собирал или запускал стенд (docker, run-server, run-tests, run-client); «curl» — ручные проверки HTTP. Для кампании автора посчитано по его транскриптам тем же способом.</p>

<h2>Сходимость и исправления</h2>
<div class="tw"><table><tr><th>Прогон</th><th class="n">Сошлось</th><th class="n">Вызовов модели</th><th>Тикеты с итерацией исправления</th><th class="n">Smoke после т11</th><th class="n">Тестов после т11</th></tr>{conv_rows}</table></div>
<p class="note">Тикет 1 требует второй итерации во всех девяти прогонах по одной причине: контрактный тест блокирующий с первого тикета, а <code>GET /blobs</code> и <code>PUT</code> ещё не реализованы. Smoke у автора локально давал 4/13 из-за сбоя Docker Desktop. Число тестов у автора не посчитано: логи его проверок не опубликованы. Паузы из-за лимита: у автора 5 за кампанию (~19 часов ожидания), у нас 0.</p>

<h2>Итоговый код после тикета 11</h2>
<div class="tw"><table><tr><th>Прогон</th><th>Базовый образ</th><th class="n">строк кода</th><th class="n">строк тестов</th><th class="n">тесты / код</th><th>Зависимости</th></tr>{code_rows}</table></div>
<p>Opus 5.5 на всех языках обошёлся без веб-фреймворка: стандартная библиотека на Python и в Node, чистый Rack на Ruby. Sonnet 5 взял Flask на Python, Express на TypeScript и Sinatra на Ruby; на JavaScript обе модели обошлись без зависимостей. Кода и тестов у Opus 5.5 в 2,2–3 раза больше. Строки считаются без пустых; тестами считаются файлы в каталогах <code>test</code>, <code>tests</code>, <code>spec</code> и с тестовыми именами.</p>

<h2>Проверки после наших прогонов</h2>
<ul>
<li>Базовые образы: все сессии на закреплённых образах, агент ни разу их не сменил.</li>
<li>Транскрипты и разбивка времени есть у всех {sum(len(glob.glob(f"docs/pilot-runs/{l}/ticket-*/*/transcript.jsonl")) for l in ("python-opus", "javascript-opus", "typescript-opus", "ruby3-opus", "ruby4-opus", "ruby3-fable", "ruby4-fable"))} сессий.</li>
<li>Интернет: 0 обращений к внешним хостам и 0 вызовов субагентов во всех кампаниях. Fable 5.1 дважды (Ruby 3, тикеты 1 и 7) читал <code>/proc/self/mountinfo</code>, осматривая окружение, и увидел хостовый путь bind-mount с именем репозитория эксперимента — канал утечки того же класса, что <code>docker inspect</code> в инцидентах автора. Дальше агент этим не воспользовался; путь в архиве заменён на <code>/Users/&lt;user&gt;/…</code>.</li>
<li>Fable 5.1, Ruby 4, тикет 11: первый вызов упёрся в лимит подписки через 26 минут ($11.79 впустую), ячейка повторена с нуля после сброса, как при паузах 429 у автора. Прерванная попытка сохранена с NOTE.md и в сравнение не входит.</li>
<li>Личных путей и данных в архивах нет.</li>
<li>{"Число ходов пересчитано по транскрипту: " + e("; ".join(fixed_cells)) + ". Агент ждал фоновую задачу, и итоговый JSON учёл только последний отрезок сессии (2 хода вместо 49)." if fixed_cells else "Число ходов во всех сессиях совпадает с транскриптом."}</li>
</ul>

<h2>Ошибки стенда, найденные и исправленные по ходу</h2>
<ul>
<li>В образе харнесса был Claude Code 2.1.238, с которым API отклоняет Opus 5.5 (ошибка 400). Версия стала параметром.</li>
<li>Проверка транскрипта на macOS падала на русском тексте, и архив оставался без транскрипта.</li>
<li>Контрактный тест искал сервер только на порту из <code>SYNCBOX_PORT</code>. Opus называет переменные compose-файла иначе, сервер вставал на 8080, и первый запуск кампании Ruby впустую сжёг четыре итерации. Тот запуск аннулирован. У Fable порт задаётся только аргументом <code>--port</code>, который подставляет <code>run-server</code>, поэтому проверка теперь, если <code>compose up</code> не дал сервер, повторяет запуск через <code>run-server</code> и убеждается, что данные лежат на tmpfs. Первый запуск кампании Fable тоже аннулирован.</li>
<li>При полностью зелёном smoke <code>gates.json</code> записывался битым.</li>
<li>Скрипт разбивки времени падал, если вызов инструмента в транскрипте завершился ошибкой.</li>
<li>Проверка выхода в интернет давала ложные срабатывания на регулярках вида <code>127\\.0\\.0\\.1</code> и на примере адреса <code>nas.lan</code> в README.</li>
</ul>

<h2>Ограничения</h2>
<ul>
<li>n = 1 на ячейку: различия между языками и версиями могут быть шумом единичной генерации.</li>
<li>Между нашими кампаниями и кампанией автора отличаются сразу модель, effort, версия Claude Code, абзац о версии в промпте и предзагрузка образов. Чистые сравнения — языки внутри одной модели, Ruby 3.3.12 против Ruby 4.0.7 и Opus 5.5 против Fable 5.1 на Ruby (промпты и стенд одинаковые).</li>
<li>Время сборки с автором напрямую не сравнимо: у него часть образов скачивалась во время прогона.</li>
<li>Образы Python и Node закреплены плавающими тегами, как у автора; Ruby — точной версией.</li>
<li>Сеть контейнера оставалась открытой; отсутствие выхода в интернет подтверждено по транскриптам, но не гарантировалось заранее.</li>
<li>Стоимость посчитана по ценам API; наши кампании шли по подписке.</li>
</ul>
</div></body></html>"""

ap = argparse.ArgumentParser()
ap.add_argument("--out", default="docs/opus-langs/report.html")
args = ap.parse_args()
Path(args.out).write_text(PAGE)
print(args.out, len(PAGE), "байт")
for k in D:
    print(f"  {full(k):28} ${tot(k, 'cost'):6.2f} ходов {tot(k, 'turns'):4d} время {tot(k, 'wall'):6.1f} out {tot(k, 'out'):7d} код {D[k]['code']['src']}/{D[k]['code']['test']} {D[k]['code']['deps']} тестов {D[k]['t']['11'].get('ntests')} smoke {D[k]['t']['11'].get('smoke')}")
rs, _ = ranks(SONNET4, "out"); rt, _ = ranks(SONNET4, "turns")
print("  ранги Sonnet out:", {name(k): round(v, 2) for k, v in rs.items()}, "ходы:", {name(k): round(v, 2) for k, v in rt.items()})
print("  max cost/turns по тикету:", max(D[k]["t"][n]["cost"] for k in D for n in TICKETS), max(D[k]["t"][n]["turns"] for k in D for n in TICKETS))
print("  пересчитаны ходы:", fixed_cells)
