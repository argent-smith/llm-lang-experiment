# Кампания Fable 5.1 × Ruby 3 / Ruby 4

Ответвление основного эксперимента. Переменная — не язык, а версия Ruby
при фиксированной модели `claude-fable-5-1`. Бэклог тот же (тикеты 1–11),
харнесс тот же (DinD, авто-луп, гейты), отличия перечислены ниже.

## Ячейки

| Тег языка     | Ruby   | Базовый образ |
| ------------- | ------ | ------------- |
| `ruby3-fable` | 3.3.12 | `ruby:3.3.12` |
| `ruby4-fable` | 4.0.7  | `ruby:4.0.7`  |

Ruby 3 — тот же, что в основной кампании: там агент на Sonnet 5 во всех
11 канонических тикетах выбрал `FROM ruby:3.3` (полный образ, не slim), в
транскриптах — `ruby 3.3.12`. Ruby 4 — последний релиз на 2026-10-03.
Оба образа полные и закреплены точной версией, чтобы ячейки отличались
только версией Ruby. Тег языка — имя pilot-директории, поэтому
архивы ложатся в `docs/pilot-runs/ruby3-fable/` и
`docs/pilot-runs/ruby4-fable/` и не смешиваются с `docs/pilot-runs/ruby/`.

## Отличия от основной кампании

- **Модель:** `claude-fable-5-1` вместо `claude-sonnet-5`.
- **Effort:** `high` вместо `xhigh`.
- **Веб-инструменты:** `--disallowedTools WebFetch,WebSearch`. `curl` из
  Bash по-прежнему открыт, поэтому гард `PILOT_ACK_OPEN_WEB` остаётся, а
  результаты формально не чистые (CLAUDE.md, «Сначала пилот», пункт 4).
- **Промпты:** канонические initial-промпты Ruby (тот же выбор, что у
  `run-pilot-replay.sh`) плюс один абзац в конце, фиксирующий версию и
  базовый образ. Абзац одинаковый во всех тикетах. Фикс-промпты лупа
  (`build-fix-prompt.py`) не меняются.

## Запуск

Предпосылки — как для основного харнесса (`docs/RUNBOOK.md`): Docker,
`python3`, `scripts/pilot-harness.env` с `CLAUDE_CODE_OAUTH_TOKEN`
(подписка, `claude setup-token`). В подписке должна быть доступна
Fable 5.1 в Claude Code.

```sh
scripts/build-base-images-tar.sh                          # один раз: предзагрузка образов, включая ruby:3.3.12 и ruby:4.0.7
PILOT_ACK_OPEN_WEB=1 scripts/run-fable-ruby.sh --check-prompts
PILOT_ACK_OPEN_WEB=1 scripts/run-fable-ruby.sh --dry-run
PILOT_ACK_OPEN_WEB=1 scripts/run-fable-ruby.sh            # кампания: 22 ячейки
```

При исчерпании оконного лимита подписки (`429`) кампания сама ждёт сброса;
после жёсткого стопа — `--resume --checkpoint <out-root>/checkpoint.json`.
После прогона проверить каждую сессию `scripts/verify-replay.py` и убедиться
по `code/Dockerfile` в архиве, что агент не сменил базовый образ.

Промпты пересобираются так:

```sh
scripts/make-pinned-prompts.py --source-lang ruby --target-lang ruby3-fable --version "Ruby 3.3.12" --image ruby:3.3.12
scripts/make-pinned-prompts.py --source-lang ruby --target-lang ruby4-fable --version "Ruby 4.0.7" --image ruby:4.0.7
```

## Ограничения

- `n = 1` на ячейку, как и в основной кампании.
- Сравнение с основной кампанией по Ruby меняет сразу три фактора: модель,
  effort и наличие абзаца о версии в промпте. Чистое сравнение внутри этой
  кампании — только Ruby 3.3.12 против Ruby 4.0.7.
- Время сборки не сравнимо с основной кампанией напрямую: там `ruby:3.3`
  не был предзагружен (холодная сборка около 100 секунд на тикет, README
  репозитория, «Известные ограничения»), здесь оба образа предзагружены.
