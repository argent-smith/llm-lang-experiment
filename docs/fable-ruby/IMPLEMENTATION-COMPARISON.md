# Syncbox на Ruby: как три агента решили одни и те же тикеты

Сравнение по снимкам кода после тикетов 1, 5, 6, 7 и 11 трёх реализаций
на Ruby 3: Sonnet 5 (основная кампания), Opus 5.5 и Fable 5.1 (наши
кампании). Пути ниже — относительно `docs/pilot-runs/<прогон>/ticket-N/<сессия>/code`.
Только факты из кода; оценок «кто лучше» нет — решения и их последствия.

## 1. Структура и Docker

|            | Sonnet 5                                                                                                                         | Opus 5.5                                                                                                                                            | Fable 5.1                                                                                                                 |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Раскладка  | `server/{main,config,app}.rb`, `client/*.rb` + скрипт `client/syncbox` с шебангом. Нет `lib/`, нет гема                          | `lib/syncbox/server/{app,store,config,runner}.rb`, `lib/syncbox/client/*` (10 файлов), `bin/syncbox`, `bin/syncbox-server`, Rakefile                | `lib/syncbox/{app,store,server,server_cli,config}.rb`, `lib/syncbox/client/*` (12 файлов), `bin/`, Rakefile, `version.rb` |
| Dockerfile | `ruby:3.3`, одна стадия, без `USER`, `CMD ruby server/main.rb`                                                                   | `ruby:3.3.12`, `BUNDLE_FROZEN`, одна стадия                                                                                                         | `ruby:3.3.12`, `HOME=/tmp`, `chmod 0777 /data`, `EXPOSE`, одна стадия. Комментарии по-русски                              |
| compose    | `docker-compose.yml`: `server`, `client`, `tests`. Пользователь не задан, то есть root. Volume `${SYNCBOX_DATA_DIR:-/tmp}:/data` | `compose.yaml` с якорем `x-app`, `user: ${SYNCBOX_UID}:${SYNCBOX_GID}`, `init: true`. У клиента `network_mode: host`, для `status` есть `read_only` | Якорь `x-ruby`, uid/gid хоста. У клиента `network_mode: host`, для push и status каталог монтируется `:ro`                |
| run-server | `docker compose up --build --abort-on-container-exit server`                                                                     | `compose run --rm --service-ports --name …` в фоне + `trap`, который сам делает `docker stop` (комментарий: «compose run does not forward SIGTERM») | `compose run … &` с отдельным проектом на каждый порт (`-p syncbox-$port`) + `trap` и `down`                              |
| run-client | `compose run --rm client`. URL `localhost`/`127.0.0.1` переписывается регуляркой на `host.docker.internal` (`extra_hosts`)       | Валидирует аргументы, `-T`, пробрасывает сигналы                                                                                                    | Каждый вызов получает свой проект `syncbox-client-$$-$RANDOM`                                                             |
| run-tests  | `compose run --build --rm tests`                                                                                                 | `compose build` + `run --rm tests`                                                                                                                  | `compose run --rm --build -T test` + `trap cleanup EXIT`                                                                  |

Multi-stage сборки нет ни у кого. Агенты выбрали эти схемы уже в т1 и дальше их не меняли.

## 2. Библиотеки

- **Sonnet:** Sinatra 4 + Puma + rackup, RSpec, rack-test, WebMock. Чтобы не получить 404 вместо 400, пришлось отключить `set :protection, except: [:path_traversal]` и `host_authorization`. HTTP-клиент — `Net::HTTP.start` с новым соединением на каждый запрос.
- **Opus:** чистый Rack 3 + Puma, сервер запускается через `Puma::Launcher` в `runner.rb`. Тесты на Minitest + rack-test. HTTP-клиент — `Net::HTTP` с одним keep-alive соединением, `max_retries = 0`, `ignore_eof = false`.
- **Fable:** тоже чистый Rack + Puma, но с собственным мини-роутером `Route = Struct.new(:method, :pattern, :handler)`, ответом 405 и заголовком `allow`. Тесты на Minitest. Клиент на `Net::HTTP` с keep-alive и тремя таймаутами.

## 3. Тикет 5: проверка key

- **Sonnet** (`blob_key_valid?` + `resolve_blob_path` в `app.rb`). Запрещено: пустой key, невалидная кодировка, `\u0000`, сегменты `""`, `.`, `..`. Дальше идёт `File.expand_path` и проверка префикса корня. `realpath` и проверки символических ссылок нет. Абсолютный путь отсекается неявно, через пустой первый сегмент. Ответ — `halt 400`. В т11 добавлен запрет префикса `.syncbox-tmp-`.
- **Opus** (`Store.validate_key`). Ключ приводится `key.b.force_encoding(UTF_8)` и проверяется на UTF-8, NUL и сегменты `""`, `.`, `..`. Отдельно проверяются `NAME_MAX`/`PATH_MAX`. Затем `blob_path` (expand_path по байтам, `start_with?("#{@blobs_dir}/")`) и `confined_on_disk?`: `realpath` самого глубокого существующего каталога должен совпасть с ожидаемым путём. Поэтому запрещён любой symlink, даже ведущий внутрь хранилища. Открытие идёт с `File::NOFOLLOW`. Ошибки ФС (`ENAMETOOLONG`, `EILSEQ` и др.) превращаются в `InvalidKeyError`. Ответ — 400 с текстом.
- **Fable** (`validate_key` + `path_for`). Проверки по сути те же, плюс явная `start_with?("/")` и зарезервированный первый сегмент `.syncbox-tmp`. Второй слой: `realpath` самого длинного существующего префикса. Symlink внутри корня разрешён, наружу — нет, цикл ссылок даёт 400. Ответ — JSON `{"error":"invalid_key","message":…}`. Плюс есть общий `rescue StandardError` → 500 с логом.

Ключ не нормализует никто: невалидный ключ отклоняется целиком.

## 4. Тикет 6: атомарная запись

|                     | Sonnet                                                      | Opus                                                                | Fable                                               |
| ------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------- | --------------------------------------------------- |
| Временный файл      | `.syncbox-tmp-<hex>` в том же каталоге, что и цель          | `<data>/tmp/<hex>.part`. Блобы лежат в `<data>/blobs/`              | `<data>/.syncbox-tmp/<hex>.tmp`                     |
| Запись              | `request.body.read` целиком в память, затем `File.binwrite` | Потоково кусками по 64 КБ, `O_EXCL`, `fsync`                        | Потоково, `O_EXCL`, `fsync` (`flush_to_disk`)       |
| fsync каталога      | нет                                                         | нет                                                                 | нет                                                 |
| flock/Mutex         | нет                                                         | нет                                                                 | Mutex только для кэша хешей                         |
| Гонка с DELETE      | нет                                                         | `make_parent_dirs` + повторы до 100 раз (`PUT_ATTEMPTS`)            | `move_into_place`, 5 повторов при `ENOENT`/`EEXIST` |
| Мусор после падения | `ensure File.delete`                                        | `prepare!` чистит `*.part` при старте; есть проба rename на `EXDEV` | `remove_stale_tmp_files` при старте                 |

Параллельные PUT по одному ключу везде решены одинаково: побеждает последний `rename`, без блокировок.

Тесты на гонку:

- **Sonnet** (`spec/app_spec.rb`): `Rack::MockRequest`, 2 потока-писателя по 8 PUT и 4 потока-читателя. Проверка `/\A(a+|b+)\z/`.
- **Opus** (`atomic_put_test.rb`): `TrickleIO` с `Thread.pass` между кусками и `File.singleton_class.prepend(RenameInterception)` — перехват rename через хук в thread-local. Есть тесты на ENOSPC и EXDEV.
- **Fable** (`store_atomic_test.rb`): подкласс Store записывает события и проверяет порядок `[[:fsync, :open], [:rename, …]]`. Сравнивает inode до и после. 4 писателя и 3 читателя с `SlowInput`.

## 5. Клиент (тикеты 7–11)

**Архитектура.**

- **Sonnet:** модули с `module_function` (`Push.run`, `Sync.classify`). Файл читается целиком через `binread`. Pull пишет напрямую `binwrite`, без temp+rename.
- **Opus:** классы `LocalDir`, `Remote`, `SyncState`, `Failures`, результаты через `Data.define`. Файлы на диск — staging + `fsync` + `rename`, без следования за symlink.
- **Fable:** `Api`, `LocalTree`, `LocalTarget`, `Transfer`, `SyncState`. `Transfer` сверяет sha256 при скачивании и с ответом сервера при загрузке.

**Дифф.** У всех одинаково: обход локального дерева, SHA-256 и сравнение с `sha256` из `GET /blobs`.

**Состояние sync.**

- Sonnet: `.syncbox/manifest.json` вида `{key: sha}`.
- Opus: `.syncbox-state.json` с отдельным разделом на каждый сервер (`server_id(url)`), формат с версией.
- Fable: `.syncbox/state.json`. Блобы сервера под `.syncbox/` пропускаются, чтобы сервер не мог подменить состояние.

**Правило конфликтов** (спецификация: изменён и локально, и на сервере относительно последнего общего состояния — побеждает более свежий `modified_at`/mtime, при равенстве — локальная). Все трое делают трёхстороннее сравнение. Если изменилась одна сторона, переносится она. Если обе — сравнение по времени, при равенстве выигрывает локальная версия. Отличия:

- **Sonnet**, `classify`: `local_mtime.to_i >= remote_time.to_i ? :push : :pull`. Сравнение до секунды, что совпадает с точностью сервера.
- **Opus**, `comparable_times`: сервер отдаёт `iso8601(6)`, локальный mtime обрезается `floor` до той же точности.
- **Fable**, `floor_to`: сервер отдаёт целые секунды, локальное время обрезается до числа знаков из `modified_at`.

Если общего состояния нет (первый запуск), все трое считают это конфликтом и применяют правило mtime. Это расширение формулировки, но одинаковое у всех. Удалений не делает никто: пропавший с одной стороны файл возвращается.

**Ошибки и коды выхода.**

- Sonnet: всегда 1, включая ошибки usage. Сетевая ошибка на отдельном файле считается сбоем этого файла, обработка продолжается.
- Opus: 2 — usage, 1 — ошибка или `PartialFailure`, 130 — прерывание.
- Fable: 0/1/2/130. Недоступность сервера (`ServerUnreachable`) прерывает команду сразу, сбои отдельных файлов собираются в `Failures`.

**Вывод status.**

- Sonnet: блоки `would upload:` и `would download:`. Файл с другим содержимым попадает в оба.
- Opus: `format("%-9s %-8s %s")`, например `upload changed key`.
- Fable: `differs key (local N, server M; push would upload, pull would download)` с размерами.

## 6. Тесты

|                 | Sonnet                                          | Opus                                                                                            | Fable                                                            |
| --------------- | ----------------------------------------------- | ----------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| Фреймворк       | RSpec                                           | Minitest + rake                                                                                 | Minitest + rake                                                  |
| Файлов / тестов | 8 / 124 `it`                                    | 16 / 217 `test_`                                                                                | 17 / 303 `test_`                                                 |
| Сервер          | rack-test                                       | rack-test + `server_process_test` (`Process.spawn` + SIGTERM)                                   | rack-test + `server_integration_test` (spawn + SIGTERM)          |
| Клиент          | WebMock (`stub_request`), реального сервера нет | Puma в том же процессе (`Puma::Server.new` в test_helper) + `client_process_test` через `Open3` | Настоящий `bin/syncbox-server` отдельным процессом (test_helper) |

## 7. Сверх спецификации и спорные места

**Sonnet.**

- Сверх: переписывание `localhost` в run-client.
- Спорное: контейнеры работают от root. По умолчанию монтируется `/tmp`. `compose up` с одним именем проекта, так что два сервера одновременно не поднять. Листинг `Dir.glob("**/*")` без `FNM_DOTMATCH`: блобы с сегментом, начинающимся с точки, по коду в список не попадают. Тело PUT целиком в памяти. Pull пишет неатомарно. README нет.

**Opus.**

- Сверх: README на 257 строк. Порт публикуется на `127.0.0.1`. Проверка EXDEV при старте. Состояние sync хранится отдельно для каждого сервера. Ответы 405 и `Rack::Head`. Отключён `log_requests`.

**Fable.**

- Сверх: README на 603 строки. `Rack::CommonLogger`. Кэш sha256 по (dev, ino, size, mtime). `--version`/`--help`. Свой обработчик сигналов в `Server#run`: стоп идёт из главного потока через очередь, в комментарии указан обход зависания Puma «около 2% случаев». 500 вместо падения процесса.

У Opus и Fable явных натяжек относительно спецификации в коде не найдено. fsync каталога не делает никто.

## 8. Стиль

- **Sonnet:** нет ни одного `frozen_string_literal`. Файлы маленькие (до 158 строк). Комментарии на английском, объясняют «почему». Обработки сигналов нет.
- **Opus:** `frozen_string_literal` везде. `store.rb` на 313 строк. Плотные английские комментарии про гонки. `Data.define`. Сигналы: `exit 130` по `Interrupt` и `trap` в обёртках.
- **Fable:** `frozen_string_literal` везде. `store.rb` на 432 строки. Очень объёмные русские комментарии. Самая большая кодовая база: около 8,4 тыс. строк против 6,3 тыс. у Opus и 2,8 тыс. у Sonnet, считая SPEC и yaml.

## Главные различия

1. **Веб-слой:** Sonnet взял Sinatra и вынужден обходить `Rack::Protection`. Opus и Fable написали чистый Rack + Puma, Fable — со своим роутером.
2. **Docker:** у Sonnet `compose up`, контейнеры от root, без сигналов. У Opus и Fable `compose run` в фоне, uid хоста, `network_mode: host`, ручной `docker stop`/`down` по сигналу. Fable ещё и изолирует проекты по порту.
3. **Traversal:** Sonnet проверяет только текст ключа. Opus и Fable добавляют `realpath` и лимиты NAME_MAX/PATH_MAX. Opus запрещает любые symlink, Fable — только ведущие наружу.
4. **Атомарность:** у Sonnet буфер в памяти и temp рядом с целью без fsync. У Opus и Fable потоковая запись, `fsync`, отдельный tmp-каталог, очистка при старте, повторы при гонке с DELETE.
5. **Клиент:** Sonnet — процедурные модули с неатомарной записью при pull. Opus и Fable — объектные слои с атомарной записью. Fable дополнительно сверяет хеш при передаче.
6. **Правило конфликтов** у всех трёхстороннее и с перевесом локальной версии при равенстве. Различаются точность сравнения времени и то, где хранится состояние: у Opus отдельно для каждого сервера.
7. **Тесты клиента:** у Sonnet WebMock, у Opus Puma в том же процессе плюс subprocess, у Fable отдельный процесс настоящего сервера.
8. **Объём:** около 2,8 тыс., 6,3 тыс. и 8,4 тыс. строк. Сложность растёт вместе с числом обработанных краевых случаев.
