SHELL := /bin/bash
.DEFAULT_GOAL := help

IMPL ?= acceptance/reference-impl
PORT ?= 18080
VENV ?= .venv
PYTHON ?= python3

MD_FILES := README.md CLAUDE.md docs/SYNCBOX-SPEC.md docs/RUNBOOK.md \
	docs/EXPERIMENT-LOG.md docs/PILOT-RESULT-python-ticket-1.md \
	docs/PILOT-RESULT-python-ticket-2.md docs/PILOT-RESULT-go.md \
	docs/PILOT-COMPARISON-python-go.md \
	docs/PILOT-COMPARISON-talk-languages.md \
	docs/PILOT-COMPARISON-all-languages.md \
	docs/MARKET-PREVALENCE-experiment-languages.md \
	docs/REPLAY-CAMPAIGN-2026-09.md \
	docs/opus-ruby/README.md \
	docs/opus-langs/README.md \
	docs/TALK-OUTLINE-rubyrussia-2026.md \
	docs/TALK-ANNOUNCEMENT-rubyrussia-2026.md \
	"docs/CFP RubyRussia 2026.md" \
	acceptance/reference-impl/README.md \
	docs/incidents/2026-08-19-python-ticket1-contamination/README.md \
	docs/incidents/2026-08-20-dontask-permission-denial/README.md \
	docs/incidents/2026-08-20-sandbox-escape-hatch/README.md \
	docs/incidents/2026-08-20-docker-build-sandbox-gaps/README.md \
	docs/incidents/2026-08-21-write-tool-sandbox-escape/README.md \
	docs/incidents/2026-08-26-docker-inspect-hostpath-leak/README.md \
	docs/incidents/2026-08-31-contract-gate-tooling/README.md \
	docs/incidents/2026-08-31-js-fix-ticket-rm-data/README.md \
	docs/incidents/2026-09-01-dood-host-fs-reachable/README.md \
	docs/incidents/2026-09-02-dind-timing-broken/README.md \
	docs/pilot-runs/README.md \
	docs/pilot-runs/python/ticket-9-dind-shakedown/NOTE.md \
	docs/pilot-runs/python/ticket-10-dind-timing-verify/NOTE.md \
	docs/pilot-runs/python/ticket-12-readside/b163903f-4867-43bf-b924-8735a3dc1e37/NOTE.md \
	docs/pilot-runs/python/ticket-1/attempt-1-9baff2a0-contaminated/NOTE.md \
	docs/pilot-runs/go/ticket-2/attempt-1-f50e806a-network-blocked/NOTE.md \
	docs/pilot-runs/go/ticket-2/attempt-2-3eba70a1-buildx-write-blocked/NOTE.md \
	docs/pilot-runs/python/ticket-1/a87d7a43-534e-4a14-9517-1232815c3e02/NOTE.md \
	docs/pilot-runs/go/ticket-2/47ced9a7-82cf-4b63-97dc-ef6f7e0dcd38/NOTE.md

# Архивные копии SYNCBOX-SPEC.md внутри docs/pilot-runs/ — намеренно
# НЕ в MD_FILES: это точные исторические снимки того, что видел агент
# (в т.ч. версии до фикса контаминации), не живая документация — лint
# или fmt-tables их не трогает и не должен.

.PHONY: help
help: ## Список целей
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: venv
# Весь набор закреплён локфайлом acceptance/requirements-lock.txt (полный
# `pip freeze` рабочего venv, 48 пинов) — тот же принцип, что и точный ID
# модели: инструмент проверки не должен дрейфовать между прогонами.
# schemathesis==4.24.3 сам по себе недостаточно: на свежем разрешении
# зависимостей pip тянул несовместимую hypothesis, и schemathesis падал
# `'CanonicalSchema' object has no attribute 'is_satisfiable'` (поймано
# на CI с Python 3.14). Локфайл фиксирует и транзитивные пакеты, и через
# CI закреплён Python 3.11 (см. .github/workflows/*.yml).
venv: ## Локальное venv из acceptance/requirements-lock.txt (весь набор закреплён)
	@test -x "$(VENV)/bin/schemathesis" || { \
		$(PYTHON) -m venv $(VENV); \
		$(VENV)/bin/pip install --quiet --upgrade pip; \
		$(VENV)/bin/pip install --quiet -r acceptance/requirements-lock.txt; \
	}

.PHONY: shellcheck
shellcheck: ## shellcheck по bash-скриптам acceptance/ и scripts/
	shellcheck acceptance/smoke.sh acceptance/contract-test.sh \
		acceptance/reference-impl/run-server acceptance/reference-impl/run-client \
		acceptance/reference-impl/_docker.sh \
		scripts/run-pilot-ticket.sh scripts/run-gates.sh scripts/run-pilot-loop.sh \
		scripts/run-pilot-replay.sh scripts/lib-open-web-guard.sh \
		scripts/pilot-harness-entrypoint.sh scripts/build-base-images-tar.sh \
		scripts/run-opus-ruby.sh scripts/run-opus-langs.sh

.PHONY: markdownlint
markdownlint: ## markdownlint по документации
	npx --yes markdownlint-cli@0.49.1 $(MD_FILES)

.PHONY: openapi-lint
openapi-lint: venv ## Проверить синтаксис docs/syncbox-openapi.yaml
	$(VENV)/bin/python -m openapi_spec_validator docs/syncbox-openapi.yaml

.PHONY: lint
lint: shellcheck markdownlint openapi-lint ## Все статические проверки (без запуска реализаций)

.PHONY: smoke
smoke: ## Acceptance-смок против IMPL (по умолчанию reference-impl)
	acceptance/smoke.sh $(IMPL) $(PORT)

.PHONY: contract
contract: venv ## Контрактный тест (Schemathesis) против IMPL
	PATH="$(abspath $(VENV))/bin:$$PATH" acceptance/contract-test.sh $(IMPL) $(PORT)

.PHONY: test
test: smoke contract ## Оба acceptance-теста против IMPL

.PHONY: pilot-ticket
pilot-ticket: ## Один вызов claude -p по тикету (реализация + архивация docs/pilot-runs/), без гейтов и итераций: make pilot-ticket PILOT_DIR=pilot-runs-live/python PROMPT=pilot-runs-live/python/.ticket-1-prompt.txt OUT=/tmp/ticket-1-result
	scripts/run-pilot-ticket.sh $(PILOT_DIR) $(PROMPT) $(OUT)

.PHONY: pilot-loop
pilot-loop: venv ## Авто-итерирующий луп по тикету: claude -p -> гейты -> фикс-промпт -> ... make pilot-loop PILOT_DIR=pilot-runs-live/python PROMPT=pilot-runs-live/python/.ticket-8-prompt.txt OUT=/tmp/ticket-8
	scripts/run-pilot-loop.sh $(PILOT_DIR) $(PROMPT) $(OUT) $(LOOP_ARGS)

.PHONY: gates
gates: venv ## Прогнать три acceptance-гейта против снапшота реализации: make gates PILOT_DIR=pilot-runs-live/python OUT=/tmp/gates
	scripts/run-gates.sh $(PILOT_DIR) $(OUT) $(GATE_ARGS)

.PHONY: pilot-replay
pilot-replay: venv ## Кампания перепрогона бэклога на стабилизированном воркфлоу (чекпойнт + митигация 429): make pilot-replay REPLAY_ARGS="--dry-run"
	scripts/run-pilot-replay.sh $(REPLAY_ARGS)

.PHONY: check
check: lint test ## Полный набор: то же, что гоняет CI

.PHONY: build
build: ## Пересобрать образ эталонной реализации (через docker compose build)
	PORT=0 docker compose -f acceptance/reference-impl/docker-compose.yml build

.PHONY: run-server
run-server: ## Поднять сервер IMPL вручную (Ctrl+C — остановить); DATA_DIR опционален
	@dir=$${DATA_DIR:-$$(mktemp -d)}; \
	echo "data-dir: $$dir"; \
	$(IMPL)/run-server --data-dir "$$dir" --port $(PORT)

.PHONY: run-client
run-client: ## Вызвать клиент IMPL: make run-client ARGS="push <dir> --server <url>"
	$(IMPL)/run-client $(ARGS)

.PHONY: fmt-tables
fmt-tables: ## Выровнять markdown-таблицы (то же, что делает хук после Edit/Write)
	@for f in $(MD_FILES); do \
		python3 .claude/hooks/align_md_tables.py "$$f"; \
	done

.PHONY: clean
clean: ## Убрать venv, кеши тестов и docker compose проекты reference-impl
	rm -rf $(VENV) .schemathesis .hypothesis
	find . -name '__pycache__' -exec rm -rf {} +
	@docker ps -aq --filter "label=com.docker.compose.project" 2>/dev/null | while read -r cid; do \
		proj=$$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$$cid" 2>/dev/null); \
		case "$$proj" in syncbox-reference-impl-*) docker rm -f "$$cid" >/dev/null 2>&1 ;; esac; \
	done
	@docker network ls --format '{{.Name}}' 2>/dev/null | grep '^syncbox-reference-impl-' | xargs -r docker network rm >/dev/null 2>&1 || true
