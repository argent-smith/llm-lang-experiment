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
	"docs/CFP RubyRussia 2026.md" "docs/Конспект разговора с ментором.md" \
	acceptance/reference-impl/README.md \
	docs/incidents/2026-08-19-python-ticket1-contamination/README.md \
	docs/incidents/2026-08-20-dontask-permission-denial/README.md \
	docs/incidents/2026-08-20-sandbox-escape-hatch/README.md \
	docs/incidents/2026-08-20-docker-build-sandbox-gaps/README.md \
	docs/incidents/2026-08-21-write-tool-sandbox-escape/README.md \
	docs/pilot-runs/README.md \
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
venv: ## Локальное venv с openapi-spec-validator и schemathesis
	@test -x "$(VENV)/bin/schemathesis" || { \
		$(PYTHON) -m venv $(VENV); \
		$(VENV)/bin/pip install --quiet --upgrade pip; \
		$(VENV)/bin/pip install --quiet openapi-spec-validator schemathesis; \
	}

.PHONY: shellcheck
shellcheck: ## shellcheck по bash-скриптам acceptance/ и scripts/
	shellcheck acceptance/smoke.sh acceptance/contract-test.sh \
		acceptance/reference-impl/run-server acceptance/reference-impl/run-client \
		acceptance/reference-impl/_docker.sh \
		scripts/run-pilot-ticket.sh scripts/run-code-quality.sh

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

.PHONY: code-quality
code-quality: ## Code quality против IMPL: make code-quality CQ_LANG=python IMPL=pilot-runs-live/python (не входит в make check — данные для анализа, не гейт цикла ревью; code security пробовали и убрали, см. docs/PILOT-COMPARISON-python-go.md)
	scripts/run-code-quality.sh $(CQ_LANG) $(IMPL) $(or $(CQ_OUT),/tmp/syncbox-code-quality-$(CQ_LANG))

.PHONY: code-quality-setup
code-quality-setup: ## Установить локальные sandbox'ы code quality (venv/bundle/npm — конвенциональный для языка стиль, закреплённые версии) для python/ruby/javascript/typescript
	cd scripts/code-quality-configs/python && python3 -m venv .venv && .venv/bin/pip install --quiet --upgrade pip && .venv/bin/pip install --quiet -r requirements.txt
	cd scripts/code-quality-configs/ruby && bundle config set --local path 'vendor/bundle' && bundle install --quiet
	cd scripts/code-quality-configs/javascript && npm install --silent
	cd scripts/code-quality-configs/typescript && npm install --silent

.PHONY: pilot-ticket
pilot-ticket: ## Прогнать один тикет пилота целиком (реализация + архивация docs/pilot-runs/ + code quality): make pilot-ticket PILOT_DIR=pilot-runs-live/python PROMPT=pilot-runs-live/python/.ticket-1-prompt.txt OUT=/tmp/ticket-1-result
	scripts/run-pilot-ticket.sh $(PILOT_DIR) $(PROMPT) $(OUT)

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
