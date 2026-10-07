# Кампания Opus 5.5 × Python / JavaScript / TypeScript

Продолжение кампании [Opus 5.5 × Ruby](../opus-ruby/README.md): остальные
три языка доклада на той же модели и той же конфигурации. Вместе с
`ruby3-opus` получается сетка из четырёх языков на Opus 5.5, сопоставимая
с сеткой основной кампании на Sonnet 5.

## Ячейки

| Тег языка         | Среда       | Базовый образ           |
| ----------------- | ----------- | ----------------------- |
| `python-opus`     | Python 3.12 | `python:3.12-slim`      |
| `javascript-opus` | Node.js 20  | `node:20-alpine`        |
| `typescript-opus` | Node.js 20  | `node:20-bookworm-slim` |

Образы — те, что агент на Sonnet 5 сам выбрал в основной кампании (все
канонические тикеты 1–11 каждого языка). Здесь они закреплены абзацем в
конце каждого промпта, как версия Ruby в кампании Ruby: обработка
промптов одинакова для всех четырёх языков на Opus 5.5, а образы
предзагружены. Версия самого TypeScript не закреплена — как и в основной
кампании, её выбирает агент.

Пара для Ruby в этой сетке — `ruby3-opus` (Ruby 3.3.12, тот же Ruby, что в
основной кампании).

## Конфигурация

Та же, что в кампании Ruby: `claude-opus-5-5`, effort `high`, Claude Code
2.1.288, `--disallowedTools WebFetch,WebSearch`, гейты `tests` и `contract`
блокирующие, `smoke` информационный, до 4 вызовов модели на тикет.
Отличия от основной кампании перечислены в
[docs/opus-ruby/README.md](../opus-ruby/README.md).

## Запуск

```sh
scripts/build-base-images-tar.sh                          # пересобрать: добавлены node:20-alpine и node:20-bookworm-slim
PILOT_ACK_OPEN_WEB=1 scripts/run-opus-langs.sh --dry-run
PILOT_ACK_OPEN_WEB=1 scripts/run-opus-langs.sh --force-clean   # кампания: 33 ячейки
```

После прогона:

```sh
scripts/check-web-access.py docs/pilot-runs/python-opus docs/pilot-runs/javascript-opus docs/pilot-runs/typescript-opus
grep -h '^FROM' docs/pilot-runs/{python,javascript,typescript}-opus/ticket-*/*/code/Dockerfile | sort | uniq -c
```

Промпты пересобираются так:

```sh
scripts/make-pinned-prompts.py --out docs/opus-langs/prompts --source-lang python --target-lang python-opus --version "Python 3.12" --image python:3.12-slim
scripts/make-pinned-prompts.py --out docs/opus-langs/prompts --source-lang javascript --target-lang javascript-opus --version "Node.js 20" --image node:20-alpine
scripts/make-pinned-prompts.py --out docs/opus-langs/prompts --source-lang typescript --target-lang typescript-opus --version "Node.js 20" --image node:20-bookworm-slim
```

## Ограничения

- `n = 1` на ячейку.
- Образы закреплены плавающими тегами (`3.12-slim`, `20-alpine`), как в
  основной кампании, а не точной версией, как Ruby: патч-версия зависит от
  дня сборки `base-images.tar`.
- В основной кампании предзагружен был `node:22-alpine`, а агент брал
  `node:20-*`, то есть образ скачивался во время прогона. Здесь оба образа
  предзагружены, поэтому время сборки с основной кампанией напрямую не
  сравнимо.
- Сеть контейнера открыта; выход агента в интернет проверяется по
  транскриптам после прогона.

## Отчёты по коду всех кампаний

Два отчёта поверх снимков кода всех одиннадцати прогонов (четыре Sonnet 5,
пять Opus 5.5, два Fable 5.1), статические HTML без JS:

- [code-report.html](code-report.html) — формальные критерии без запуска
  кода: размер, переделки и локальность правок по тикетам, дублирование
  (jscpd). Генератор — `scripts/make-code-report.py` (общее для отчётов —
  `scripts/campaignlib.py`).
- [mutation-report.html](mutation-report.html) — mutation score штатных
  тестов пяти Ruby-реализаций (mutant 0.17 внутри Docker-образа каждой
  реализации). Прогон — `scripts/mutation/run-campaign.sh`, архив
  результатов — [mutation/](mutation/) (по ключу прогона: итоги, список
  методов и выборка, число мутаций на метод, отчёт mutant без строк
  прогресса; `root-run/` — отвергнутое первое измерение под root для
  оценки воспроизводимости). Генератор — `scripts/make-mutation-report.py`.
  У Opus и Fable наборы тестов идут 10–30 с на прогон, поэтому мутации
  гоняются по случайной выборке 25% методов (seed 42); у Sonnet — по всем.
