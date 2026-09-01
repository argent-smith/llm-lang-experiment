#!/usr/bin/env python3
"""gates.json (от scripts/run-gates.sh) -> промпт-симптом для следующего
вызова `claude -p` в авто-итерирующем лупе (scripts/run-pilot-loop.sh).

Ключевое требование метода (CLAUDE.md, раздел «Метод», п. 3): пилотный
агент не должен видеть ни путей внутри мета-репозитория, ни имён
acceptance-скриптов, ни того, что проверку гоняет Schemathesis. Промпт
описывает СИМПТОМ так, как его увидел бы разработчик, гоняющий сервер
руками. Санитайзинг:
  - абсолютные пути на хосте вырезаются;
  - имена служебных скриптов/инструментов заменяются на нейтральные;
  - конкретный http://127.0.0.1:<port> -> http://<server>.

Использование:
  build-fix-prompt.py <gates.json> --tickets-done <N> [--iteration <k>]
"""
import argparse
import json
import re
import sys

CENSOR = [
    (re.compile(r"/Users/[^\s\"']+"), "<путь>"),
    (re.compile(r"\bacceptance/[A-Za-z0-9_.-]+"), "внешняя проверка"),
    (re.compile(r"\bschemathesis\b", re.I), "формальная проверка по схеме"),
    (re.compile(r"\bpilot-runs[A-Za-z0-9_/.-]*"), "<архив>"),
    (re.compile(r"\bllm-lang-experiment\b"), "<репозиторий>"),
    (re.compile(r"\breference-impl\b"), "<эталон>"),
    (re.compile(r"http://127\.0\.0\.1:\d+"), "http://<server>"),
    (re.compile(r"http://localhost:\d+"), "http://<server>"),
]


def sanitize(text: str) -> str:
    for pat, repl in CENSOR:
        text = pat.sub(repl, text)
    return text.strip()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("gates_json")
    ap.add_argument("--tickets-done", type=int, required=True)
    ap.add_argument("--iteration", type=int, default=2)
    args = ap.parse_args()

    with open(args.gates_json) as fh:
        g = json.load(fh)

    gates = g.get("gates", {})
    blocking = set(g.get("blocking_failed", []))
    n = args.tickets_done

    out = []
    out.append(
        f"Внешняя проверка текущей реализации (тикеты 1-{n} уже сделаны в этом "
        f"же репозитории) нашла несоответствия. Нужно исправить их по существу, "
        f"не трогая ничего сверх этого."
    )

    contract = gates.get("contract", {})
    if contract.get("status") == "fail" and "contract" in blocking:
        out.append(
            "\nФормальная проверка HTTP-поверхности сервера по схеме API — "
            "перебором мусорных и граничных значений key — нашла ответы вне "
            "контракта:"
        )
        for f in contract.get("failures", []):
            meth = f.get("method", "?")
            path = f.get("path", "?")
            recv = f.get("received", "?")
            doc = f.get("documented", "").strip()
            line = f"\n- {meth} {path}: сервер вернул {recv}"
            if doc:
                line += f", а операция в схеме объявляет только {doc}"
            line += "."
            rep = sanitize(f.get("reproduce", ""))
            if rep:
                line += f"\n  Воспроизведение:\n      {rep}"
            if f.get("server_error"):
                line += "\n  (это 5xx — сервер не должен падать ни на каком значении key)"
            out.append(line)
        out.append(
            "\nОриентир — список ответов каждой операции в syncbox-openapi.yaml "
            "(в корне репозитория); ответ на любое значение key обязан быть из "
            "этого списка, 5xx недопустим ни на каком входе. Обрабатывай класс "
            "проблемы, не хардкодь конкретные байтовые последовательности из "
            "примеров. Правки допустимы только в коде реализации — файлы "
            "спецификации (SYNCBOX-SPEC.md, syncbox-openapi.yaml) не трогай, "
            "это внешний контракт."
        )

    smoke = gates.get("smoke", {})
    if smoke.get("status") == "fail" and "smoke" in blocking:
        steps = ", ".join(smoke.get("failed_steps", [])) or "(имена шагов не распознаны)"
        out.append(
            f"\nСценарная проверка через run-server/run-client провалила шаги: "
            f"{steps}. Последние строки вывода:\n\n"
            + "\n".join("    " + ln for ln in sanitize(smoke.get("detail_tail", "")).splitlines())
        )

    tests = gates.get("tests", {})
    if tests.get("status") in ("fail", "error") and "tests" in blocking:
        out.append(
            "\nШтатные тесты (run-tests) не прошли. Последние строки:\n\n"
            + "\n".join("    " + ln for ln in sanitize(tests.get("detail_tail", "")).splitlines())
        )

    out.append(
        "\nПосле фикса добавь тесты на эти случаи и перепроверь сам — подними "
        "сервер через run-server и прогони run-tests. Не меняй ничего, что не "
        "относится к перечисленным несоответствиям."
    )

    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
