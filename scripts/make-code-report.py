#!/usr/bin/env python3
"""Отчёт о коде реализаций по снимкам docs/pilot-runs: размер, переделки и
локальность правок по тикетам, дублирование (jscpd). Без запуска кода.

    scripts/make-code-report.py [--out docs/opus-langs/code-report.html] [--no-jscpd]

jscpd запускается через `npx --yes jscpd@4.0.5` (нужен Node 22+); результаты
кешируются в pilot-runs-live/.cache/. Страница статическая, без JS; цвета —
из темы терминала agterm с запасными значениями.
"""
import argparse
import difflib
import hashlib
import html
import json
import os
import statistics
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from campaignlib import META, REPO, RUNS, TICKETS, files, full, loc, name, snapshots  # noqa: E402

os.chdir(REPO)
e = html.escape
num = lambda v: f"{v:,.0f}".replace(",", " ")
CACHE = REPO / "pilot-runs-live/.cache"
JSCPD_VER = "4.0.5"
TEST_IGNORE = "**/test/**,**/tests/**,**/spec/**,**/__tests__/**,**/*.test.*,**/*.spec.*,**/test_*,**/*_test.*,**/*_spec.rb"


def read_lines(path):
    try:
        return [l for l in open(path, errors="replace").read().splitlines() if l.strip()]
    except OSError:
        return []


def churn(prev, cur):
    """Между двумя снимками: добавлено/удалено непустых строк, файлы новые/изменённые/удалённые."""
    fp, fc = (files(prev) if prev else {}), files(cur)
    added = deleted = 0
    new = mod = gone = 0
    for rel in set(fp) | set(fc):
        a = read_lines(os.path.join(prev, rel)) if rel in fp else []
        b = read_lines(os.path.join(cur, rel)) if rel in fc else []
        if rel not in fp:
            new += 1
        elif rel not in fc:
            gone += 1
        if a == b:
            continue
        if rel in fp and rel in fc:
            mod += 1
        sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
        for tag, i1, i2, j1, j2 in sm.get_opcodes():
            if tag in ("delete", "replace"):
                deleted += i2 - i1
            if tag in ("insert", "replace"):
                added += j2 - j1
    return dict(added=added, deleted=deleted, new=new, mod=mod, gone=gone, existing=len(fp))


def sizes(code):
    fs = files(code)
    by = {"code": [], "test": [], "infra": []}
    for rel, c in fs.items():
        by[c].append((loc(os.path.join(code, rel)), rel))
    big = max(by["code"] + by["test"] + by["infra"], default=(0, ""))
    return dict(code=sum(l for l, _ in by["code"]), test=sum(l for l, _ in by["test"]), infra=sum(l for l, _ in by["infra"]),
                files=len(fs), big=big[0], bigname=big[1],
                median=statistics.median([l for l, _ in by["code"]]) if by["code"] else 0)


def jscpd(code, ignore_tests):
    key = hashlib.sha1(f"{code}|{ignore_tests}|{JSCPD_VER}".encode()).hexdigest()[:16]
    CACHE.mkdir(parents=True, exist_ok=True)
    cf = CACHE / f"jscpd-{key}.json"
    if cf.exists():
        return json.loads(cf.read_text())
    out = CACHE / f"jscpd-out-{key}"
    ignore = "**/node_modules/**,**/dist/**,**/*.md,**/*.yaml,**/*.yml,**/*.lock,**/*.json"
    if ignore_tests:
        ignore += "," + TEST_IGNORE
    r = subprocess.run(["npx", "--yes", f"jscpd@{JSCPD_VER}", code, "--silent", "--reporters", "json", "--output", str(out),
                        "--ignore", ignore, "--min-lines", "5", "--min-tokens", "50",
                        "--format", "ruby,python,javascript,typescript"], capture_output=True, text=True)
    rep = out / "jscpd-report.json"
    if not rep.exists():
        sys.exit(f"jscpd не отработал для {code}: {r.stderr[-400:]}")
    t = json.load(open(rep))["statistics"]["total"]
    res = dict(lines=t["lines"], dup=t["duplicatedLines"], pct=t["percentage"], clones=t["clones"])
    cf.write_text(json.dumps(res))
    return res


ap = argparse.ArgumentParser()
ap.add_argument("--out", default="docs/opus-langs/code-report.html")
ap.add_argument("--no-jscpd", action="store_true")
args = ap.parse_args()

D = {}
for k, *_ in RUNS:
    snap = snapshots(k)
    prev = None
    per = {}
    for n in TICKETS:
        per[n] = churn(prev, snap[n])
        per[n]["size"] = sizes(snap[n])
        prev = snap[n]
    fin = snap["11"]
    D[k] = dict(t=per, size=sizes(fin), snap=snap,
                dup_all=None if args.no_jscpd else jscpd(fin, False),
                dup_code=None if args.no_jscpd else jscpd(fin, True))
    print(f"  {full(k):26} код {D[k]['size']['code']:5d} тесты {D[k]['size']['test']:5d} инфра {D[k]['size']['infra']:4d} "
          f"+{sum(x['added'] for x in per.values()):6d} −{sum(x['deleted'] for x in per.values()):5d} "
          f"dup {D[k]['dup_code']['pct'] if D[k]['dup_code'] else '-'}% / {D[k]['dup_all']['pct'] if D[k]['dup_all'] else '-'}%", file=sys.stderr)

tot_add = lambda k: sum(D[k]["t"][n]["added"] for n in TICKETS)
tot_del = lambda k: sum(D[k]["t"][n]["deleted"] for n in TICKETS)
rework = lambda k: tot_del(k) / max(tot_add(k), 1)
# переделки без тикета 1: удаления на тикетах 2–11 относительно кода, существовавшего до каждого из них
later_del = lambda k: sum(D[k]["t"][n]["deleted"] for n in TICKETS[1:])
mod_share = lambda k: statistics.mean(D[k]["t"][n]["mod"] / max(D[k]["t"][n]["existing"], 1) for n in TICKETS[1:])
noop = lambda k: [n for n in TICKETS[1:] if D[k]["t"][n]["added"] + D[k]["t"][n]["deleted"] == 0]
sw = lambda k: f'<b class="sw {META[k]["cls"]}"></b>'
RUBY3 = ["rb-s", "rb3-o", "rb3-f"]
RUBY4 = ["rb4-o", "rb4-f"]


def hbars(title, val, fmt, note=""):
    mx = max(val(k) for k in D) or 1
    out = [f'<div class="card"><h3>{e(title)}</h3>']
    prev = None
    for k in D:
        v = val(k)
        gap = ' style="margin-top:12px"' if prev and prev != META[k]["lang"] else ""
        prev = META[k]["lang"]
        out.append(f'<div class="hb"{gap} title="{e(full(k))}: {fmt(v)}"><span class="hl">{e(name(k))}<i>{META[k]["model"]}</i></span>'
                   f'<span class="ht"><span class="hf {META[k]["cls"]}" style="width:{v / mx * 100:.1f}%"></span></span><span class="hv">{fmt(v)}</span></div>')
    if note:
        out.append(f'<p class="note">{note}</p>')
    return "".join(out) + "</div>"


def grouped(title, keys, field, fmt, top, step):
    W, H, L, B, TOP = 560, 200, 40, 24, 14
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
            val = D[k]["t"][str(n)][field]
            h = max(min(val, top) / top * ph, 1.5)
            x = x0 + i * (bw + 2)
            s.append(f'<path class="{META[k]["cls"]}" d="M{x:.1f},{TOP + ph} v{-(h - 2):.1f} q0,-2 2,-2 h{bw - 4:.1f} q2,0 2,2 v{h - 2:.1f} z">'
                     f'<title>Тикет {n} · {e(full(k))}: {fmt(val)}</title></path>')
        s.append(f'<text class="ax" x="{L + (n - 0.5) * gw:.1f}" y="{H - 7}" text-anchor="middle">т{n}</text>')
    s.append(f'<line class="base" x1="{L}" x2="{W}" y1="{TOP + ph}" y2="{TOP + ph}"/></svg></div>')
    return "".join(s)


legend = ('<div class="legend"><span><b class="sw s"></b>Sonnet 5 (кампания автора)</span><span><b class="sw o"></b>Opus 5.5</span>'
          '<span><b class="sw o4"></b>Opus 5.5 на Ruby 4.0.7</span><span><b class="sw f"></b>Fable 5.1</span><span><b class="sw f4"></b>Fable 5.1 на Ruby 4.0.7</span></div>')

size_rows = "".join(
    f'<tr><td>{sw(k)}{e(full(k))}</td><td class="n">{num(D[k]["size"]["code"])}</td><td class="n">{num(D[k]["size"]["test"])}</td>'
    f'<td class="n">{num(D[k]["size"]["infra"])}</td><td class="n">{D[k]["size"]["files"]}</td><td class="n">{D[k]["size"]["median"]:.0f}</td>'
    f'<td class="n" title="{e(D[k]["size"]["bigname"])}">{num(D[k]["size"]["big"])} <span class="muted">{e(os.path.basename(D[k]["size"]["bigname"]))}</span></td>'
    + (f'<td class="n">{D[k]["dup_code"]["pct"]:.1f}%</td><td class="n">{D[k]["dup_all"]["pct"]:.1f}%</td><td class="n">{D[k]["dup_all"]["clones"]}</td>' if D[k]["dup_all"] else "<td></td><td></td><td></td>")
    + "</tr>" for k in D)

churn_rows = "".join(
    f'<tr><td>{sw(k)}{e(full(k))}</td><td class="n">{num(tot_add(k))}</td><td class="n">{num(tot_del(k))}</td><td class="n">{rework(k) * 100:.0f}%</td>'
    f'<td class="n">{num(later_del(k))}</td><td class="n">{mod_share(k) * 100:.0f}%</td>'
    f'<td class="n">{max(TICKETS[1:], key=lambda n: D[k]["t"][n]["deleted"])}: −{num(max(D[k]["t"][n]["deleted"] for n in TICKETS[1:]))}</td>'
    f'<td>{", ".join("т" + n for n in noop(k)) or "—"}</td></tr>' for k in D)

tk_head = "<tr><th>Тикет</th>" + "".join(f'<th class="n">{e(full(k))}</th>' for k in D) + "</tr>"
tk_rows = ""
for n in TICKETS:
    tk_rows += f"<tr><td>т{n}</td>" + "".join(
        f'<td class="n" title="файлов: новых {D[k]["t"][n]["new"]}, изменённых {D[k]["t"][n]["mod"]}, удалённых {D[k]["t"][n]["gone"]}">'
        f'+{num(D[k]["t"][n]["added"])} <span class="del">−{num(D[k]["t"][n]["deleted"])}</span> <span class="muted">{D[k]["t"][n]["mod"]}ф</span></td>' for k in D) + "</tr>"

top_del = int(max(D[k]["t"][n]["deleted"] for k in D for n in TICKETS[1:]) / 100 + 1) * 100

PAGE = f"""<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Syncbox: код реализаций</title><style>
body{{background:var(--agterm-background,Canvas);color:var(--agterm-foreground,CanvasText);font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;margin:0}}
.page{{--fg:var(--agterm-foreground,CanvasText);--s:var(--agterm-color-4,#2a78d6);--o:var(--agterm-color-5,#a44fc4);--o4:var(--agterm-color-3,#c08a12);--f:var(--agterm-color-6,#1a8f9c);--f4:var(--agterm-color-14,#4fb3bf);
--muted:color-mix(in srgb,var(--fg) 62%,transparent);--line:color-mix(in srgb,var(--fg) 15%,transparent);--panel:color-mix(in srgb,var(--fg) 5%,transparent);max-width:1180px;margin:0 auto;padding:28px 24px 60px}}
h1{{font-size:24px;margin:0 0 4px;line-height:1.25}} h2{{font-size:17px;margin:38px 0 6px;padding-top:18px;border-top:1px solid var(--line)}} h3{{font-size:13px;margin:0 0 10px;font-weight:600}}
p{{margin:6px 0;max-width:88ch}} .sub,.note,.muted{{color:var(--muted)}} .note{{font-size:12px;margin-top:8px}} code{{font:12px ui-monospace,Menlo,monospace}}
.tiles{{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin:18px 0}}
.tile,.card{{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:14px 16px}}
.tile b{{display:block;font-size:24px;line-height:1.15;font-variant-numeric:tabular-nums}} .tile span{{color:var(--muted);font-size:12px}}
.grid2{{display:grid;grid-template-columns:repeat(auto-fit,minmax(420px,1fr));gap:12px;margin:10px 0}}
.hb{{display:grid;grid-template-columns:130px 1fr 76px;gap:10px;align-items:center;margin:4px 0}} .hl i{{display:block;font-style:normal;font-size:11px;color:var(--muted);line-height:1.1}}
.ht{{height:12px}} .hf{{display:block;height:12px;border-radius:0 4px 4px 0;min-width:2px}} .hv{{text-align:right;font-variant-numeric:tabular-nums}}
.s{{background:var(--s);fill:var(--s)}} .o{{background:var(--o);fill:var(--o)}} .o4{{background:var(--o4);fill:var(--o4)}} .f{{background:var(--f);fill:var(--f)}} .f4{{background:var(--f4);fill:var(--f4)}}
.legend{{display:flex;flex-wrap:wrap;gap:6px 18px;margin:12px 0;font-size:12px}} .sw{{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:6px}}
svg{{width:100%;height:auto;display:block}} .grid{{stroke:var(--line);stroke-width:1}} .base{{stroke:var(--muted);stroke-width:1}} .ax{{fill:var(--muted);font-size:10px}} svg path:hover{{opacity:.75}}
.tw{{overflow-x:auto;margin:10px 0}} table{{border-collapse:collapse;width:100%;font-size:12.5px}} th,td{{padding:5px 9px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}}
th{{color:var(--muted);font-weight:500}} td.n,th.n{{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}} .del{{color:var(--muted)}}
ul{{margin:6px 0;padding-left:20px;max-width:88ch}} li{{margin:3px 0}}
</style></head><body><div class="page">
<h1>Syncbox: код одиннадцати реализаций</h1>
<p class="sub">Формальные критерии по снимкам кода после каждого тикета, без запуска реализаций: размер, переделки и локальность правок по тикетам, дублирование. Четыре прогона Sonnet 5 (кампания автора), пять Opus 5.5 и два Fable 5.1 (наши кампании). n = 1 на ячейку — наблюдения, не выводы.</p>

<div class="tiles">
<div class="tile"><b>{num(min(D[k]["size"]["code"] for k in D))} – {num(max(D[k]["size"]["code"] for k in D))}</b><span>строк кода после тикета 11, от {e(full(min(D, key=lambda k: D[k]["size"]["code"])))} до {e(full(max(D, key=lambda k: D[k]["size"]["code"])))}</span></div>
<div class="tile"><b>{min(rework(k) for k in D) * 100:.0f}% – {max(rework(k) for k in D) * 100:.0f}%</b><span>переделки: удалённых строк к добавленным за 11 тикетов; меньше всего у {e(full(min(D, key=rework)))}, больше всего у {e(full(max(D, key=rework)))}</span></div>
<div class="tile"><b>{min(D[k]["dup_code"]["pct"] for k in D) if not args.no_jscpd else 0:.1f}% – {max(D[k]["dup_code"]["pct"] for k in D) if not args.no_jscpd else 0:.1f}%</b><span>дублирование в коде без тестов (jscpd, ≥5 строк и ≥50 токенов)</span></div>
<div class="tile"><b>{num(max(D[k]["size"]["big"] for k in D))}</b><span>самый большой файл: {e(D[max(D, key=lambda k: D[k]["size"]["big"])]["size"]["bigname"])} у {e(full(max(D, key=lambda k: D[k]["size"]["big"])))}</span></div>
</div>

<h2>Метод</h2>
<ul>
<li><b>Снимки.</b> Канонический код после каждого тикета из <code>docs/pilot-runs/</code>: у автора — по <code>manifest.json</code>, у нас — последняя итерация ячейки. Учитываются файлы кода (<code>.rb .py .js .ts</code>, скрипты в <code>bin/</code>), тесты (каталоги <code>test</code>, <code>tests</code>, <code>spec</code>, тестовые имена) и инфраструктура (Dockerfile, compose, <code>run-*</code>, манифесты зависимостей). Копии спецификации, README и lock-файлы не считаются. Строки — без пустых.</li>
<li><b>Переделки.</b> Diff между снимками соседних тикетов (<code>difflib</code> по непустым строкам): добавлено, удалено, файлов новых и изменённых. Весь код написан агентом, поэтому каждая удалённая строка — переделка собственного кода. «Доля переделок» = удалено / добавлено за 11 тикетов.</li>
<li><b>Локальность.</b> Доля существующих файлов, которые тикет изменил (среднее по тикетам 2–11). Чем ниже, тем точечнее правки.</li>
<li><b>Дублирование.</b> jscpd {JSCPD_VER} на финальном снимке: доля дублированных строк, отдельно без тестов и с тестами. Одна метрика на все четыре языка.</li>
<li>Чего здесь нет: сложности функций, линтеров и сканеров безопасности — их результаты зависят от инструмента конкретного языка (автор по этой причине исключил bandit/gosec); mutation score и поведенческих проверок — они требуют запуска реализаций.</li>
</ul>

<h2>Размер и дублирование после тикета 11</h2>
{legend}
<div class="tw"><table><tr><th>Прогон</th><th class="n">код</th><th class="n">тесты</th><th class="n">инфра</th><th class="n">файлов</th><th class="n">медианный файл</th><th class="n">самый большой файл</th><th class="n">дубли, код</th><th class="n">дубли, код + тесты</th><th class="n">клонов</th></tr>{size_rows}</table></div>
<div class="grid2">
{hbars("Строк кода (без тестов) после тикета 11", lambda k: D[k]["size"]["code"], num)}
{hbars("Строк тестов после тикета 11", lambda k: D[k]["size"]["test"], num)}
{hbars("Дублирование в коде без тестов, %", lambda k: D[k]["dup_code"]["pct"] if D[k]["dup_code"] else 0, lambda v: f"{v:.1f}%")}
{hbars("Дублирование с тестами, %", lambda k: D[k]["dup_all"]["pct"] if D[k]["dup_all"] else 0, lambda v: f"{v:.1f}%", "Тесты дублируют сильнее кода: повторяющиеся setup-блоки и похожие сценарии.")}
</div>

<h2>Переделки и локальность по тикетам</h2>
<div class="tw"><table><tr><th>Прогон</th><th class="n">добавлено за 11 тикетов</th><th class="n">удалено</th><th class="n">доля переделок</th><th class="n">удалено на т2–т11</th><th class="n">изменённых файлов на тикет</th><th class="n">самый большой откат</th><th>тикеты без правок кода</th></tr>{churn_rows}</table></div>
<div class="grid2">
{hbars("Доля переделок: удалено / добавлено", rework, lambda v: f"{v * 100:.0f}%")}
{hbars("Локальность: доля существующих файлов, изменённых тикетом", mod_share, lambda v: f"{v * 100:.0f}%", "Среднее по тикетам 2–11. Тикет 1 создаёт проект, в нём нечего менять.")}
</div>
<h3 style="margin-top:18px">Удалённые строки по тикетам, Ruby</h3>
<div class="grid2">
{grouped("Ruby 3: удалено строк на тикете", RUBY3, "deleted", lambda v: f"{v:.0f}", top_del, top_del // 5 or 1)}
{grouped("Ruby 4: удалено строк на тикете", RUBY4, "deleted", lambda v: f"{v:.0f}", top_del, top_del // 5 or 1)}
</div>
<h3 style="margin-top:18px">Все прогоны: добавлено, удалено, изменённых файлов</h3>
<div class="tw"><table>{tk_head}{tk_rows}</table></div>
<p class="note">Ячейка: +добавлено −удалено Nф — число существующих файлов, которые тикет изменил. Подробности о новых и удалённых файлах — по наведению.</p>

<h2>Что видно</h2>
<ul>
<li>Размер кода без тестов отличается в {max(D[k]["size"]["code"] for k in D) / min(D[k]["size"]["code"] for k in D):.1f} раза между самым компактным и самым объёмным прогоном при одинаковой спецификации и зелёных проверках у всех.</li>
<li>Доля переделок — от {min(rework(k) for k in D) * 100:.0f}% до {max(rework(k) for k in D) * 100:.0f}%. Это переписывание собственного кода на следующих тикетах; низкая доля при большом объёме означает, что архитектура тикета 1 выдержала весь бэклог.</li>
<li>Тесты дублируются сильнее кода у всех прогонов; по коду без тестов разброс {min(D[k]["dup_code"]["pct"] for k in D) if not args.no_jscpd else 0:.1f}–{max(D[k]["dup_code"]["pct"] for k in D) if not args.no_jscpd else 0:.1f}%.</li>
<li><b>Тикеты без правок кода.</b> {"; ".join(f"{e(full(k))}: {', '.join('т' + n for n in noop(k))}" for k in D if noop(k))}. Это тикеты, чью функциональность агент сделал раньше: контрактный тест блокирует тикет 1, пока не реализованы <code>GET /blobs</code> и <code>PUT</code>, и часть агентов реализует на тикете 1 всю работу с блобами. Границы тикетов (риск 2 у автора) здесь измеримы, а стоимость таких тикетов в сравнениях по тикетам — не стоимость их реализации.</li>
<li>Эти критерии детерминированы и повторяемы, в отличие от токенов и времени, но измеряют форму кода, а не его поведение. Следующий слой — поведенческие проверки одним набором сценариев против всех реализаций и mutation score тестов.</li>
</ul>
</div></body></html>"""
Path(args.out).write_text(PAGE)
print(args.out, len(PAGE), "байт")
