"""Общее для генераторов отчётов: прогоны, снимки кода по тикетам,
классификация файлов реализации."""
import glob
import json
import os
import re
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TICKETS = [str(i) for i in range(1, 12)]

# ключ, язык, модель, подпись версии, css-класс, (источник, тег)
RUNS = [
    ("py-s", "Python", "Sonnet 5", "", "s", ("manifest", "python")),
    ("py-o", "Python", "Opus 5.5", "", "o", ("replay", "python-opus")),
    ("js-s", "JavaScript", "Sonnet 5", "", "s", ("manifest", "javascript")),
    ("js-o", "JavaScript", "Opus 5.5", "", "o", ("replay", "javascript-opus")),
    ("ts-s", "TypeScript", "Sonnet 5", "", "s", ("manifest", "typescript")),
    ("ts-o", "TypeScript", "Opus 5.5", "", "o", ("replay", "typescript-opus")),
    ("rb-s", "Ruby", "Sonnet 5", "3.3", "s", ("manifest", "ruby")),
    ("rb3-o", "Ruby", "Opus 5.5", "3.3.12", "o", ("replay", "ruby3-opus")),
    ("rb4-o", "Ruby", "Opus 5.5", "4.0.7", "o4", ("replay", "ruby4-opus")),
    ("rb3-f", "Ruby", "Fable 5.1", "3.3.12", "f", ("replay", "ruby3-fable")),
    ("rb4-f", "Ruby", "Fable 5.1", "4.0.7", "f4", ("replay", "ruby4-fable")),
]
META = {k: dict(lang=l, model=m, ver=v, cls=c, src=s) for k, l, m, v, c, s in RUNS}


def name(k):
    return META[k]["lang"] + (f" {META[k]['ver']}" if META[k]["ver"] else "")


def full(k):
    return f"{name(k)} · {META[k]['model']}"


def snapshots(k):
    """{тикет: путь к code/} — канонический снимок после тикета."""
    src, tag = META[k]["src"]
    if src == "manifest":
        man = json.load(open(REPO / "docs/pilot-runs/manifest.json"))["languages"][tag]["tickets"]
        return {n: str(REPO / man[n] / "code") for n in TICKETS}
    roots = [r for r in sorted(glob.glob(str(REPO / "pilot-runs-live/.replay-*")))
             if os.path.exists(f"{r}/checkpoint.json")
             and tag in (json.load(open(f"{r}/checkpoint.json")).get("campaign") or {}).get("languages", [])]
    ck = json.load(open(f"{roots[-1]}/checkpoint.json"))
    out = {}
    for c in ck["cells"]:
        if c["lang"] == tag:
            last = json.load(open(c["loop_json"]))["iterations"][-1]["session"]
            out[str(c["ticket"])] = str(REPO / f"docs/pilot-runs/{tag}/ticket-{c['ticket']}/{last}/code")
    return out


SRC_EXT = (".rb", ".py", ".js", ".mjs", ".cjs", ".ts")
TEST_RE = re.compile(r"(^|/)(tests?|spec|__tests__)/|(^|/)test_[^/]*\.py$|[._](test|spec)\.[cm]?[jt]s$|_test\.(py|rb)$|_spec\.rb$")
SKIP_RE = re.compile(r"(^|/)(node_modules|dist|build|\.venv|__pycache__|\.git)/")
INFRA_RE = re.compile(r"(^|/)(Dockerfile[^/]*|docker-compose[^/]*\.ya?ml|compose[^/]*\.ya?ml|run-server|run-client|run-tests|Rakefile|Makefile|Gemfile|package\.json|pyproject\.toml|requirements[^/]*\.txt|tsconfig[^/]*\.json)$")
SPEC_FILES = {"SYNCBOX-SPEC.md", "syncbox-openapi.yaml"}


def classify(rel):
    """code | test | infra | None (прочее: README, lock-файлы, копии спецификации)."""
    if SKIP_RE.search(rel) or os.path.basename(rel) in SPEC_FILES:
        return None
    if rel.endswith(SRC_EXT) or re.search(r"(^|/)(bin|exe)/[^/.]+$", rel):
        return "test" if TEST_RE.search(rel) else "code"
    if INFRA_RE.search(rel):
        return "infra"
    return None


def files(code):
    """{относительный путь: класс} для всех учитываемых файлов снимка."""
    out = {}
    for f in glob.glob(code + "/**/*", recursive=True):
        if os.path.isfile(f):
            rel = f[len(code) + 1:]
            c = classify(rel)
            if c:
                out[rel] = c
    return out


def loc(path):
    try:
        return sum(1 for l in open(path, errors="replace") if l.strip())
    except OSError:
        return 0
