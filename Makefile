.PHONY: help \
	images-save images-push images-push-remote up diff down \
	kafka-verify rabbitmq-verify \
	postgres-verify redis-verify minio-verify clickhouse-verify \
	check-updates postgres-check-updates redis-check-updates kafka-check-updates \
	minio-check-updates clickhouse-check-updates rabbitmq-check-updates \
	pg-app-create pg-app-show-creds pg-app-drop redis-app-create kafka-app-create minio-app-create clickhouse-app-create rabbitmq-app-create \
	kafka-topic-create kafka-topic-alter kafka-topic-describe kafka-topic-list \
	postgres-status postgres-logs postgres-shell postgres-up postgres-diff postgres-down \
	redis-status redis-logs redis-shell redis-up redis-diff redis-down \
	clickhouse-status clickhouse-logs clickhouse-shell clickhouse-up clickhouse-diff clickhouse-down \
	rabbitmq-status rabbitmq-logs rabbitmq-shell rabbitmq-up rabbitmq-diff rabbitmq-down \
	kafka-bootstrap kafka-reset kafka-status kafka-logs kafka-shell kafka-up kafka-diff kafka-down \
	minio-status minio-logs minio-shell minio-up minio-diff minio-down \
	minio-app-append \
	env-new env-backup kubeconfig-fetch kubeconfig-info microk8s-setup microk8s-uninstall ssh \
	monitoring-status monitoring-logs monitoring-port-forward monitoring-up monitoring-diff monitoring-down \
	monitoring-top-nodes monitoring-events monitoring-pod-events monitoring-describe-pod

# Do not print "Entering/Leaving directory ..." on recursive make
MAKEFLAGS += --no-print-directory

ENV ?= dev

# per-environment overrides (SSH_HOST/SSH_KEY/KUBECONFIG/REGISTRY/etc)
-include environments/$(ENV).mk

SERVICES := postgres kafka redis minio clickhouse rabbitmq

REGISTRY ?= localhost:32000

KUBECONFIG ?= k8s/config/$(ENV)
# Always export an absolute kubeconfig path (important for `make -C <service> ...`)
KUBECONFIG := $(abspath $(KUBECONFIG))
export KUBECONFIG

SSH_USER ?= ubuntu
SSH_HOST ?=
SSH_PORT ?= 22
SSH_KEY ?= $(HOME)/.ssh/id_rsa
SSH_OPTS ?= -o StrictHostKeyChecking=accept-new

REMOTE ?= $(SSH_USER)@$(SSH_HOST)
SSH := ssh $(SSH_OPTS) -p $(SSH_PORT) -i $(SSH_KEY)
SCP := scp $(SSH_OPTS) -P $(SSH_PORT) -i $(SSH_KEY)

# ANSI color codes
CYAN := \033[0;36m
GREEN := \033[0;32m
YELLOW := \033[0;33m
BLUE := \033[0;34m
MAGENTA := \033[0;35m
RED := \033[0;31m
BOLD := \033[1m
RESET := \033[0m

help:
	@echo "$(BOLD)$(GREEN)infra$(RESET)"
	@echo ""
	@echo "$(BOLD)$(GREEN)ENV:$(RESET)"
	@echo "  make <target> $(YELLOW)ENV=dev|prod|staging$(RESET) ..."
	@echo ""
	@echo "$(BOLD)$(GREEN)Images:$(RESET)"
	@echo "  make images-save $(YELLOW)ENV=$(ENV)$(RESET) [$(YELLOW)SERVICE=redis$(RESET)] - Скачать/сохранить tar во всех сервисах (или только SERVICE)"
	@echo "  make images-push $(YELLOW)ENV=$(ENV)$(RESET) [$(YELLOW)SERVICE=redis$(RESET)] - docker load -> tag -> push в registry (см. REGISTRY в сервисах)"
	@echo "  make images-push-remote $(YELLOW)ENV=$(ENV)$(RESET) [$(YELLOW)SERVICE=redis$(RESET)] - scp *.tar на удалённый сервер + docker load/tag/push в registry на сервере"
	@echo ""
	@echo "$(BOLD)$(GREEN)Helmfile:$(RESET)"
	@echo "  make up $(YELLOW)ENV=$(ENV)$(RESET) [$(YELLOW)ENABLED_SERVICES=postgres,redis$(RESET)] [$(YELLOW)EXCLUDE_SERVICES=kafka,clickhouse$(RESET)] - helmfile apply"
	@echo "  make diff $(YELLOW)ENV=$(ENV)$(RESET) [$(YELLOW)ENABLED_SERVICES=postgres,redis$(RESET)] [$(YELLOW)EXCLUDE_SERVICES=kafka,clickhouse$(RESET)] - helmfile diff"
	@echo "  make down $(YELLOW)ENV=$(ENV)$(RESET) [$(YELLOW)ENABLED_SERVICES=postgres,redis$(RESET)] [$(YELLOW)EXCLUDE_SERVICES=kafka,clickhouse$(RESET)] - helmfile destroy"
	@echo ""
	@echo "$(BOLD)$(GREEN)Service shortcuts (up/diff/down):$(RESET)"
	@echo "  make postgres-up $(YELLOW)ENV=$(ENV)$(RESET)    - развернуть только postgres (эквивалент: make up ENABLED_SERVICES=postgres)"
	@echo "  make redis-up $(YELLOW)ENV=$(ENV)$(RESET)      - развернуть только redis"
	@echo "  make kafka-up $(YELLOW)ENV=$(ENV)$(RESET)      - развернуть только kafka"
	@echo "  make minio-up $(YELLOW)ENV=$(ENV)$(RESET)       - развернуть только minio"
	@echo "  make clickhouse-up $(YELLOW)ENV=$(ENV)$(RESET) - развернуть только clickhouse"
	@echo "  make rabbitmq-up $(YELLOW)ENV=$(ENV)$(RESET)   - развернуть только rabbitmq"
	@echo "  make monitoring-up $(YELLOW)ENV=$(ENV)$(RESET)  - развернуть только netdata"
	@echo "  (аналогично для diff/down: $(YELLOW){service}-diff$(RESET), $(YELLOW){service}-down$(RESET))"
	@echo ""
	@echo "$(BOLD)$(GREEN)Image verification (bitnamilegacy):$(RESET)"
	@echo "  make kafka-verify      - проверить доступность тегов в bitnamilegacy для Kafka"
	@echo "  make postgres-verify   - проверить доступность тегов в bitnamilegacy для PostgreSQL"
	@echo "  make redis-verify      - проверить доступность тегов в bitnamilegacy для Redis"
	@echo "  make minio-verify      - проверить доступность тегов в bitnamilegacy для MinIO"
	@echo "  make clickhouse-verify - проверить доступность тегов в bitnamilegacy для ClickHouse"
	@echo "  make rabbitmq-verify   - проверить доступность тегов в bitnamilegacy для RabbitMQ"
	@echo ""
	@echo "$(BOLD)$(GREEN)Updates check:$(RESET)"
	@echo "  make check-updates     - проверить наличие новых версий чартов и образов для всех сервисов"
	@echo "  make {service}-check-updates - проверить обновления для конкретного сервиса"
	@echo ""
	@echo "$(BOLD)$(GREEN)App accounts (per-app isolation):$(RESET)"
	@echo "  make pg-app-create    $(YELLOW)APP=myapp$(RESET) [$(YELLOW)APP_NS=myapp$(RESET)] [$(YELLOW)POSTGRES_ADMIN_PASSWORD=...$(RESET)]"
	@echo "  make pg-app-show-creds $(YELLOW)APP=myapp$(RESET) [$(YELLOW)ENV=$(ENV)$(RESET)] - показать креды из Secret app-postgres"
	@echo "  make pg-app-drop      $(YELLOW)APP=myapp$(RESET) [$(YELLOW)ENV=$(ENV)$(RESET)] - удалить БД, роль и Secret приложения"
	@echo "  make redis-app-create $(YELLOW)APP=myapp$(RESET) [$(YELLOW)APP_NS=myapp$(RESET)]"
	@echo "  make kafka-app-create $(YELLOW)APP=myapp$(RESET) [$(YELLOW)APP_NS=myapp$(RESET)]"
	@echo "  make minio-app-create $(YELLOW)APP=myapp$(RESET) [$(YELLOW)APP_NS=myapp$(RESET)]"
	@echo "  make clickhouse-app-create $(YELLOW)APP=myapp$(RESET) [$(YELLOW)APP_NS=myapp$(RESET)]"
	@echo "  make rabbitmq-app-create $(YELLOW)APP=myapp$(RESET) [$(YELLOW)APP_NS=myapp$(RESET)]"
	@echo "  make minio-app-append $(YELLOW)APP=myapp BUCKET=b2$(RESET) [$(YELLOW)PREFIX=data/$(RESET)] [$(YELLOW)ACCESS_MODE=...$(RESET)] [$(YELLOW)PUBLIC_READ=true$(RESET)] [$(YELLOW)PUBLIC_LIST=true$(RESET)]"
	@echo ""
	@echo "$(BOLD)$(GREEN)Kafka topics:$(RESET)"
	@echo "  make kafka-topic-create $(YELLOW)APP=myapp TOPIC_SUFFIX=events$(RESET) [$(YELLOW)PARTITIONS=3$(RESET)] [$(YELLOW)REPLICATION_FACTOR=1$(RESET)] [$(YELLOW)CONFIGS=k=v,k2=v2$(RESET)]"
	@echo "  make kafka-topic-alter $(YELLOW)TOPIC=myapp.events$(RESET) [$(YELLOW)PARTITIONS=12$(RESET)] [$(YELLOW)CONFIGS=k=v,k2=v2$(RESET)]"
	@echo "  make kafka-topic-describe $(YELLOW)TOPIC=myapp.events$(RESET)"
	@echo "  make kafka-topic-list [$(YELLOW)PREFIX=myapp.$(RESET)]"
	@echo ""
	@echo "$(BOLD)$(GREEN)Per-service diagnostics:$(RESET)"
	@echo "  make postgres-status $(YELLOW)ENV=$(ENV)$(RESET)  - статус PostgreSQL"
	@echo "  make postgres-logs $(YELLOW)ENV=$(ENV)$(RESET)     - логи PostgreSQL"
	@echo "  make postgres-shell $(YELLOW)ENV=$(ENV)$(RESET)    - shell в контейнер PostgreSQL"
	@echo "  make postgres-backup $(YELLOW)ENV=$(ENV)$(RESET)   - бэкап PostgreSQL"
	@echo "  make postgres-restore $(YELLOW)BACKUP_FILE=... ENV=$(ENV)$(RESET) - восстановление из бэкапа"
	@echo "  make postgres-recreate-prep $(YELLOW)ENV=$(ENV)$(RESET) - подготовка к пересозданию с новым размером PVC (бэкап, down, delete PVC)"
	@echo "  make redis-status $(YELLOW)ENV=$(ENV)$(RESET)     - статус Redis"
	@echo "  make redis-logs $(YELLOW)ENV=$(ENV)$(RESET)        - логи Redis"
	@echo "  make redis-shell $(YELLOW)ENV=$(ENV)$(RESET)       - shell в контейнер Redis"
	@echo "  make kafka-status $(YELLOW)ENV=$(ENV)$(RESET)      - статус Kafka"
	@echo "  make kafka-logs $(YELLOW)ENV=$(ENV)$(RESET)         - логи Kafka"
	@echo "  make kafka-shell $(YELLOW)ENV=$(ENV)$(RESET)        - shell в контейнер Kafka"
	@echo "  make kafka-bootstrap $(YELLOW)ENV=$(ENV)$(RESET)   - первичная установка Kafka (bootstrap-safe)"
	@echo "  make kafka-reset $(YELLOW)ENV=$(ENV)$(RESET)       - ⚠ reset данных Kafka (аварийно)"
	@echo "  make minio-status $(YELLOW)ENV=$(ENV)$(RESET)      - статус MinIO"
	@echo "  make minio-logs $(YELLOW)ENV=$(ENV)$(RESET)         - логи MinIO"
	@echo "  make minio-shell $(YELLOW)ENV=$(ENV)$(RESET)        - shell в контейнер MinIO"
	@echo "  make clickhouse-status $(YELLOW)ENV=$(ENV)$(RESET) - статус ClickHouse"
	@echo "  make clickhouse-logs $(YELLOW)ENV=$(ENV)$(RESET)    - логи ClickHouse"
	@echo "  make clickhouse-shell $(YELLOW)ENV=$(ENV)$(RESET) - shell в контейнер ClickHouse"
	@echo "  make rabbitmq-status $(YELLOW)ENV=$(ENV)$(RESET)    - статус RabbitMQ"
	@echo "  make rabbitmq-logs $(YELLOW)ENV=$(ENV)$(RESET)       - логи RabbitMQ"
	@echo "  make rabbitmq-shell $(YELLOW)ENV=$(ENV)$(RESET)      - shell в контейнер RabbitMQ"
	@echo ""
	@echo "$(BOLD)$(GREEN)Kubeconfig/SSH:$(RESET)"
	@echo "  make kubeconfig-fetch $(YELLOW)ENV=$(ENV)$(RESET) $(YELLOW)SSH_HOST=... SSH_KEY=...$(RESET)  - скачать kubeconfig (microk8s config)"
	@echo "  make kubeconfig-info $(YELLOW)ENV=$(ENV)$(RESET)  - kubectl cluster-info"
	@echo "  make microk8s-setup $(YELLOW)ENV=$(ENV)$(RESET)   - проверить/установить microk8s, необходимые модули и docker на удалённом сервере"
	@echo "  make microk8s-uninstall $(YELLOW)ENV=$(ENV)$(RESET) [$(YELLOW)REMOVE_DOCKER=1$(RESET)] - удалить microk8s (и опционально docker) на удалённом сервере"
	@echo ""
	@echo "$(BOLD)$(GREEN)Environment skeleton:$(RESET)"
	@echo "  make env-new $(YELLOW)ENV=staging$(RESET)        - создать рыбу окружения (mk/yaml/kubeconfig/values)"
	@echo "  make env-backup $(YELLOW)ENV=$(ENV)$(RESET)       - бэкап secrets/configmaps в namespaces из environments/$(ENV).yaml"
	@echo ""
	@echo "$(BOLD)$(GREEN)Monitoring (Netdata):$(RESET)"
	@echo "  make monitoring-up $(YELLOW)ENV=$(ENV)$(RESET)          - развернуть Netdata (эквивалент: make up ENABLED_SERVICES=netdata)"
	@echo "  make monitoring-diff $(YELLOW)ENV=$(ENV)$(RESET)         - показать изменения Netdata"
	@echo "  make monitoring-down $(YELLOW)ENV=$(ENV)$(RESET)         - удалить Netdata"
	@echo "  make monitoring-status $(YELLOW)ENV=$(ENV)$(RESET)       - статус Netdata"
	@echo "  make monitoring-logs $(YELLOW)ENV=$(ENV)$(RESET)         - логи Netdata"
	@echo "  make monitoring-port-forward $(YELLOW)ENV=$(ENV)$(RESET) - доступ http://localhost:19999"
	@echo "  make monitoring-top-nodes $(YELLOW)ENV=$(ENV)$(RESET)    - использование CPU/памяти на нодах"
	@echo "  make monitoring-events $(YELLOW)ENV=$(ENV)$(RESET)        - последние события в namespace monitoring"
	@echo "  make monitoring-pod-events $(YELLOW)ENV=$(ENV)$(RESET) [$(YELLOW)POD=имя-пода$(RESET)] - события по поду Netdata"
	@echo "  make monitoring-describe-pod $(YELLOW)ENV=$(ENV)$(RESET) [$(YELLOW)POD=имя-пода$(RESET)] - describe пода Netdata"

# Usage: make images-save ENV=prod [SERVICE=redis]
images-save:
	@SERVICE_LIST=$${SERVICE:-$(SERVICES)}; \
	for s in $$SERVICE_LIST; do \
		echo "=== $$s: images-save ==="; \
		$(MAKE) -C $$s images-save ENV=$(ENV) REGISTRY=$(REGISTRY); \
	done

# Usage: make images-push ENV=prod [SERVICE=redis]
images-push:
	@SERVICE_LIST=$${SERVICE:-$(SERVICES)}; \
	for s in $$SERVICE_LIST; do \
		echo "=== $$s: images-sync-from-files ==="; \
		$(MAKE) -C $$s images-sync-from-files ENV=$(ENV) REGISTRY=$(REGISTRY); \
	done

# Upload tar images to a REMOTE server and publish to its local registry (REGISTRY, usually localhost:32000)
# Requires SSH_* variables (from environments/$(ENV).mk)
# Usage: make images-push-remote ENV=prod [SERVICE=redis]
images-push-remote:
	@if [ -z "$(SSH_HOST)" ]; then echo "✗ SSH_HOST не задан (используйте environments/$(ENV).mk или SSH_HOST=...)"; exit 1; fi
	@set -e; SERVICE_LIST=$${SERVICE:-$(SERVICES)}; \
	REMOTE_DIR="infra-images-$(ENV)-$$(date +%s%N)"; \
	echo "Remote: $(REMOTE)"; \
	echo "Registry on remote: $(REGISTRY)"; \
	echo "Uploading tar files -> $$REMOTE_DIR"; \
	$(SSH) $(REMOTE) "mkdir -p '$$REMOTE_DIR'"; \
	FOUND=0; \
	for s in $$SERVICE_LIST; do \
		if ls "$$s/images/"*.tar >/dev/null 2>&1; then \
			FOUND=1; \
			echo "=== $$s: scp images ==="; \
			$(SCP) "$$s/images/"*.tar "$(REMOTE):$$REMOTE_DIR/"; \
		else \
			echo "=== $$s: no tar files (skip) ==="; \
		fi; \
	done; \
	if [ $$FOUND -eq 0 ]; then \
		echo "✗ Не найдено ни одного файла */images/*.tar (сначала выполните: make images-save ENV=$(ENV))"; \
		$(SSH) $(REMOTE) "rmdir '$$REMOTE_DIR' >/dev/null 2>&1 || true"; \
		exit 1; \
	fi; \
	echo "Building image map (SRC -> DEST)"; \
	MAP_FILE=$$(mktemp); \
	{ \
		for s in $$SERVICE_LIST; do \
			case "$$s" in \
				kafka|redis|minio|clickhouse|rabbitmq) \
					SRC="$$( $(MAKE) -s -C $$s --eval 'print-src:;@printf "%s\n" "$$(IMAGES_SRC)"' print-src )"; \
					DST="$$( $(MAKE) -s -C $$s --eval 'print-dst:;@printf "%s\n" "$$(IMAGES_LOCAL)"' print-dst )"; \
					set -- $$DST; \
					for src_img in $$SRC; do \
						dst_img="$$1"; shift || true; \
						printf '%s|%s\n' "$$src_img" "$$dst_img"; \
					done; \
					;; \
				postgres) \
					printf '%s|%s\n' \
						"$$( $(MAKE) -s -C postgres --eval 'p:;@printf "%s" "$$(POSTGRESQL_IMAGE)"' p )" "$$( $(MAKE) -s -C postgres --eval 'p:;@printf "%s" "$$(POSTGRESQL_LOCAL)"' p )"; \
					printf '%s|%s\n' \
						"$$( $(MAKE) -s -C postgres --eval 'p:;@printf "%s" "$$(OS_SHELL_IMAGE)"' p )" "$$( $(MAKE) -s -C postgres --eval 'p:;@printf "%s" "$$(OS_SHELL_LOCAL)"' p )"; \
					printf '%s|%s\n' \
						"$$( $(MAKE) -s -C postgres --eval 'p:;@printf "%s" "$$(POSTGRES_EXPORTER_IMAGE)"' p )" "$$( $(MAKE) -s -C postgres --eval 'p:;@printf "%s" "$$(POSTGRES_EXPORTER_LOCAL)"' p )"; \
					;; \
			esac; \
		done; \
	} > "$$MAP_FILE"; \
	echo "Uploading image map -> $$REMOTE_DIR/map.txt"; \
	$(SCP) "$$MAP_FILE" "$(REMOTE):$$REMOTE_DIR/map.txt"; \
	echo "Loading tars + tagging + pushing on remote..."; \
	REMOTE_PUSH_SCRIPT=$$(mktemp); \
	printf '%s\n' \
		'#!/usr/bin/env bash' \
		'set -euo pipefail' \
		'dir="$${1:?dir required}"' \
		'map="$${2:?map required}"' \
		'command -v docker >/dev/null 2>&1 || { echo "✗ docker not found on remote"; exit 1; }' \
		'[ -d "$$dir" ] || { echo "✗ remote dir missing: $$dir"; exit 1; }' \
		'[ -f "$$map" ] || { echo "✗ remote map missing: $$map"; exit 1; }' \
		'echo "docker load *.tar"' \
		'for f in "$$dir"/*.tar; do [ -f "$$f" ] || continue; echo "  - $$f"; docker load -i "$$f" >/dev/null; done' \
		'echo "apply tags + push"' \
		'while IFS="|" read -r src dst; do' \
		'  [ -n "$$dst" ] || continue' \
		'  if ! docker image inspect "$$dst" >/dev/null 2>&1; then' \
		'    src2="$${src#docker.io/}"; src3="$${src#registry-1.docker.io/}"; srclatest="$${src2%:*}:latest"' \
		'    if docker image inspect "$$src" >/dev/null 2>&1; then docker tag "$$src" "$$dst"' \
		'    elif docker image inspect "$$src2" >/dev/null 2>&1; then docker tag "$$src2" "$$dst"' \
		'    elif docker image inspect "$$src3" >/dev/null 2>&1; then docker tag "$$src3" "$$dst"' \
		'    elif docker image inspect "$$srclatest" >/dev/null 2>&1; then docker tag "$$srclatest" "$$dst"' \
		'    else echo "✗ missing src image for tag: src=$$src dst=$$dst"; exit 1; fi' \
		'  fi' \
		'  echo "  → pushing $$dst"' \
		'  docker push "$$dst" >/dev/null' \
		'done < "$$map"' \
		'rm -rf "$$dir"' \
		> "$$REMOTE_PUSH_SCRIPT"; \
	chmod +x "$$REMOTE_PUSH_SCRIPT"; \
	$(SCP) "$$REMOTE_PUSH_SCRIPT" "$(REMOTE):$$REMOTE_DIR/push-images.sh"; \
	$(SSH) $(REMOTE) "bash '$$REMOTE_DIR/push-images.sh' '$$REMOTE_DIR' '$$REMOTE_DIR/map.txt'"; \
	rm -f "$$REMOTE_PUSH_SCRIPT"; \
	rm -f "$$MAP_FILE"; \
	echo "✓ Done"

kafka-verify:
	@$(MAKE) -C kafka images-verify

postgres-verify:
	@$(MAKE) -C postgres images-verify

redis-verify:
	@$(MAKE) -C redis images-verify

minio-verify:
	@$(MAKE) -C minio images-verify

clickhouse-verify:
	@$(MAKE) -C clickhouse images-verify

rabbitmq-verify:
	@$(MAKE) -C rabbitmq images-verify

## =========================
## Updates check (new chart/image versions)
## =========================

check-updates: ## Проверить наличие новых версий чартов и образов для всех сервисов
	@echo "$(BOLD)$(GREEN)Проверка обновлений для всех сервисов...$(RESET)"
	@echo ""
	@$(MAKE) postgres-check-updates
	@echo ""
	@$(MAKE) redis-check-updates
	@echo ""
	@$(MAKE) kafka-check-updates
	@echo ""
	@$(MAKE) minio-check-updates
	@echo ""
	@$(MAKE) clickhouse-check-updates
	@echo ""
	@$(MAKE) rabbitmq-check-updates

postgres-check-updates:
	@$(MAKE) -C postgres check-updates

redis-check-updates:
	@$(MAKE) -C redis check-updates

kafka-check-updates:
	@$(MAKE) -C kafka check-updates

minio-check-updates:
	@$(MAKE) -C minio check-updates

clickhouse-check-updates:
	@$(MAKE) -C clickhouse check-updates

rabbitmq-check-updates:
	@$(MAKE) -C rabbitmq check-updates

pg-app-create:
	@$(MAKE) -C postgres app-create APP="$(APP)" APP_NS="$(APP_NS)" ENV="$(ENV)" KUBECONFIG="$(KUBECONFIG)" POSTGRES_ADMIN_PASSWORD="$(POSTGRES_ADMIN_PASSWORD)"
pg-app-show-creds:
	@$(MAKE) -C postgres app-show-creds APP="$(APP)" APP_NS="$(APP_NS)" ENV="$(ENV)" KUBECONFIG="$(KUBECONFIG)"
pg-app-drop:
	@$(MAKE) -C postgres app-drop APP="$(APP)" APP_NS="$(APP_NS)" ENV="$(ENV)" KUBECONFIG="$(KUBECONFIG)" POSTGRES_ADMIN_PASSWORD="$(POSTGRES_ADMIN_PASSWORD)"
pg-app-verify:
	@$(MAKE) -C postgres app-verify APP="$(APP)" APP_NS="$(APP_NS)" ENV="$(ENV)" KUBECONFIG="$(KUBECONFIG)"

redis-app-create:
	@$(MAKE) -C redis app-create APP="$(APP)" APP_NS="$(APP_NS)"

kafka-app-create:
	@$(MAKE) -C kafka app-create APP="$(APP)" APP_NS="$(APP_NS)"

rabbitmq-app-create:
	@$(MAKE) -C rabbitmq app-create APP="$(APP)" APP_NS="$(APP_NS)"

## =========================
## Per-service diagnostics (status/logs/shell)
## =========================

postgres-status:
	@$(MAKE) -C postgres status ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"
postgres-logs:
	@$(MAKE) -C postgres logs ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"
postgres-shell:
	@$(MAKE) -C postgres shell ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"
postgres-backup:
	@$(MAKE) -C postgres backup ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"
postgres-restore:
	@$(MAKE) -C postgres restore ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)" BACKUP_FILE="$(BACKUP_FILE)"
postgres-delete-pvcs:
	@$(MAKE) -C postgres delete-pvcs ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"
postgres-recreate-prep:
	@echo "=== 1/3 Бэкап ==="
	@$(MAKE) postgres-backup ENV="$(ENV)"
	@echo ""
	@echo "=== 2/3 Удаление release ==="
	@$(MAKE) postgres-down ENV="$(ENV)"
	@echo ""
	@echo "=== 3/3 Удаление PVC ==="
	@$(MAKE) postgres-delete-pvcs ENV="$(ENV)"
	@echo ""
	@echo "Дальше: отредактируйте postgres/values-$(ENV).yaml (primary.persistence.size), затем:"
	@echo "  make postgres-up ENV=$(ENV)"
	@echo "  make postgres-restore BACKUP_FILE=backups/postgres-backup-YYYYMMDD-HHMMSS.sql.gz ENV=$(ENV)"
	@echo "(путь BACKUP_FILE — относительно postgres/, см. postgres/list-backups)"

redis-status:
	@$(MAKE) -C redis status ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"
redis-logs:
	@$(MAKE) -C redis logs ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"
redis-shell:
	@$(MAKE) -C redis shell ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"

kafka-bootstrap:
	@$(MAKE) -C kafka bootstrap ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"
kafka-reset:
	@$(MAKE) -C kafka reset ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"
kafka-status:
	@$(MAKE) -C kafka status ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"
kafka-logs:
	@$(MAKE) -C kafka logs ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"
kafka-shell:
	@$(MAKE) -C kafka shell ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"

minio-status:
	@$(MAKE) -C minio status ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"
minio-logs:
	@$(MAKE) -C minio logs ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"
minio-shell:
	@$(MAKE) -C minio shell ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"

clickhouse-status:
	@$(MAKE) -C clickhouse status ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"
clickhouse-logs:
	@$(MAKE) -C clickhouse logs ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"
clickhouse-shell:
	@$(MAKE) -C clickhouse shell ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"

rabbitmq-status:
	@$(MAKE) -C rabbitmq status ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"
rabbitmq-logs:
	@$(MAKE) -C rabbitmq logs ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"
rabbitmq-shell:
	@$(MAKE) -C rabbitmq shell ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"

kafka-topic-create:
	@$(MAKE) -C kafka topic-create \
		APP="$(APP)" TOPIC_SUFFIX="$(TOPIC_SUFFIX)" TOPIC="$(TOPIC)" \
		PARTITIONS="$(PARTITIONS)" REPLICATION_FACTOR="$(REPLICATION_FACTOR)" \
		CONFIGS="$(CONFIGS)"

kafka-topic-alter:
	@$(MAKE) -C kafka topic-alter \
		TOPIC="$(TOPIC)" PARTITIONS="$(PARTITIONS)" CONFIGS="$(CONFIGS)"

kafka-topic-describe:
	@$(MAKE) -C kafka topic-describe TOPIC="$(TOPIC)"

kafka-topic-list:
	@$(MAKE) -C kafka topic-list PREFIX="$(PREFIX)"

minio-app-create:
	@$(MAKE) -C minio app-create \
		APP="$(APP)" APP_NS="$(APP_NS)" \
		BUCKET="$(BUCKET)" PREFIX="$(PREFIX)" \
		ACCESS_MODE="$(ACCESS_MODE)" PUBLIC_READ="$(PUBLIC_READ)" PUBLIC_LIST="$(PUBLIC_LIST)" \
		VERSIONING="$(VERSIONING)" QUOTA="$(QUOTA)" TAGS="$(TAGS)" LIFECYCLE_JSON="$(LIFECYCLE_JSON)" \
		OBJECT_LOCK="$(OBJECT_LOCK)" RETENTION_DAYS="$(RETENTION_DAYS)" \
		ACCESS_KEY="$(ACCESS_KEY)" SECRET_KEY="$(SECRET_KEY)" MINIO_SCHEME="$(MINIO_SCHEME)" \
		APP_PUBLIC_ENDPOINT="$(APP_PUBLIC_ENDPOINT)"

clickhouse-app-create:
	@$(MAKE) -C clickhouse app-create \
		APP="$(APP)" APP_NS="$(APP_NS)" DB="$(DB)" APP_USER="$(APP_USER)" APP_PASSWORD="$(APP_PASSWORD)" \
		APP_SECRET_NAME="$(APP_SECRET_NAME)" ADMIN_USER="$(ADMIN_USER)"

minio-app-append:
	@$(MAKE) -C minio app-append \
		APP="$(APP)" BUCKET="$(BUCKET)" PREFIX="$(PREFIX)" \
		ACCESS_MODE="$(ACCESS_MODE)" PUBLIC_READ="$(PUBLIC_READ)" PUBLIC_LIST="$(PUBLIC_LIST)" \
		ACCESS_KEY="$(ACCESS_KEY)" MINIO_SCHEME="$(MINIO_SCHEME)" \
		APP_PUBLIC_ENDPOINT="$(APP_PUBLIC_ENDPOINT)"

up:
	@REDIS_PASSWORD=$$(kubectl get secret -n redis redis -o jsonpath='{.data.redis-password}' 2>/dev/null | base64 -d || true); \
	if [ -z "$$REDIS_PASSWORD" ]; then \
		echo "Redis password secret not found (redis/redis). Creating one for first install..."; \
		command -v openssl >/dev/null 2>&1 || { echo "✗ openssl не найден (нужен для генерации пароля)"; exit 1; }; \
		REDIS_PASSWORD=$$(openssl rand -hex 16); \
		kubectl create namespace redis --dry-run=client -o yaml | kubectl apply -f - >/dev/null; \
		kubectl delete secret redis -n redis --ignore-not-found >/dev/null; \
		kubectl create secret generic redis -n redis --from-literal=redis-password="$$REDIS_PASSWORD" >/dev/null; \
	fi; \
	RABBITMQ_PASSWORD=$$(kubectl get secret -n rabbitmq rabbitmq -o jsonpath='{.data.rabbitmq-password}' 2>/dev/null | base64 -d || true); \
	RABBITMQ_COOKIE=$$(kubectl get secret -n rabbitmq rabbitmq -o jsonpath='{.data.rabbitmq-erlang-cookie}' 2>/dev/null | base64 -d || true); \
	if [ -z "$$RABBITMQ_PASSWORD" ] || [ -z "$$RABBITMQ_COOKIE" ]; then \
		echo "RabbitMQ secret not found or incomplete (rabbitmq/rabbitmq). Creating one for first install..."; \
		command -v openssl >/dev/null 2>&1 || { echo "✗ openssl не найден (нужен для генерации пароля)"; exit 1; }; \
		RABBITMQ_PASSWORD=$$(openssl rand -hex 16); \
		RABBITMQ_COOKIE=$$(openssl rand -hex 32); \
		kubectl create namespace rabbitmq --dry-run=client -o yaml | kubectl apply -f - >/dev/null; \
		kubectl delete secret rabbitmq -n rabbitmq --ignore-not-found >/dev/null; \
		kubectl create secret generic rabbitmq -n rabbitmq \
			--from-literal=rabbitmq-password="$$RABBITMQ_PASSWORD" \
			--from-literal=rabbitmq-erlang-cookie="$$RABBITMQ_COOKIE" \
			>/dev/null; \
	fi; \
	ENV=$(ENV) REDIS_PASSWORD="$$REDIS_PASSWORD" RABBITMQ_PASSWORD="$$RABBITMQ_PASSWORD" RABBITMQ_ERLANG_COOKIE="$$RABBITMQ_COOKIE" ENABLED_SERVICES="$(ENABLED_SERVICES)" EXCLUDE_SERVICES="$(EXCLUDE_SERVICES)" helmfile -f helmfile.yaml.gotmpl -e default apply

diff:
	@REDIS_PASSWORD=$$(kubectl get secret -n redis redis -o jsonpath='{.data.redis-password}' 2>/dev/null | base64 -d || true); \
	if [ -z "$$REDIS_PASSWORD" ]; then \
		echo "✗ Redis password secret not found (redis/redis). Run: make up ENV=$(ENV)"; \
		exit 1; \
	fi; \
	RABBITMQ_PASSWORD=$$(kubectl get secret -n rabbitmq rabbitmq -o jsonpath='{.data.rabbitmq-password}' 2>/dev/null | base64 -d || true); \
	RABBITMQ_COOKIE=$$(kubectl get secret -n rabbitmq rabbitmq -o jsonpath='{.data.rabbitmq-erlang-cookie}' 2>/dev/null | base64 -d || true); \
	if [ -z "$$RABBITMQ_PASSWORD" ] || [ -z "$$RABBITMQ_COOKIE" ]; then \
		echo "✗ RabbitMQ secret not found or incomplete (rabbitmq/rabbitmq). Run: make up ENV=$(ENV) ENABLED_SERVICES=rabbitmq"; \
		exit 1; \
	fi; \
	ENV=$(ENV) REDIS_PASSWORD="$$REDIS_PASSWORD" RABBITMQ_PASSWORD="$$RABBITMQ_PASSWORD" RABBITMQ_ERLANG_COOKIE="$$RABBITMQ_COOKIE" ENABLED_SERVICES="$(ENABLED_SERVICES)" EXCLUDE_SERVICES="$(EXCLUDE_SERVICES)" helmfile -f helmfile.yaml.gotmpl -e default diff

down:
	@ENV=$(ENV) ENABLED_SERVICES="$(ENABLED_SERVICES)" EXCLUDE_SERVICES="$(EXCLUDE_SERVICES)" helmfile -f helmfile.yaml.gotmpl -e default destroy

## =========================
## Service shortcuts (up/diff/down for individual services)
## =========================

postgres-up:
	@$(MAKE) up ENV="$(ENV)" ENABLED_SERVICES=postgres
postgres-diff:
	@$(MAKE) diff ENV="$(ENV)" ENABLED_SERVICES=postgres
postgres-down:
	@$(MAKE) down ENV="$(ENV)" ENABLED_SERVICES=postgres

redis-up:
	@$(MAKE) up ENV="$(ENV)" ENABLED_SERVICES=redis
redis-diff:
	@$(MAKE) diff ENV="$(ENV)" ENABLED_SERVICES=redis
redis-down:
	@$(MAKE) down ENV="$(ENV)" ENABLED_SERVICES=redis

kafka-up:
	@$(MAKE) up ENV="$(ENV)" ENABLED_SERVICES=kafka
kafka-diff:
	@$(MAKE) diff ENV="$(ENV)" ENABLED_SERVICES=kafka
kafka-down:
	@$(MAKE) down ENV="$(ENV)" ENABLED_SERVICES=kafka

minio-up:
	@$(MAKE) up ENV="$(ENV)" ENABLED_SERVICES=minio
minio-diff:
	@$(MAKE) diff ENV="$(ENV)" ENABLED_SERVICES=minio
minio-down:
	@$(MAKE) down ENV="$(ENV)" ENABLED_SERVICES=minio

clickhouse-up:
	@$(MAKE) up ENV="$(ENV)" ENABLED_SERVICES=clickhouse
clickhouse-diff:
	@$(MAKE) diff ENV="$(ENV)" ENABLED_SERVICES=clickhouse
clickhouse-down:
	@$(MAKE) down ENV="$(ENV)" ENABLED_SERVICES=clickhouse

rabbitmq-up:
	@$(MAKE) up ENV="$(ENV)" ENABLED_SERVICES=rabbitmq
rabbitmq-diff:
	@$(MAKE) diff ENV="$(ENV)" ENABLED_SERVICES=rabbitmq
rabbitmq-down:
	@$(MAKE) down ENV="$(ENV)" ENABLED_SERVICES=rabbitmq

monitoring-up:
	@$(MAKE) up ENV="$(ENV)" ENABLED_SERVICES=netdata
monitoring-diff:
	@$(MAKE) diff ENV="$(ENV)" ENABLED_SERVICES=netdata
monitoring-down:
	@$(MAKE) down ENV="$(ENV)" ENABLED_SERVICES=netdata

kubeconfig-fetch:
	@if [ -z "$(SSH_HOST)" ]; then echo "✗ SSH_HOST не задан"; exit 1; fi
	@mkdir -p k8s/config
	@echo "Fetching kubeconfig from $(REMOTE) -> $(KUBECONFIG)"
	@$(SSH) $(REMOTE) "microk8s config" > "$(KUBECONFIG)"
	@chmod 600 "$(KUBECONFIG)"
	@echo "✓ Saved: $(KUBECONFIG)"

kubeconfig-info:
	@if [ ! -f "$(KUBECONFIG)" ]; then \
		echo "✗ Файл $(KUBECONFIG) не найден"; \
		echo "  Сначала выполните: make kubeconfig-fetch ENV=$(ENV)"; \
		exit 1; \
	fi
	@kubectl --kubeconfig "$(KUBECONFIG)" cluster-info

# Check and setup microk8s on remote server
# Required addons: registry, dns, ingress, storage, metrics-server
# Also checks/installs docker for image management
# Проверка «включён»: только блок между "enabled:" и "disabled:" (раньше grep -A 20
# захватывал disabled и metrics-server из disabled ошибочно считался включённым).
# Usage: make microk8s-setup ENV=prod
microk8s-setup:
	@if [ -z "$(SSH_HOST)" ]; then echo "✗ SSH_HOST не задан (используйте environments/$(ENV).mk или SSH_HOST=...)"; exit 1; fi
	@echo "=== Проверка microk8s на $(REMOTE) ==="
	@SCRIPT=$$(mktemp); \
	printf '%s\n' \
		'set -uo pipefail' \
		'echo "[1/5] Проверка установки microk8s..."' \
		'if ! snap list microk8s >/dev/null 2>&1; then' \
		'  echo "  ✗ microk8s не установлен"' \
		'  echo "  → Устанавливаю microk8s..."' \
		'  sudo snap install microk8s --classic --channel=latest/stable 2>&1 | grep -v "^$$" || true' \
		'  echo "  ✓ microk8s установлен"' \
		'  echo "  → Ожидание готовности microk8s [до 120 сек]..."' \
		'  if ! sudo microk8s status --wait-ready --timeout 120 2>&1; then' \
		'    echo "  ✗ microk8s не запустился за 120 секунд"' \
		'    exit 1' \
		'  fi' \
		'  echo "  ✓ microk8s готов"' \
		'else' \
		'  VERSION=$$(snap list microk8s | grep "^microk8s" | tr -s " " | cut -d" " -f2)' \
		'  echo "  ✓ microk8s установлен [версия: $$VERSION]"' \
		'  echo "[2/5] Проверка статуса microk8s..."' \
		'  if ! sudo microk8s status --wait-ready --timeout 30 >/dev/null 2>&1; then' \
		'    echo "  ⚠ microk8s не запущен"' \
		'    echo "  → Запускаю microk8s..."' \
		'    sudo microk8s start 2>&1 || true' \
		'    echo "  → Ожидание готовности [до 120 сек]..."' \
		'    if ! sudo microk8s status --wait-ready --timeout 120 2>&1; then' \
		'      echo "  ✗ microk8s не запустился за 120 секунд"' \
		'      exit 1' \
		'    fi' \
		'    echo "  ✓ microk8s запущен"' \
		'  else' \
		'    echo "  ✓ microk8s запущен и готов"' \
		'  fi' \
		'fi' \
		'' \
		'echo "[3/5] Проверка необходимых аддонов..."' \
		'ADDONS="registry dns ingress storage metrics-server"' \
		'is_addon_enabled() { echo "$$ENABLED_BLOCK" | grep -qE "^    $$1 "; }' \
		'ENABLED_BLOCK=$$(sudo microk8s status 2>/dev/null | awk '\''/^  enabled:/{e=1;next} /^  disabled:/{e=0;next} e{print}'\'')' \
		'NEED_ENABLE=""' \
		'for addon in $$ADDONS; do' \
		'  if is_addon_enabled $$addon; then' \
		'    echo "  ✓ $$addon: включен"' \
		'  else' \
		'    echo "  ✗ $$addon: не включен"' \
		'    NEED_ENABLE="$$NEED_ENABLE $$addon"' \
		'  fi' \
		'done' \
		'' \
		'if [ -n "$$NEED_ENABLE" ]; then' \
		'  echo "[4/5] Включение аддонов:$$NEED_ENABLE"' \
		'  for addon in $$NEED_ENABLE; do' \
		'    echo "  → Включаю $$addon..."' \
		'    sudo microk8s enable $$addon 2>&1 | grep -v "^$$" || true' \
		'    sleep 3' \
		'    ENABLED_BLOCK=$$(sudo microk8s status 2>/dev/null | awk '\''/^  enabled:/{e=1;next} /^  disabled:/{e=0;next} e{print}'\'')' \
		'    RETRIES=0' \
		'    while [ $$RETRIES -lt 10 ]; do' \
		'      if echo "$$ENABLED_BLOCK" | grep -qE "^    $$addon "; then' \
		'        break' \
		'      fi' \
		'      sleep 3' \
		'      RETRIES=$$((RETRIES + 1))' \
		'      echo "    ожидание... [$$RETRIES/10]"' \
		'      ENABLED_BLOCK=$$(sudo microk8s status 2>/dev/null | awk '\''/^  enabled:/{e=1;next} /^  disabled:/{e=0;next} e{print}'\'')' \
		'    done' \
		'    if echo "$$ENABLED_BLOCK" | grep -qE "^    $$addon "; then' \
		'      echo "  ✓ $$addon: включен"' \
		'    else' \
		'      echo "  ⚠ $$addon: включение может занять время [проверьте: sudo microk8s status]"' \
		'    fi' \
		'  done' \
		'else' \
		'  echo "[4/5] Все аддоны уже включены"' \
		'fi' \
		'' \
		'echo "[5/5] Проверка установки docker..."' \
		'if ! command -v docker >/dev/null 2>&1; then' \
		'  echo "  ✗ docker не установлен"' \
		'  echo "  → Устанавливаю docker..."' \
		'  sudo snap install docker 2>&1 | grep -v "^$$" || true' \
		'  if command -v docker >/dev/null 2>&1; then' \
		'    DOCKER_VERSION=$$(docker --version 2>&1 | head -1)' \
		'    echo "  ✓ docker установлен [$$DOCKER_VERSION]"' \
		'  else' \
		'    echo "  ⚠ docker установка может занять время (проверьте: snap list docker)"' \
		'  fi' \
		'else' \
		'  DOCKER_VERSION=$$(docker --version 2>&1 | head -1)' \
		'  echo "  ✓ docker установлен [$$DOCKER_VERSION]"' \
		'fi' \
		'' \
		'echo ""' \
		'echo "=== Итоговый статус microk8s ==="' \
		'sudo microk8s status 2>&1 | head -20' \
		'echo ""' \
		'echo "=== Версия ==="' \
		'sudo microk8s version 2>&1' \
		'echo ""' \
		'echo "✓ microk8s настроен и готов к работе"' \
		> "$$SCRIPT"; \
	$(SCP) "$$SCRIPT" "$(REMOTE):/tmp/microk8s-setup.sh" >/dev/null 2>&1; \
	$(SSH) -t $(REMOTE) "bash /tmp/microk8s-setup.sh; rm -f /tmp/microk8s-setup.sh"; \
	rm -f "$$SCRIPT"

microk8s-uninstall:
	@if [ -z "$(SSH_HOST)" ]; then echo "✗ SSH_HOST не задан (используйте environments/$(ENV).mk или SSH_HOST=...)"; exit 1; fi
	@echo "=== Uninstall microk8s on $(REMOTE) ==="
	@SCRIPT=$$(mktemp); \
	printf '%s\n' \
		'set -euo pipefail' \
		'REMOVE_DOCKER="$${REMOVE_DOCKER:-0}"' \
		'echo "[1/4] Stop microk8s (if installed)..."' \
		'if snap list microk8s >/dev/null 2>&1; then' \
		'  sudo microk8s stop >/dev/null 2>&1 || true' \
		'  echo "  ✓ stopped"' \
		'else' \
		'  echo "  ✓ microk8s not installed"' \
		'fi' \
		'' \
		'echo "[2/4] Remove snap microk8s..."' \
		'if snap list microk8s >/dev/null 2>&1; then' \
		'  sudo snap remove microk8s --purge 2>&1 | grep -v "^$$" || true' \
		'  echo "  ✓ removed"' \
		'else' \
		'  echo "  ✓ already absent"' \
		'fi' \
		'' \
		'echo "[3/4] Cleanup leftover dirs/interfaces..."' \
		'sudo rm -rf /var/snap/microk8s /var/snap/microk8s/common 2>/dev/null || true' \
		'sudo rm -rf /var/lib/kubelet /var/lib/cni /etc/cni/net.d 2>/dev/null || true' \
		'sudo rm -rf /run/flannel /var/run/flannel 2>/dev/null || true' \
		'for i in cni0 flannel.1 vxlan.calico tunl0; do sudo ip link delete "$$i" >/dev/null 2>&1 || true; done' \
		'echo "  ✓ cleanup done"' \
		'' \
		'echo "[4/4] Optionally remove docker snap..."' \
		'if [ "$$REMOVE_DOCKER" = "1" ]; then' \
		'  if snap list docker >/dev/null 2>&1; then' \
		'    sudo snap remove docker --purge 2>&1 | grep -v "^$$" || true' \
		'    echo "  ✓ docker removed"' \
		'  else' \
		'    echo "  ✓ docker not installed"' \
		'  fi' \
		'else' \
		'  echo "  (skip) REMOVE_DOCKER=$$REMOVE_DOCKER"' \
		'fi' \
		'' \
		'echo "✓ microk8s uninstall completed"' \
		> "$$SCRIPT"; \
	$(SCP) "$$SCRIPT" "$(REMOTE):/tmp/microk8s-uninstall.sh" >/dev/null 2>&1; \
	$(SSH) -t $(REMOTE) "REMOVE_DOCKER=$(REMOVE_DOCKER) bash /tmp/microk8s-uninstall.sh; rm -f /tmp/microk8s-uninstall.sh"; \
	rm -f "$$SCRIPT"

ssh:
	@if [ -z "$(SSH_HOST)" ]; then echo "✗ SSH_HOST не задан"; exit 1; fi
	@$(SSH) $(REMOTE)

env-new:
	@if [ -z "$(ENV)" ]; then echo "✗ ENV не задан"; exit 1; fi
	@mkdir -p environments k8s/config
	@if [ ! -f "environments/$(ENV).mk" ]; then \
		printf '%s\n' \
			"# overrides for ENV=$(ENV)" \
			"# SSH_HOST=your-host" \
			"# SSH_USER=ubuntu" \
			"# SSH_PORT=22" \
			"# SSH_KEY=/path/to/id_ed25519" \
			"#" \
			"# Registry for images (microk8s addon registry is usually localhost:32000)" \
			"REGISTRY ?= localhost:32000" \
			"#" \
			"# kubeconfig path for this environment" \
			"KUBECONFIG ?= k8s/config/$(ENV)" \
			> "environments/$(ENV).mk"; \
		echo "✓ created environments/$(ENV).mk"; \
	fi
	@if [ ! -f "$(KUBECONFIG)" ]; then \
		echo "# put kubeconfig here (or run: make kubeconfig-fetch ENV=$(ENV) SSH_HOST=... SSH_KEY=...)" > "$(KUBECONFIG)"; \
	fi
	@for s in $(SERVICES); do \
		if [ -f "$$s/values-$(ENV).yaml" ]; then \
			continue; \
		fi; \
		if [ -f "$$s/values-$(ENV).yaml" ]; then \
			continue; \
		elif [ "$(ENV)" = "prod" ] && [ -f "$$s/values-prod.yaml" ]; then \
			cp "$$s/values-prod.yaml" "$$s/values-$(ENV).yaml"; \
			echo "✓ created $$s/values-$(ENV).yaml (from values-prod.yaml)"; \
		elif [ -f "$$s/values-dev.yaml" ]; then \
			cp "$$s/values-dev.yaml" "$$s/values-$(ENV).yaml"; \
			echo "✓ created $$s/values-$(ENV).yaml (from values-dev.yaml)"; \
		else \
			echo "⚠ $$s: missing values-dev.yaml (skip)"; \
		fi; \
	done
	@echo "✓ Environment skeleton created: $(ENV)"

env-backup:
	@if [ -z "$(ENV)" ]; then echo "✗ ENV не задан"; exit 1; fi
	@command -v kubectl >/dev/null 2>&1 || { echo "✗ kubectl не найден"; exit 1; }
	@if [ ! -f "$(KUBECONFIG)" ]; then \
		echo "✗ Файл kubeconfig не найден: $(KUBECONFIG)"; \
		echo "  Сначала выполните: make kubeconfig-fetch ENV=$(ENV)"; \
		exit 1; \
	fi
	@if [ ! -f "environments/$(ENV).yaml" ]; then \
		echo "✗ Файл environments/$(ENV).yaml не найден"; \
		echo "  Создайте его командой: make env-new ENV=$(ENV)"; \
		exit 1; \
	fi
	@if [ "$${CONFIRM:-0}" != "1" ]; then \
		echo "⚠ Будет сделан локальный бэкап Kubernetes secrets/configmaps (может содержать пароли)."; \
		if [ -t 0 ]; then \
			printf "Сделать локальный бэкап в tar.gz? [y/N] "; \
			read -r ans; \
			case "$$ans" in y|Y|yes|YES) : ;; *) echo "Aborted"; exit 1 ;; esac; \
		else \
			echo "✗ Для неинтерактивного запуска требуется подтверждение: CONFIRM=1"; \
			exit 1; \
		fi; \
	fi
	@umask 077; \
	install -d -m 700 environments/backups; \
	TS=$$(date +%Y%m%d-%H%M%S); \
	ARCHIVE="environments/backups/$(ENV)-$${TS}.tar.gz"; \
	TMP_DIR=$$(mktemp -d); \
	OUT_DIR="$$TMP_DIR/$(ENV)"; \
	mkdir -p "$$OUT_DIR"; \
	cp "environments/$(ENV).yaml" "$$OUT_DIR/environments.$(ENV).yaml"; \
	NAMESPACES=$$(awk '/^[A-Za-z0-9_-]+:/{svc=$$1} /namespace:/{print $$2}' "environments/$(ENV).yaml" | sort -u); \
	if [ -z "$$NAMESPACES" ]; then \
		echo "✗ Не удалось извлечь namespaces из environments/$(ENV).yaml"; \
		rm -rf "$$TMP_DIR"; \
		exit 1; \
	fi; \
	for ns in $$NAMESPACES; do \
		mkdir -p "$$OUT_DIR/namespaces/$$ns"; \
		echo "=== backup namespace: $$ns ==="; \
		kubectl --kubeconfig "$(KUBECONFIG)" get secret -n "$$ns" \
			--field-selector type!=kubernetes.io/service-account-token,type!=helm.sh/release.v1 \
			-o yaml > "$$OUT_DIR/namespaces/$$ns/secrets.yaml" 2>/dev/null || true; \
		kubectl --kubeconfig "$(KUBECONFIG)" get configmap -n "$$ns" \
			--field-selector metadata.name!=kube-root-ca.crt \
			-o yaml > "$$OUT_DIR/namespaces/$$ns/configmaps.yaml" 2>/dev/null || true; \
	done; \
	tar -czf "$$ARCHIVE" -C "$$TMP_DIR" "$(ENV)"; \
	rm -rf "$$TMP_DIR"; \
	echo "✓ Saved: $$ARCHIVE"

monitoring-status:
	@$(MAKE) -C monitoring/netdata status ENV=$(ENV)

monitoring-logs:
	@$(MAKE) -C monitoring/netdata logs ENV=$(ENV)

monitoring-port-forward:
	@$(MAKE) -C monitoring/netdata port-forward ENV=$(ENV)

monitoring-top-nodes:
	@$(MAKE) -C monitoring/netdata top-nodes ENV=$(ENV)

monitoring-events:
	@$(MAKE) -C monitoring/netdata events ENV=$(ENV)

monitoring-pod-events:
	@$(MAKE) -C monitoring/netdata pod-events ENV=$(ENV) POD="$(POD)"

monitoring-describe-pod:
	@$(MAKE) -C monitoring/netdata describe-pod ENV=$(ENV) POD="$(POD)"
