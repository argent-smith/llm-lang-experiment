#!/usr/bin/env python3
"""Отчёт о mutation score тестов пяти Ruby-реализаций по архиву прогонов
mutant (scripts/mutation/run-campaign.sh → docs/opus-langs/mutation/<ключ>/).

    scripts/make-mutation-report.py [--src docs/opus-langs/mutation] [--out docs/opus-langs/mutation-report.html]

Страница статическая, без JS; подсказки — через SVG <title>. Палитра — три
категориальных слота (Sonnet / Opus / Fable), проверена validate_palette.js
в светлом и тёмном режимах.
"""
import argparse
import html
import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from campaignlib import META, REPO, full, name  # noqa: E402

e = html.escape
num = lambda v: f"{v:,.0f}".replace(",", " ")
pct = lambda v: f"{v * 100:.1f}%"
KEYS = ["rb-s", "rb3-o", "rb3-f", "rb4-o", "rb4-f"]
SLOT = {"Sonnet 5": "s", "Opus 5.5": "o", "Fable 5.1": "f"}
GROUPS = [("Ruby 3.3", ["rb-s", "rb3-o", "rb3-f"]), ("Ruby 4.0.7", ["rb4-o", "rb4-f"])]
HELPER_RE = re.compile(r"TestSupport|Test::|Spec::|Fake|Helper")

ap = argparse.ArgumentParser()
ap.add_argument("--src", default="docs/opus-langs/mutation")
ap.add_argument("--out", default="docs/opus-langs/mutation-report.html")
args = ap.parse_args()
SRC = REPO / args.src


def kv(path, keys):
    out = {}
    for line in open(path, errors="replace"):
        m = re.match(r"^(\w[\w/-]*):\s+(.+?)\s*$", line)
        if m and m.group(1) in keys:
            out[m.group(1)] = m.group(2)
    return out


def alive_report(path):
    """{субъект: (выжило, пример diff)} из отчёта mutant (без строк прогресса)."""
    L = open(path, errors="replace").read().split("\n")
    heads = [(i, m.group(1)) for i, l in enumerate(L) if (m := re.match(r"^(Syncbox\S+?):/\S+:\d+$", l))]
    out = {}
    for n, (i, subj) in enumerate(heads):
        blk = L[i:heads[n + 1][0] if n + 1 < len(heads) else len(L)]
        evils = sum(1 for x in blk if x.startswith("evil:"))
        more = [int(m.group(1)) for x in blk if (m := re.match(r"\((\d+) more alive", x))]
        count = 1 + more[0] if more else evils
        diff = []
        if evils:
            j = next(k for k, x in enumerate(blk) if x.startswith("evil:")) + 2
            while j < len(blk) and not blk[j].startswith("-----"):
                diff.append(blk[j])
                j += 1
        out[subj] = (count, "\n".join(diff))
    return out


def wilson(k, n, z=1.96):
    if not n:
        return (0, 0)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (c - h, c + h)


D = {}
for k in KEYS:
    d = SRC / k
    if not (d / "summary.txt").exists():
        continue
    s = kv(d / "summary.txt", {"Subjects", "Mutations", "Kills", "Alive", "Timeouts", "Runtime", "Killtime", "Coverage"})
    env = kv(d / "environment.txt", {"Integration", "Subjects", "Mutations", "All-Tests"})
    sample = [l.strip() for l in open(d / "subjects-sample.txt") if l.strip()]
    per_mut = {}
    if (d / "subject-mutations.txt").exists():
        for l in open(d / "subject-mutations.txt"):
            if "\t" in l:
                a, b = l.rstrip("\n").split("\t")
                per_mut[a] = int(b) if b.isdigit() else None
    alive = alive_report(d / "mutant.log")
    subjects = []
    for subj in sample:
        a = alive.get(subj, (0, ""))[0]
        m = per_mut.get(subj)
        subjects.append(dict(name=subj, alive=a, mutations=m, score=(1 - a / m) if m else None,
                             helper=bool(HELPER_RE.search(subj)), diff=alive.get(subj, (0, ""))[1]))
    base = (d / "baseline.log").read_text(errors="replace")
    bm = re.search(r"(\d+) (?:runs|examples)", base)
    second = SRC / "root-run" / k / "summary.txt"
    mut, kills, al = int(s["Mutations"]), int(s["Kills"]), int(s["Alive"])
    helpers = [x for x in subjects if x["helper"]]
    h_mut = sum(x["mutations"] or 0 for x in helpers)
    h_alive = sum(x["alive"] for x in helpers)
    D[k] = dict(
        integration=env.get("Integration", "?"), tests=int(env.get("All-Tests", 0)), tests_baseline=int(bm.group(1)) if bm else 0,
        subjects_total=int(env.get("Subjects", 0)), subjects_sample=len(sample), mutations_total=int(env.get("Mutations", 0)),
        mutations=mut, kills=kills, alive=al, timeouts=int(s.get("Timeouts", 0)),
        runtime=float(s.get("Runtime", "0").rstrip("s")), killtime=float(s.get("Killtime", "0").rstrip("s")),
        score=kills / mut, ci=wilson(kills, mut), subjects=subjects, patches=sum(1 for l in open(d / "patches.log") if l.startswith("patched")),
        helpers=len(helpers), helper_mut=h_mut, helper_alive=h_alive,
        score_core=((kills - (h_mut - h_alive)) / (mut - h_mut)) if h_mut and mut > h_mut else None,
        second=(lambda t: int(t["Kills"]) / int(t["Mutations"]))(kv(second, {"Kills", "Mutations"})) if second.exists() else None,
        second_alive=int(kv(second, {"Alive"}).get("Alive", 0)) if second.exists() else None,
    )

if not D:
    sys.exit(f"нет данных в {SRC}")
sw = lambda k: f'<b class="sw {SLOT[META[k]["model"]]}"></b>'
label = lambda k: f'{name(k)} · {META[k]["model"]}'
legend = ('<div class="legend"><span><b class="sw s"></b>Sonnet 5 (кампания автора)</span><span><b class="sw o"></b>Opus 5.5</span>'
          '<span><b class="sw f"></b>Fable 5.1</span></div>')


def score_chart():
    """Горизонтальные бары score по прогонам, фасеты по версии Ruby."""
    W, L, R, BAR, GAP, GH = 1100, 200, 90, 18, 8, 26
    rows = []
    y = 24
    for g, keys in GROUPS:
        rows.append(("group", g, y))
        y += 20
        for k in keys:
            if k in D:
                rows.append(("bar", k, y))
                y += BAR + GAP
        y += GH
    H = y + 22
    pw = W - L - R
    s = [f'<svg viewBox="0 0 {W} {H}" role="img" aria-label="Mutation score по прогонам">']
    for v in range(0, 101, 25):
        x = L + pw * v / 100
        s.append(f'<line class="grid" x1="{x:.1f}" x2="{x:.1f}" y1="14" y2="{H - 18}"/><text class="ax" x="{x:.1f}" y="{H - 5}" text-anchor="middle">{v}%</text>')
    for kind, k, y in rows:
        if kind == "group":
            s.append(f'<text class="grp" x="{L - 8}" y="{y + 4}" text-anchor="end">{e(k)}</text>')
            continue
        v = D[k]["score"]
        w = pw * v
        lo, hi = D[k]["ci"]
        tip = f'{label(k)}: {pct(v)} (убито {num(D[k]["kills"])} из {num(D[k]["mutations"])}; 95% ДИ {pct(lo)}–{pct(hi)})'
        s.append(f'<g class="mark"><title>{e(tip)}</title><rect class="hit" x="{L - 8}" y="{y - 4}" width="{pw + 8 + R}" height="{BAR + 8}"/>'
                 f'<path class="{SLOT[META[k]["model"]]}" d="M{L},{y} h{w - 4:.1f} q4,0 4,4 v{BAR - 8} q0,4 -4,4 h{-(w - 4):.1f} z"/>'
                 f'<line class="ci" x1="{L + pw * lo:.1f}" x2="{L + pw * hi:.1f}" y1="{y + BAR / 2}" y2="{y + BAR / 2}"/>'
                 f'<text class="lbl" x="{L - 8}" y="{y + BAR / 2 + 4}" text-anchor="end">{e(META[k]["model"])}</text>'
                 f'<text class="val" x="{L + w + 8:.1f}" y="{y + BAR / 2 + 4}">{pct(v)}</text></g>')
    s.append(f'<line class="base" x1="{L}" x2="{L}" y1="14" y2="{H - 18}"/></svg>')
    return "".join(s)


def dumbbell():
    """Повторный прогон: ночной (root) → дневной (nobody), одна тональность, два оттенка."""
    items = [k for k in KEYS if k in D and D[k]["second"] is not None]
    W, L, R, RH = 1100, 200, 90, 30
    H = 24 + RH * len(items) + 24
    pw = W - L - R
    s = [f'<svg viewBox="0 0 {W} {H}" role="img" aria-label="Воспроизводимость score">']
    for v in range(0, 101, 25):
        x = L + pw * v / 100
        s.append(f'<line class="grid" x1="{x:.1f}" x2="{x:.1f}" y1="14" y2="{H - 18}"/><text class="ax" x="{x:.1f}" y="{H - 5}" text-anchor="middle">{v}%</text>')
    for i, k in enumerate(items):
        y = 24 + RH * i + RH / 2
        a, b = D[k]["second"], D[k]["score"]
        xa, xb = L + pw * a, L + pw * b
        tip = f'{label(k)}: ночной прогон (root) {pct(a)} → повтор (nobody) {pct(b)}, Δ {(b - a) * 100:+.1f} п.п.'
        s.append(f'<g class="mark"><title>{e(tip)}</title><rect class="hit" x="{L - 8}" y="{y - RH / 2}" width="{pw + 8 + R}" height="{RH}"/>'
                 f'<line class="db" x1="{xa:.1f}" x2="{xb:.1f}" y1="{y}" y2="{y}"/>'
                 f'<circle class="d1" cx="{xa:.1f}" cy="{y}" r="5"/><circle class="d2" cx="{xb:.1f}" cy="{y}" r="5"/>'
                 f'<text class="lbl" x="{L - 8}" y="{y + 4}" text-anchor="end">{e(label(k))}</text>'
                 f'<text class="val" x="{max(xa, xb) + 10:.1f}" y="{y + 4}">{(b - a) * 100:+.1f} п.п.</text></g>')
    s.append(f'<line class="base" x1="{L}" x2="{L}" y1="14" y2="{H - 18}"/></svg>')
    return "".join(s)


def strip_chart():
    """Score каждого субъекта выборки — точки по строкам прогонов."""
    W, L, R, RH = 1100, 200, 40, 34
    keys = [k for k in KEYS if k in D]
    H = 24 + RH * len(keys) + 24
    pw = W - L - R
    s = [f'<svg viewBox="0 0 {W} {H}" role="img" aria-label="Score по субъектам">']
    for v in range(0, 101, 25):
        x = L + pw * v / 100
        s.append(f'<line class="grid" x1="{x:.1f}" x2="{x:.1f}" y1="14" y2="{H - 18}"/><text class="ax" x="{x:.1f}" y="{H - 5}" text-anchor="middle">{v}%</text>')
    for i, k in enumerate(keys):
        y = 24 + RH * i + RH / 2
        s.append(f'<text class="lbl" x="{L - 8}" y="{y + 4}" text-anchor="end">{e(label(k))}</text>')
        pts = sorted((x for x in D[k]["subjects"] if x["score"] is not None), key=lambda x: x["score"])
        cls = SLOT[META[k]["model"]]
        for j, x in enumerate(pts):
            cx = L + pw * x["score"]
            jitter = ((j * 7919) % 11 - 5) * 1.1
            tip = f'{x["name"]}: {pct(x["score"])} — выжило {x["alive"]} из {x["mutations"]}' + (" (тестовый помощник)" if x["helper"] else "")
            s.append(f'<g class="mark"><title>{e(tip)}</title><circle class="hit" cx="{cx:.1f}" cy="{y + jitter:.1f}" r="12"/>'
                     f'<circle class="dot {cls}{" hol" if x["helper"] else ""}" cx="{cx:.1f}" cy="{y + jitter:.1f}" r="4.5"/></g>')
    s.append(f'<line class="base" x1="{L}" x2="{L}" y1="14" y2="{H - 18}"/></svg>')
    return "".join(s)


main_rows = "".join(
    f'<tr><td>{sw(k)}{e(label(k))}</td><td>{e(D[k]["integration"])}</td><td class="n">{D[k]["tests"]}</td>'
    f'<td class="n">{D[k]["subjects_total"]}</td><td class="n">{D[k]["subjects_sample"]} <span class="muted">({D[k]["subjects_sample"] / D[k]["subjects_total"] * 100:.0f}%)</span></td>'
    f'<td class="n">{num(D[k]["mutations"])} <span class="muted">из {num(D[k]["mutations_total"])}</span></td><td class="n">{num(D[k]["kills"])}</td><td class="n">{num(D[k]["alive"])}</td><td class="n">{D[k]["timeouts"]}</td>'
    f'<td class="n"><b>{pct(D[k]["score"])}</b></td><td class="n muted">{pct(D[k]["ci"][0])}–{pct(D[k]["ci"][1])}</td>'
    f'<td class="n">{D[k]["runtime"] / 60:.0f} мин</td><td class="n">{D[k]["mutations"] / D[k]["runtime"]:.2f}</td></tr>' for k in D)

repro_rows = "".join(
    f'<tr><td>{sw(k)}{e(label(k))}</td><td class="n">{pct(D[k]["second"])}</td><td class="n">{pct(D[k]["score"])}</td>'
    f'<td class="n">{(D[k]["score"] - D[k]["second"]) * 100:+.1f}</td><td class="n">{D[k]["second_alive"]} → {D[k]["alive"]}</td></tr>'
    for k in D if D[k]["second"] is not None)

def top_alive(k):
    out = []
    for x in sorted(D[k]["subjects"], key=lambda x: -x["alive"])[:3]:
        n = x["name"].removeprefix("Syncbox::")
        out.append(f'<code>{e(n)}</code> {x["alive"]}' + (f'/{x["mutations"]}' if x["mutations"] else ""))
    return "; ".join(out)


def median_score(k):
    v = sorted(x["score"] for x in D[k]["subjects"] if x["score"] is not None)
    return pct(v[len(v) // 2]) if v else "—"


subj_rows = "".join(
    f'<tr><td>{sw(k)}{e(label(k))}</td><td class="n">{sum(1 for x in D[k]["subjects"] if x["alive"] == 0)} из {D[k]["subjects_sample"]}</td>'
    f'<td class="n">{sum(1 for x in D[k]["subjects"] if x["score"] is not None and x["score"] < 0.5)}</td>'
    f'<td class="n">{median_score(k)}</td><td>{top_alive(k)}</td></tr>' for k in D)


def diff_html(diff):
    rows = []
    for l in diff.split("\n"):
        cls = "add" if l.startswith("+") else "del" if l.startswith("-") else "ctx"
        rows.append(f'<i class="{cls}">{e(l)}</i>')
    return "<pre>" + "\n".join(rows) + "</pre>"


def examples(k):
    xs = [x for x in sorted(D[k]["subjects"], key=lambda x: -x["alive"]) if x["diff"]]
    body = "".join(f'<h4><code>{e(x["name"])}</code> <span class="muted">— выжило {x["alive"]}'
                   + (f' из {x["mutations"]}' if x["mutations"] else "") + "</span></h4>" + diff_html(x["diff"]) for x in xs)
    return f'<details><summary>{sw(k)}{e(label(k))}: по одному выжившему мутанту на каждый из {len(xs)} методов с выжившими</summary>{body}</details>'


core_note = ""
for k in D:
    if D[k]["score_core"] is not None:
        core_note += (f'<li><b>{e(label(k))}: тестовые помощники в выборке.</b> Вспомогательный код тестов лежит в пространстве <code>Syncbox::TestSupport</code> и попадает под выражение <code>Syncbox*</code>: '
                      f'{D[k]["helpers"]} из {D[k]["subjects_sample"]} субъектов выборки ({num(D[k]["helper_mut"])} мутаций, выжило {D[k]["helper_alive"]}) — это код, который тесты не проверяют по определению. '
                      f'Без них score = <b>{pct(D[k]["score_core"])}</b> (в таблице — {pct(D[k]["score"])}). У остальных прогонов помощники вне <code>Syncbox</code> либо их нет.</li>')

best = max(D, key=lambda k: D[k]["score"])
worst = min(D, key=lambda k: D[k]["score"])
tot_mut = sum(D[k]["mutations"] for k in D)
tot_rt = sum(D[k]["runtime"] for k in D)

PAGE = f"""<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Syncbox: mutation score</title><style>
:root{{color-scheme:light dark;--surface:var(--agterm-background,#fcfcfb);--fg:var(--agterm-foreground,#0b0b0b);--ink2:color-mix(in srgb,var(--fg) 70%,transparent);--muted:color-mix(in srgb,var(--fg) 55%,transparent);
--line:color-mix(in srgb,var(--fg) 12%,transparent);--base:color-mix(in srgb,var(--fg) 30%,transparent);--panel:color-mix(in srgb,var(--fg) 4%,transparent);
--s:#2a78d6;--o:#eb6834;--f:#1baf7a;--d1:#86b6ef;--d2:#2a78d6;--add:#006300;--del:#d03b3b}}
@media (prefers-color-scheme:dark){{:root:not([data-theme="light"]){{--s:#3987e5;--o:#d95926;--f:#199e70;--d1:#6da7ec;--d2:#3987e5;--add:#0ca30c;--del:#e66767}}}}
:root[data-theme="dark"]{{--s:#3987e5;--o:#d95926;--f:#199e70;--d1:#6da7ec;--d2:#3987e5;--add:#0ca30c;--del:#e66767}}
body{{background:var(--surface);color:var(--fg);font:14px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;margin:0}}
.page{{max-width:1180px;margin:0 auto;padding:28px 16px 60px}}
h1{{font-size:24px;margin:0 0 4px;line-height:1.25}} h2{{font-size:17px;margin:38px 0 6px;padding-top:18px;border-top:1px solid var(--line)}} h3{{font-size:13px;margin:0 0 10px;font-weight:600}} h4{{font-size:12.5px;margin:14px 0 4px;font-weight:600}}
p{{margin:6px 0;max-width:88ch}} .sub,.note,.muted{{color:var(--muted)}} .note{{font-size:12px;margin-top:8px}} code{{font:12px ui-monospace,Menlo,monospace}}
.tiles{{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin:18px 0}}
.tile,.card{{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:14px 16px}}
.tile b{{display:block;font-size:26px;line-height:1.15;font-weight:600}} .tile span{{color:var(--muted);font-size:12px}}
.grid2{{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,460px),1fr));gap:12px;margin:10px 0}}
.legend{{display:flex;flex-wrap:wrap;gap:6px 18px;margin:12px 0;font-size:12px}} .sw{{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:6px;vertical-align:-1px}}
.s{{background:var(--s);fill:var(--s)}} .o{{background:var(--o);fill:var(--o)}} .f{{background:var(--f);fill:var(--f)}}
svg{{width:100%;max-width:1100px;height:auto;display:block}} .grid{{stroke:var(--line);stroke-width:1}} .base{{stroke:var(--base);stroke-width:1}} .ax{{fill:var(--muted);font-size:10px}}
.lbl{{fill:var(--ink2);font-size:11.5px}} .grp{{fill:var(--fg);font-size:11.5px;font-weight:600}} .val{{fill:var(--fg);font-size:11.5px;font-variant-numeric:tabular-nums}}
.hit{{fill:transparent}} .mark:hover path,.mark:hover .dot{{opacity:.75}} .ci{{stroke:var(--surface);stroke-width:2;opacity:.9}}
.db{{stroke:var(--d1);stroke-width:2;stroke-linecap:round}} .d1{{fill:var(--d1);stroke:var(--surface);stroke-width:2}} .d2{{fill:var(--d2);stroke:var(--surface);stroke-width:2}}
.dot{{stroke:var(--surface);stroke-width:2}} .dot.hol{{fill:var(--surface);stroke-width:2}} .dot.hol.s{{stroke:var(--s)}} .dot.hol.o{{stroke:var(--o)}} .dot.hol.f{{stroke:var(--f)}}
.key{{display:flex;flex-wrap:wrap;gap:6px 18px;font-size:12px;margin:6px 0}} .key i{{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:6px;vertical-align:-1px}}
.tw{{overflow-x:auto;margin:10px 0}} table{{border-collapse:collapse;width:100%;font-size:12.5px}} th,td{{padding:5px 9px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}}
th{{color:var(--muted);font-weight:500}} td.n,th.n{{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}}
ul{{margin:6px 0;padding-left:20px;max-width:88ch}} li{{margin:3px 0}}
details{{margin:8px 0;border:1px solid var(--line);border-radius:8px;padding:8px 14px}} summary{{cursor:pointer;font-size:13px}}
pre{{font:11.5px/1.4 ui-monospace,Menlo,monospace;background:var(--panel);border-radius:6px;padding:8px 10px;overflow-x:auto;margin:4px 0 0}} pre i{{font-style:normal;display:block}} pre .add{{color:var(--add)}} pre .del{{color:var(--del)}}
</style></head><body><div class="page">
<h1>Syncbox: mutation score тестов пяти Ruby-реализаций</h1>
<p class="sub">Сколько искусственно внесённых ошибок в коде замечают штатные тесты реализации. mutant 0.17 на финальных снимках после тикета 11: один прогон Sonnet 5 (кампания автора), два Opus 5.5 и два Fable 5.1. n = 1 на ячейку — наблюдения, не выводы.</p>

<div class="tiles">
<div class="tile"><b>{pct(D[worst]["score"])} – {pct(D[best]["score"])}</b><span>mutation score: от {e(label(worst))} до {e(label(best))}</span></div>
<div class="tile"><b>{num(tot_mut)}</b><span>мутаций прогнано через тесты, каждая — полный прогон набора</span></div>
<div class="tile"><b>{tot_rt / 3600:.1f} ч</b><span>суммарное время измерения на 6 воркерах</span></div>
<div class="tile"><b>{sum(D[k]["tests"] for k in D)}</b><span>тестов в пяти наборах: {", ".join(str(D[k]["tests"]) for k in D)}</span></div>
</div>

<h2>Score по прогонам</h2>
{legend}
<div class="card">{score_chart()}
<p class="note">Длина бара — доля убитых мутаций; светлая засечка внутри — 95% доверительный интервал Вильсона по числу мутаций (условный: мутации одного метода не независимы). Подробности — по наведению и в таблице ниже.</p></div>
<div class="tw"><table><tr><th>Прогон</th><th>фреймворк</th><th class="n">тестов</th><th class="n">методов</th><th class="n">в выборке</th><th class="n">мутаций</th><th class="n">убито</th><th class="n">выжило</th><th class="n">таймаутов</th><th class="n">score</th><th class="n">95% ДИ</th><th class="n">время</th><th class="n">мутаций/с</th></tr>{main_rows}</table></div>

<h2>Метод</h2>
<ul>
<li><b>Инструмент.</b> <a href="https://github.com/mbj/mutant">mutant</a> 0.17 (<code>--usage opensource</code>), набор операторов <code>light</code>, 6 параллельных воркеров, таймаут 120 с на мутацию — мутация, не уложившаяся в таймаут, у mutant считается убитой (столбец «таймаутов»). Тесты и mutant идут внутри Docker-образа самой реализации под непривилегированным пользователем: тесты на права доступа под root пропускаются или ведут себя иначе.</li>
<li><b>Субъекты.</b> Все методы в пространстве <code>Syncbox*</code>. У Sonnet — {D["rb-s"]["subjects_total"]} методов (маршруты Sinatra — блоки, не методы, они вне измерения); у Opus и Fable — {", ".join(str(D[k]["subjects_total"]) for k in D if k != "rb-s")}. Для каждой мутации гоняется весь набор тестов (<code>cover "Syncbox*"</code>), не эвристически выбранный файл: имена тестовых классов у агентов не совпадают с именами классов кода.</li>
<li><b>Выборка.</b> Наборы Opus и Fable поднимают реальный сервер в тестах и идут 10–30 с на прогон, полный набор из 6–9 тысяч мутаций занял бы сутки на реализацию. Поэтому у них случайная выборка 25% методов с фиксированным seed 42, score — по мутациям выбранных методов. У Sonnet (rspec, 0.5 с на прогон) — все методы. Доля ниже 100% указана в столбце «в выборке».</li>
<li><b>Что не меняется.</b> Код реализации в архиве не правится; в измерительной копии заменён только строковый литерал <code>"\\xFF".b</code>, который не принимает парсер mutant ({", ".join(f"{e(name(k))} {META[k]['model']}: {D[k]['patches']}" for k in D)} файлов). Тесты не менялись.</li>
{core_note}
<li><b>Что score не показывает.</b> Число ошибок в самом коде: все пять реализаций прошли одни и те же внешние проверки. Score говорит, насколько тесты привязаны к поведению — то есть заметят ли они следующую поломку. Часть выживших мутаций эквивалентна исходному коду (например, замена <code>env = ENV</code> на обязательный аргумент, если все вызовы передают его явно), поэтому 100% недостижимы и не нужны.</li>
</ul>

<h2>Воспроизводимость</h2>
<p>Два независимых измерения на одном снимке и одной выборке: ночной прогон под root (отвергнут — у Opus на Ruby 4 тесты на права доступа под root падали) и дневной под <code>nobody</code>. Разница — таймауты и порядок параллельного выполнения.</p>
<div class="card">{dumbbell()}<div class="key"><span><i style="background:var(--d1)"></i>ночной прогон, root</span><span><i style="background:var(--d2)"></i>повтор, nobody</span></div></div>
<div class="tw"><table><tr><th>Прогон</th><th class="n">root</th><th class="n">nobody</th><th class="n">Δ п.п.</th><th class="n">выжило</th></tr>{repro_rows}</table></div>

<h2>Где выживают мутанты</h2>
<p>Score каждого метода из выборки: доля убитых мутаций в нём. Один метод — одна точка; полые точки — тестовые помощники.</p>
{legend}
<div class="card">{strip_chart()}</div>
<div class="tw"><table><tr><th>Прогон</th><th class="n">методов без выживших</th><th class="n">методов со score &lt; 50%</th><th class="n">медианный score метода</th><th>больше всего выживших (выжило/мутаций)</th></tr>{subj_rows}</table></div>

<h2>Примеры выживших мутантов</h2>
<p>Из отчёта mutant: первый выживший мутант каждого метода, где они есть. Diff относительно исходного метода; тесты на такой код остаются зелёными.</p>
{"".join(examples(k) for k in D)}

<h2>Что видно</h2>
<ul>
<li>Разрыв между кампанией автора и нашими — не проценты, а кратность: {pct(D["rb-s"]["score"])} у Sonnet против {pct(min(D[k]["score"] for k in D if k != "rb-s"))}–{pct(max(D[k]["score"] for k in D if k != "rb-s"))} у Opus и Fable. У Sonnet тесты в основном проверяют, что команда отработала, а не что она сделала: в <code>Sync#run</code> из {next(x["mutations"] for x in D["rb-s"]["subjects"] if x["name"] == "Syncbox::Sync#run") or "?"} мутаций выжило {next(x["alive"] for x in D["rb-s"]["subjects"] if x["name"] == "Syncbox::Sync#run")}, а тело <code>FailureReport#print</code> можно заменить на <code>raise</code> — ни один из {D["rb-s"]["tests"]} тестов это не вызывает.</li>
<li>Между Opus 5.5 и Fable 5.1 устойчивой разницы нет: четыре прогона лежат в коридоре {pct(min(D[k]["score"] for k in D if k != "rb-s"))}–{pct(max(D[k]["score"] for k in D if k != "rb-s"))}, и порядок меняется с версией Ruby (на 3.3.12 выше Opus на 0.2 п.п., на 4.0.7 — на 8.9 п.п.). Доверительные интервалы на Ruby 4 не пересекаются, но они считаны по мутациям одной случайной выборки методов: у Fable на Ruby 4 в выборку попали <code>Options.build_parser</code> и <code>Server::Runner#run</code> — методы, которые тесты по построению почти не трогают (151 выживших из 240). Это свойство выборки, не модели; разница между версиями Ruby — внутри того же шума.</li>
<li>У Opus и Fable выжившие мутанты сосредоточены в обвязке — разборе ответов сервера, форматировании сообщений об ошибках, опциях CLI (см. столбец «больше всего выживших»); у Sonnet — в основной логике push/pull/sync/status.</li>
<li>Измерение детерминировано по входу (снимок, выборка, seed) и воспроизводимо с точностью до таймаутов, но дорого: 25% методов — это {tot_rt / 3600:.1f} ч на пять реализаций. Полный прогон имеет смысл только для одной реализации за раз.</li>
</ul>
</div></body></html>"""
Path(args.out).write_text(PAGE)
print(args.out, len(PAGE), "байт")
