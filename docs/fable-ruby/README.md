# Кампания Fable 5.1 × Ruby 3 / Ruby 4

Повтор кампании [Opus 5.5 × Ruby](../opus-ruby/README.md) на модели
`claude-fable-5-1`. Всё остальное то же: effort `high`, Claude Code
2.1.288, `--disallowedTools WebFetch,WebSearch`, гейты `tests` и
`contract` блокирующие, `smoke` информационный, до 4 вызовов модели на
тикет.

## Ячейки

| Тег языка     | Ruby   | Базовый образ |
| ------------- | ------ | ------------- |
| `ruby3-fable` | 3.3.12 | `ruby:3.3.12` |
| `ruby4-fable` | 4.0.7  | `ruby:4.0.7`  |

Промпты побайтно совпадают с промптами кампании Opus 5.5 × Ruby
(`docs/opus-ruby/prompts/`), так что между двумя кампаниями отличается
только модель.

## Запуск

```sh
PILOT_ACK_OPEN_WEB=1 scripts/run-fable-ruby.sh --dry-run
PILOT_ACK_OPEN_WEB=1 scripts/run-fable-ruby.sh --force-clean   # кампания: 22 ячейки
```

После прогона:

```sh
scripts/check-web-access.py docs/pilot-runs/ruby3-fable docs/pilot-runs/ruby4-fable
grep -h '^FROM' docs/pilot-runs/ruby{3,4}-fable/ticket-*/*/code/Dockerfile | sort | uniq -c
```

## Ограничения

- `n = 1` на ячейку.
- Сеть контейнера открыта; выход агента в интернет проверяется по
  транскриптам после прогона. Репозиторий с решениями прошлых кампаний
  публичный.
