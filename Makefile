.PHONY: help \
	status top-totals \
	images-save images-push images-push-remote up diff down \
	kafka-verify rabbitmq-verify \
	postgres-verify redis-verify minio-verify clickhouse-verify \
	check-updates postgres-check-updates redis-check-updates kafka-check-updates \
	minio-check-updates clickhouse-check-updates rabbitmq-check-updates \
	pg-app-create pg-app-show-creds pg-app-psql pg-app-drop redis-app-create redis-app-show-creds redis-app-drop kafka-app-create kafka-app-show-creds kafka-app-drop minio-app-create minio-app-show-creds minio-app-drop clickhouse-app-create clickhouse-app-show-creds clickhouse-app-drop rabbitmq-app-create rabbitmq-app-show-creds rabbitmq-app-drop \
	kafka-topic-create kafka-topic-alter kafka-topic-describe kafka-topic-list \
	apps-merge-print apps-local-src-helm-sets apps-apply apps-conf-template apps-src-clone app-local-src-hostpath-mount \
	postgres-status postgres-logs postgres-shell postgres-db postgres-up postgres-diff postgres-down \
	redis-status redis-logs redis-shell redis-up redis-diff redis-down \
	clickhouse-status clickhouse-logs clickhouse-shell clickhouse-up clickhouse-diff clickhouse-down \
	rabbitmq-status rabbitmq-logs rabbitmq-shell rabbitmq-up rabbitmq-diff rabbitmq-down \
	kafka-bootstrap kafka-reset kafka-status kafka-logs kafka-shell kafka-up kafka-diff kafka-down \
	minio-status minio-logs minio-shell minio-up minio-diff minio-down \
	minio-app-append \
	env-new env-backup kubeconfig-fetch kubeconfig-microk8s-local kubeconfig-info microk8s-setup microk8s-uninstall ssh \
	k8s-port-expose-show k8s-port-expose-patch k8s-port-expose-apply \
	monitoring-status monitoring-logs monitoring-port-forward monitoring-up monitoring-diff monitoring-down \
	monitoring-top-nodes monitoring-events monitoring-pod-events monitoring-describe-pod \
	redis-backup redis-restore-acl kafka-backup-meta kafka-restore-meta-topics minio-backup-meta minio-restore-meta clickhouse-backup clickhouse-restore rabbitmq-backup-defs rabbitmq-restore-defs \
	backup-all \
	infra-control-parity-check infra-lab

# Do not print "Entering/Leaving directory ..." on recursive make
MAKEFLAGS += --no-print-directory

ENV ?= local

# Реестр приложений: apps/registry.yaml; секреты — apps/conf/<app>/*.yaml (не в git).
REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
APPS_REGISTRY ?= $(REPO_ROOT)/apps/registry.yaml

ifneq ($(wildcard $(REPO_ROOT)/.tools/yq-mikefarah),)
YQ ?= $(REPO_ROOT)/.tools/yq-mikefarah
else
YQ ?= yq
endif
export YQ

# per-environment overrides (SSH_HOST/SSH_KEY/KUBECONFIG/REGISTRY/etc)
-include environments/$(ENV).mk

SERVICES := postgres kafka redis minio clickhouse rabbitmq

REGISTRY ?= localhost:32000

# k8s-port-expose: локальный манифест TCP (пусто → k8s-port-expose/ports-$(ENV).yaml)
PORT_EXPOSE_CONFIG ?=

KUBECONFIG ?= k8s/config/$(ENV)
# Always use an absolute kubeconfig path (important for `make -C <service> ...`)
KUBECONFIG := $(abspath $(KUBECONFIG))
# Всегда экспортируем путь: при отсутствии файла kubectl завершится с явной ошибкой (без тихого ~/.kube/config).
export KUBECONFIG

SSH_USER ?= ubuntu
SSH_HOST ?=
SSH_PORT ?= 22
SSH_KEY ?= $(HOME)/.ssh/id_rsa
SSH_OPTS ?= -o StrictHostKeyChecking=accept-new

REMOTE ?= $(SSH_USER)@$(SSH_HOST)
SSH := ssh $(SSH_OPTS) -p $(SSH_PORT) -i $(SSH_KEY)
SCP := scp $(SSH_OPTS) -P $(SSH_PORT) -i $(SSH_KEY)

# Локальный snap MicroK8s: команда для `config` (при ошибке прав: MICROK8S_CMD='sudo microk8s' или группа microk8s).
MICROK8S_CMD ?= microk8s

# ANSI color codes
CYAN := \033[0;36m
GREEN := \033[0;32m
YELLOW := \033[0;33m
BLUE := \033[0;34m
MAGENTA := \033[0;35m
RED := \033[0;31m
BOLD := \033[1m
RESET := \033[0m

infra-lab:
	@node "$(REPO_ROOT)/scripts/infra-lab.mjs"

infra-control-parity-check:
	@node "$(REPO_ROOT)/docs/infra-control/parity-check.mjs"

help:
	@echo "$(BOLD)$(GREEN)infra$(RESET)"
	@echo ""
	@echo "$(BOLD)$(GREEN)С чего начать:$(RESET)"
	@echo "  Точка входа — $(YELLOW)Бутстрап$(RESET) (TUI: $(YELLOW)make infra-lab$(RESET)): для удалённой среды настройте SSH ($(YELLOW)environments/<ENV>.mk$(RESET), $(YELLOW)make ssh ENV=...$(RESET)) и получите kubeconfig ($(YELLOW)make kubeconfig-fetch ...$(RESET)); для работы только с локальным кластером на этой машине достаточно $(YELLOW)make kubeconfig-microk8s-local ENV=...$(RESET) (без SSH)."
	@echo ""
	@echo "$(BOLD)$(GREEN)ENV:$(RESET)"
	@echo "  make <target> $(YELLOW)ENV=local|prod|staging$(RESET) ..."
	@echo "  make status $(YELLOW)ENV=$(ENV)$(RESET)              - ноды, поды (все namespace), helm list -A"
	@echo "  make top-totals $(YELLOW)ENV=$(ENV)$(RESET)          - CPU/память: занято и доступно (allocatable; Metrics API; jq)"
	@echo "  make infra-lab          - интерактивное меню (npm install → node scripts/infra-lab.mjs)"
	@echo "  make infra-control-parity-check — сверить цели Makefile с docs/infra-control/targets.json"
	@echo ""
	@echo "$(BOLD)$(GREEN)Images:$(RESET)"
	@echo "  make images-save $(YELLOW)ENV=$(ENV)$(RESET) [$(YELLOW)SERVICE=redis$(RESET)] - Скачать/сохранить tar во всех сервисах (или только SERVICE)"
	@echo "  make images-push $(YELLOW)ENV=$(ENV)$(RESET) [$(YELLOW)SERVICE=redis$(RESET)] - docker load -> tag -> push в registry (см. REGISTRY в сервисах)"
	@echo "  make images-push-remote $(YELLOW)ENV=$(ENV)$(RESET) [$(YELLOW)SERVICE=redis$(RESET)] - scp *.tar на удалённый сервер + docker load/tag/push в registry на сервере"
	@echo ""
	@echo "$(BOLD)$(GREEN)Apps конфигурация:$(RESET)"
	@echo "  make apps-merge-print $(YELLOW)[APPS_REGISTRY=...$(RESET)] $(YELLOW)[YQ=path/to/yq$(RESET)] - сырый merge (stdout, mikefarah yq v4)"
	@echo "  make apps-local-src-helm-sets $(YELLOW)ENV=local$(RESET) $(YELLOW)APP=<name>$(RESET) — stdout: $(YELLOW)--set$(RESET) для $(YELLOW)app.volumes.$(RESET)* (hostPath=$(YELLOW)apps/src/<APP>$(RESET)) в вашем helm upgrade приложения"
	@echo "  make apps-apply $(YELLOW)ENV=$(ENV)$(RESET) $(YELLOW)[ENABLED_SERVICES=... EXCLUDE_SERVICES=...$(RESET)] $(YELLOW)[APPS_APPLY_CONTINUE_ON_ERROR=1$(RESET)] - учётки из apps/conf; по умолчанию останов на первой ошибке make"
	@echo "  make apps-conf-template $(YELLOW)APP=myapp$(RESET) $(YELLOW)[SKIP_REGISTRY=1$(RESET)] - шаблон apps/conf из apps/conf/_example + по умолчанию запись в registry (enabled: false)"
	@echo "  make apps-src-clone $(YELLOW)APP=<name>$(RESET) [$(YELLOW)APPS_REGISTRY=...$(RESET)] - git clone по repo_url (+ repo_branch) из registry → apps/src/<APP>"
	@echo "  make app-local-src-hostpath-mount $(YELLOW)ENV=local$(RESET) $(YELLOW)APP=<name>$(RESET) $(YELLOW)APP_LOCAL_K8S_WORKLOAD=<kind>/<имя>$(RESET) [$(YELLOW)pod/…|deployment/…|sts/…|ds/…$(RESET)] — hostPath $(YELLOW)apps/src/<APP>$(RESET); initContainers+containers; [$(YELLOW)APP_LOCAL_SRC_READ_ONLY=1$(RESET)] [$(YELLOW)APP_LOCAL_SRC_CONTAINER=…$(RESET)]"
	@echo ""
	@echo "  make up $(YELLOW)ENV=$(ENV)$(RESET) [$(YELLOW)ENABLED_SERVICES=postgres,redis$(RESET)] [$(YELLOW)EXCLUDE_SERVICES=kafka,clickhouse$(RESET)] [$(YELLOW)SKIP_APPS_APPLY=1$(RESET)] — helmfile apply, затем apps-apply из apps/registry.yaml и apps/conf/..."
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
	@echo "  make pg-app-psql      $(YELLOW)APP=myapp$(RESET) [$(YELLOW)ENV=$(ENV)$(RESET)] - интерактивный psql под ролью приложения"
	@echo "  make pg-app-drop      $(YELLOW)APP=myapp$(RESET) [$(YELLOW)ENV=$(ENV)$(RESET)] - удалить БД, роль и Secret (⚠ y/N; $(YELLOW)SKIP_CONFIRM=1$(RESET))"
	@echo "  make postgres-db      $(YELLOW)APP=myapp ENV=$(ENV)$(RESET) - открыть psql под ролью приложения (алиас pg-app-psql)"
	@echo "  make redis-app-create $(YELLOW)APP=myapp$(RESET) [$(YELLOW)APP_NS=myapp$(RESET)] [$(YELLOW)REDIS_DB=0$(RESET)] [$(YELLOW)APPS_REGISTRY=...$(RESET)] — следующий свободный redis_db из registry или REDIS_DB"
	@echo "  make redis-app-show-creds $(YELLOW)APP=myapp$(RESET) [$(YELLOW)ENV=$(ENV)$(RESET)] - показать креды из Secret app-redis (REDIS_KEY_PREFIX, REDIS_DB)"
	@echo "  make redis-app-drop     $(YELLOW)APP=myapp$(RESET) [$(YELLOW)ENV=$(ENV)$(RESET)] - ACL + Secret (⚠ y/N; $(YELLOW)SKIP_CONFIRM=1$(RESET))"
	@echo "  make kafka-app-create $(YELLOW)APP=myapp$(RESET) [$(YELLOW)APP_NS=myapp$(RESET)]"
	@echo "  make kafka-app-show-creds $(YELLOW)APP=myapp$(RESET) [$(YELLOW)ENV=$(ENV)$(RESET)] — креды из Secret приложения в k8s"
	@echo "  make kafka-app-drop     $(YELLOW)APP=myapp$(RESET) - SCRAM, ACL, Secret (топики не удаляются; $(YELLOW)SKIP_CONFIRM=1$(RESET))"
	@echo "  make minio-app-create $(YELLOW)APP=myapp$(RESET) [$(YELLOW)APP_NS=myapp$(RESET)]"
	@echo "  make minio-app-show-creds $(YELLOW)APP=myapp$(RESET) [$(YELLOW)ENV=$(ENV)$(RESET)] — креды из Secret приложения в k8s"
	@echo "  make minio-app-drop     $(YELLOW)APP=myapp$(RESET) [$(YELLOW)MINIO_REMOVE_BUCKETS=1$(RESET)] - пользователь/политика/Secret; bucket — второй запрос"
	@echo "  make clickhouse-app-create $(YELLOW)APP=myapp$(RESET) [$(YELLOW)APP_NS=myapp$(RESET)]"
	@echo "  make clickhouse-app-show-creds $(YELLOW)APP=myapp$(RESET) [$(YELLOW)ENV=$(ENV)$(RESET)] — креды из Secret приложения в k8s"
	@echo "  make clickhouse-app-drop $(YELLOW)APP=myapp$(RESET) - DROP DATABASE/USER + Secret"
	@echo "  make rabbitmq-app-create $(YELLOW)APP=myapp$(RESET) [$(YELLOW)APP_NS=myapp$(RESET)]"
	@echo "  make rabbitmq-app-show-creds $(YELLOW)APP=myapp$(RESET) [$(YELLOW)ENV=$(ENV)$(RESET)] — креды из Secret приложения в k8s"
	@echo "  make rabbitmq-app-drop  $(YELLOW)APP=myapp$(RESET) - vhost, пользователь, Secret"
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
	@echo "$(BOLD)$(GREEN)Backup / Restore (definitions; данные таблиц/топиков/бакетов — см. <service>/BACKUP.md):$(RESET)"
	@echo "  make backup-all $(YELLOW)ENV=$(ENV)$(RESET) [$(YELLOW)ENABLED_SERVICES=...$(RESET)] [$(YELLOW)EXCLUDE_SERVICES=...$(RESET)] [$(YELLOW)BACKUP_ALL_CONTINUE_ON_ERROR=0$(RESET)]"
	@echo "  make redis-backup / redis-restore-acl $(YELLOW)BACKUP_FILE=...$(RESET)         (RDB снимок + ACL)"
	@echo "  make kafka-backup-meta / kafka-restore-meta-topics $(YELLOW)BACKUP_FILE=...$(RESET)  (topics + ACL + SCRAM users list)"
	@echo "  make minio-backup-meta / minio-restore-meta $(YELLOW)BACKUP_FILE=...$(RESET)    (users + policies + buckets + tracking secrets)"
	@echo "  make clickhouse-backup / clickhouse-restore $(YELLOW)BACKUP_FILE=...$(RESET)    (schemas + users + grants)"
	@echo "  make rabbitmq-backup-defs / rabbitmq-restore-defs $(YELLOW)BACKUP_FILE=...$(RESET) (vhosts + users + queues + bindings)"
	@echo "  make postgres-backup / postgres-restore $(YELLOW)BACKUP_FILE=...$(RESET)        (pg_dumpall — данные)"
	@echo ""
	@echo "$(BOLD)$(GREEN)Kubeconfig/SSH:$(RESET)"
	@echo "  make kubeconfig-fetch $(YELLOW)ENV=$(ENV)$(RESET) $(YELLOW)SSH_HOST=... SSH_KEY=...$(RESET)  - kubeconfig с удалённой ноды по SSH (microk8s config)"
	@echo "  make kubeconfig-microk8s-local $(YELLOW)ENV=$(ENV)$(RESET)  - kubeconfig локального MicroK8s на этой машине (без SSH; см. MICROK8S_CMD)"
	@echo "  make kubeconfig-info $(YELLOW)ENV=$(ENV)$(RESET)  - kubectl cluster-info"
	@echo "  make microk8s-setup $(YELLOW)ENV=$(ENV)$(RESET)   - проверить/установить microk8s, необходимые модули и docker на удалённом сервере"
	@echo "  make microk8s-uninstall $(YELLOW)ENV=$(ENV)$(RESET) [$(YELLOW)REMOVE_DOCKER=1$(RESET)] - удалить microk8s (и опционально docker) на удалённом сервере"
	@echo ""
	@echo "$(BOLD)$(GREEN)k8s port expose (microk8s ingress TCP):$(RESET)"
	@echo "  make k8s-port-expose-show $(YELLOW)ENV=$(ENV)$(RESET) - DaemonSet + TCP ConfigMap (ingress)"
	@echo "  make k8s-port-expose-patch $(YELLOW)ENV=$(ENV) LAYER=tcp HOST_PORT=1883 BACKEND=myns/svc:1883$(RESET)"
	@echo "  make k8s-port-expose-patch $(YELLOW)ENV=$(ENV) LAYER=tcp HOST_PORT=1883 RM=1$(RESET) - удалить маршрут в ConfigMap"
	@echo "  make k8s-port-expose-patch $(YELLOW)ENV=$(ENV) LAYER=hostport OP=add HOST_PORT=1883 CONTAINER_PORT=1883 PORT_NAME=mqtt$(RESET)"
	@echo "  make k8s-port-expose-patch $(YELLOW)ENV=$(ENV) LAYER=hostport OP=rm HOST_PORT=1883$(RESET) - убрать hostPort из DS"
	@echo "  make k8s-port-expose-apply $(YELLOW)ENV=$(ENV)$(RESET) [$(YELLOW)PORT_EXPOSE_CONFIG=...$(RESET)] — применить $(YELLOW)k8s-port-expose/ports-$(ENV).yaml$(RESET) (или указанный файл)"
	@echo "  опция: $(YELLOW)DRY_RUN=client|server$(RESET) — проверка без записи (server = admission)"
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

apps-merge-print:
	@"$(REPO_ROOT)/scripts/apps-merge-config.sh" "$(APPS_REGISTRY)" "$(REPO_ROOT)"

apps-local-src-helm-sets:
	@test "$(ENV)" = "local" || (echo '✗ apps-local-src-helm-sets только при ENV=local' >&2; exit 1)
	@test -n "$(APP)" || (echo '✗ Укажите APP=<name>' >&2; exit 1)
	@ENV="$(ENV)" REPO_ROOT="$(REPO_ROOT)" APP="$(APP)" APPS_REGISTRY="$(APPS_REGISTRY)" YQ="$(YQ)" \
		"$(REPO_ROOT)/scripts/apps-local-src-helm-sets.sh"

apps-apply:
	@APPS_REGISTRY="$(APPS_REGISTRY)" REPO_ROOT="$(REPO_ROOT)" ENV="$(ENV)" \
	ENABLED_SERVICES="$(ENABLED_SERVICES)" EXCLUDE_SERVICES="$(EXCLUDE_SERVICES)" \
	APPS_APPLY_CONTINUE_ON_ERROR="$(APPS_APPLY_CONTINUE_ON_ERROR)" \
	"$(REPO_ROOT)/scripts/apps-apply.sh"

# Usage: make apps-conf-template APP=myapp [SKIP_REGISTRY=1]
apps-conf-template:
	@if [ -z "$(APP)" ]; then echo "✗ Задайте APP=myapp"; exit 1; fi
	@SKIP_REGISTRY="$(SKIP_REGISTRY)" "$(REPO_ROOT)/scripts/apps-conf-template.sh" "$(REPO_ROOT)" "$(APP)"

# Клон исходников в apps/src/<APP> по полям repo_url / repo_branch в registry (см. apps/registry.yaml).
apps-src-clone:
	@test -n "$(APP)" || (echo '✗ Укажите APP=<name> (поле name из apps/registry.yaml)' >&2; exit 1)
	@url=$$(APP="$(APP)" "$(YQ)" -r '.apps[] | select(.name == strenv(APP)) | .repo_url // ""' "$(APPS_REGISTRY)"); \
	br=$$(APP="$(APP)" "$(YQ)" -r '.apps[] | select(.name == strenv(APP)) | .repo_branch // ""' "$(APPS_REGISTRY)"); \
	if [ -z "$$url" ]; then echo "✗ Для APP=$(APP) в registry не задан repo_url" >&2; exit 1; fi; \
	"$(REPO_ROOT)/scripts/apps-src-clone.sh" "$(REPO_ROOT)" "$(APP)" "$$url" "$$br"

app-local-src-hostpath-mount:
	@test "$(ENV)" = "local" || (echo '✗ app-local-src-hostpath-mount только при ENV=local' >&2; exit 1)
	@test -n "$(APP)" || (echo '✗ Укажите APP=<name>' >&2; exit 1)
	@test -n "$(APP_LOCAL_K8S_WORKLOAD)" || (echo '✗ Укажите APP_LOCAL_K8S_WORKLOAD=deployment/<имя> (или statefulset|daemonset)' >&2; exit 1)
	@ENV="$(ENV)" REPO_ROOT="$(REPO_ROOT)" APP="$(APP)" APPS_REGISTRY="$(APPS_REGISTRY)" \
		APPS_MERGED_FILE="$(APPS_MERGED_FILE)" APP_NS="$(APP_NS)" \
		APP_LOCAL_K8S_WORKLOAD="$(APP_LOCAL_K8S_WORKLOAD)" \
		APP_LOCAL_SRC_MOUNT_PATH="$(APP_LOCAL_SRC_MOUNT_PATH)" \
		APP_LOCAL_SRC_CONTAINER="$(APP_LOCAL_SRC_CONTAINER)" \
		APP_LOCAL_SRC_READ_ONLY="$(APP_LOCAL_SRC_READ_ONLY)" \
		"$(REPO_ROOT)/scripts/app-local-src-hostpath-mount.sh"

pg-app-create:
	@$(MAKE) -C postgres app-create APP="$(APP)" APP_NS="$(APP_NS)" ENV="$(ENV)" KUBECONFIG="$(KUBECONFIG)" POSTGRES_ADMIN_PASSWORD="$(POSTGRES_ADMIN_PASSWORD)" APPS_REGISTRY="$(APPS_REGISTRY)"
postgres-db:
	@$(MAKE) pg-app-psql APP="$(APP)" APP_NS="$(APP_NS)" ENV="$(ENV)" KUBECONFIG="$(KUBECONFIG)"
pg-app-psql:
	@$(MAKE) -C postgres app-psql APP="$(APP)" APP_NS="$(APP_NS)" ENV="$(ENV)" KUBECONFIG="$(KUBECONFIG)"
pg-app-show-creds:
	@$(MAKE) -C postgres app-show-creds APP="$(APP)" APP_NS="$(APP_NS)" ENV="$(ENV)" KUBECONFIG="$(KUBECONFIG)"
pg-app-drop:
	@$(MAKE) -C postgres app-drop APP="$(APP)" APP_NS="$(APP_NS)" ENV="$(ENV)" KUBECONFIG="$(KUBECONFIG)" POSTGRES_ADMIN_PASSWORD="$(POSTGRES_ADMIN_PASSWORD)" SKIP_CONFIRM="$(SKIP_CONFIRM)"
pg-app-verify:
	@$(MAKE) -C postgres app-verify APP="$(APP)" APP_NS="$(APP_NS)" ENV="$(ENV)" KUBECONFIG="$(KUBECONFIG)"

# Не передаём REDIS_AUTH_* с пустым значением — иначе затираются дефолты redis/Makefile (?=).
redis-app-create:
	@$(MAKE) -C redis app-create APP="$(APP)" APP_NS="$(APP_NS)" ENV="$(ENV)" KUBECONFIG="$(KUBECONFIG)" APPS_REGISTRY="$(APPS_REGISTRY)" \
		$(if $(strip $(REDIS_AUTH_SECRET_NAME)),REDIS_AUTH_SECRET_NAME="$(REDIS_AUTH_SECRET_NAME)") \
		$(if $(strip $(REDIS_AUTH_SECRET_PASSWORD_KEY)),REDIS_AUTH_SECRET_PASSWORD_KEY="$(REDIS_AUTH_SECRET_PASSWORD_KEY)") \
		$(if $(filter-out undefined,$(origin REDIS_DB)),REDIS_DB="$(REDIS_DB)")
redis-app-show-creds:
	@$(MAKE) -C redis app-show-creds APP="$(APP)" APP_NS="$(APP_NS)" ENV="$(ENV)" KUBECONFIG="$(KUBECONFIG)"

redis-app-drop:
	@$(MAKE) -C redis app-drop APP="$(APP)" APP_NS="$(APP_NS)" ENV="$(ENV)" KUBECONFIG="$(KUBECONFIG)" SKIP_CONFIRM="$(SKIP_CONFIRM)" \
		$(if $(strip $(REDIS_AUTH_SECRET_NAME)),REDIS_AUTH_SECRET_NAME="$(REDIS_AUTH_SECRET_NAME)") \
		$(if $(strip $(REDIS_AUTH_SECRET_PASSWORD_KEY)),REDIS_AUTH_SECRET_PASSWORD_KEY="$(REDIS_AUTH_SECRET_PASSWORD_KEY)") \
		$(if $(strip $(APP_USER)),APP_USER="$(APP_USER)")

kafka-app-create:
	@$(MAKE) -C kafka app-create APP="$(APP)" APP_NS="$(APP_NS)" APPS_REGISTRY="$(APPS_REGISTRY)"

kafka-app-show-creds:
	@$(MAKE) -C kafka app-show-creds APP="$(APP)" APP_NS="$(APP_NS)" KUBECONFIG="$(KUBECONFIG)"

kafka-app-drop:
	@$(MAKE) -C kafka app-drop APP="$(APP)" APP_NS="$(APP_NS)" APP_USER="$(APP_USER)" KUBECONFIG="$(KUBECONFIG)" SKIP_CONFIRM="$(SKIP_CONFIRM)"

rabbitmq-app-create:
	@$(MAKE) -C rabbitmq app-create APP="$(APP)" APP_NS="$(APP_NS)" APPS_REGISTRY="$(APPS_REGISTRY)"

rabbitmq-app-show-creds:
	@$(MAKE) -C rabbitmq app-show-creds APP="$(APP)" APP_NS="$(APP_NS)" ENV="$(ENV)" KUBECONFIG="$(KUBECONFIG)"

rabbitmq-app-drop:
	@$(MAKE) -C rabbitmq app-drop APP="$(APP)" APP_NS="$(APP_NS)" ENV="$(ENV)" KUBECONFIG="$(KUBECONFIG)" \
		APP_VHOST="$(APP_VHOST)" APP_USER="$(APP_USER)" APP_SECRET_NAME="$(APP_SECRET_NAME)" SKIP_CONFIRM="$(SKIP_CONFIRM)"

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
	@$(MAKE) -C minio app-create APPS_REGISTRY="$(APPS_REGISTRY)" \
		APP="$(APP)" APP_NS="$(APP_NS)" \
		BUCKET="$(BUCKET)" PREFIX="$(PREFIX)" \
		ACCESS_MODE="$(ACCESS_MODE)" PUBLIC_READ="$(PUBLIC_READ)" PUBLIC_LIST="$(PUBLIC_LIST)" \
		VERSIONING="$(VERSIONING)" QUOTA="$(QUOTA)" TAGS="$(TAGS)" LIFECYCLE_JSON="$(LIFECYCLE_JSON)" \
		OBJECT_LOCK="$(OBJECT_LOCK)" RETENTION_DAYS="$(RETENTION_DAYS)" \
		ACCESS_KEY="$(ACCESS_KEY)" SECRET_KEY="$(SECRET_KEY)" MINIO_SCHEME="$(MINIO_SCHEME)" \
		APP_PUBLIC_ENDPOINT="$(APP_PUBLIC_ENDPOINT)"

minio-app-show-creds:
	@$(MAKE) -C minio app-show-creds APP="$(APP)" APP_NS="$(APP_NS)" APP_SECRET_NAME="$(APP_SECRET_NAME)" ENV="$(ENV)" KUBECONFIG="$(KUBECONFIG)"

minio-app-drop:
	@$(MAKE) -C minio app-drop APP="$(APP)" APP_NS="$(APP_NS)" ENV="$(ENV)" KUBECONFIG="$(KUBECONFIG)" \
		ACCESS_KEY="$(ACCESS_KEY)" APP_SECRET_NAME="$(APP_SECRET_NAME)" SKIP_CONFIRM="$(SKIP_CONFIRM)" MINIO_REMOVE_BUCKETS="$(MINIO_REMOVE_BUCKETS)"

clickhouse-app-create:
	@$(MAKE) -C clickhouse app-create \
		APP="$(APP)" APP_NS="$(APP_NS)" DB="$(DB)" APP_USER="$(APP_USER)" \
		APP_SECRET_NAME="$(APP_SECRET_NAME)" ADMIN_USER="$(ADMIN_USER)" \
		KUBECONFIG="$(KUBECONFIG)" APPS_REGISTRY="$(APPS_REGISTRY)"

clickhouse-app-show-creds:
	@$(MAKE) -C clickhouse app-show-creds \
		APP="$(APP)" APP_NS="$(APP_NS)" APP_SECRET_NAME="$(APP_SECRET_NAME)" KUBECONFIG="$(KUBECONFIG)"

clickhouse-app-drop:
	@$(MAKE) -C clickhouse app-drop \
		APP="$(APP)" APP_NS="$(APP_NS)" ENV="$(ENV)" KUBECONFIG="$(KUBECONFIG)" \
		DB="$(DB)" APP_USER="$(APP_USER)" APP_SECRET_NAME="$(APP_SECRET_NAME)" ADMIN_USER="$(ADMIN_USER)" SKIP_CONFIRM="$(SKIP_CONFIRM)"

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
	if ! kubectl get secret -n postgres postgres-postgresql >/dev/null 2>&1; then \
		echo "PostgreSQL admin secret not found (postgres/postgres-postgresql). Creating one for first install..."; \
		command -v openssl >/dev/null 2>&1 || { echo "✗ openssl не найден (нужен для генерации пароля)"; exit 1; }; \
		PG_PASSWORD=$$(openssl rand -hex 16); \
		kubectl create namespace postgres --dry-run=client -o yaml | kubectl apply -f - >/dev/null; \
		kubectl create secret generic postgres-postgresql -n postgres \
			--from-literal=postgres-password="$$PG_PASSWORD" \
			>/dev/null; \
	fi; \
	if ! kubectl get secret -n minio minio >/dev/null 2>&1; then \
		echo "MinIO root secret not found (minio/minio). Creating one for first install..."; \
		command -v openssl >/dev/null 2>&1 || { echo "✗ openssl не найден (нужен для генерации пароля)"; exit 1; }; \
		MINIO_ROOT_PASSWORD=$$(openssl rand -hex 16); \
		kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f - >/dev/null; \
		kubectl create secret generic minio -n minio \
			--from-literal=root-user="admin" \
			--from-literal=root-password="$$MINIO_ROOT_PASSWORD" \
			>/dev/null; \
	fi; \
	if ! kubectl get secret -n clickhouse clickhouse >/dev/null 2>&1; then \
		echo "ClickHouse admin secret not found (clickhouse/clickhouse). Creating one for first install..."; \
		command -v openssl >/dev/null 2>&1 || { echo "✗ openssl не найден (нужен для генерации пароля)"; exit 1; }; \
		CH_PASSWORD=$$(openssl rand -hex 16); \
		kubectl create namespace clickhouse --dry-run=client -o yaml | kubectl apply -f - >/dev/null; \
		kubectl create secret generic clickhouse -n clickhouse \
			--from-literal=admin-password="$$CH_PASSWORD" \
			>/dev/null; \
	fi; \
	kafka_active=0; \
	if [ -n "$(ENABLED_SERVICES)" ]; then \
		echo ",$(ENABLED_SERVICES)," | grep -qF ",kafka," && kafka_active=1; \
	else \
		echo ",$(EXCLUDE_SERVICES)," | grep -qF ",kafka," || kafka_active=1; \
	fi; \
	if [ $$kafka_active -eq 1 ]; then \
		$(MAKE) -C kafka secrets-init ENV="$(ENV)" KUBECONFIG="$(KUBECONFIG)"; \
	fi; \
	ENV=$(ENV) REDIS_PASSWORD="$$REDIS_PASSWORD" RABBITMQ_PASSWORD="$$RABBITMQ_PASSWORD" RABBITMQ_ERLANG_COOKIE="$$RABBITMQ_COOKIE" ENABLED_SERVICES="$(ENABLED_SERVICES)" EXCLUDE_SERVICES="$(EXCLUDE_SERVICES)" helmfile -f helmfile.yaml.gotmpl -e default apply; \
	if [ "$(SKIP_APPS_APPLY)" != "1" ]; then \
		APPS_REGISTRY="$(APPS_REGISTRY)" REPO_ROOT="$(REPO_ROOT)" ENV="$(ENV)" ENABLED_SERVICES="$(ENABLED_SERVICES)" EXCLUDE_SERVICES="$(EXCLUDE_SERVICES)" APPS_APPLY_CONTINUE_ON_ERROR="$(APPS_APPLY_CONTINUE_ON_ERROR)" "$(REPO_ROOT)/scripts/apps-apply.sh"; \
	fi

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

kubeconfig-microk8s-local:
	@mkdir -p k8s/config
	@echo "Local MicroK8s ($(MICROK8S_CMD)) -> $(KUBECONFIG)"
	@$(MICROK8S_CMD) config > "$(KUBECONFIG)"
	@chmod 600 "$(KUBECONFIG)"
	@echo "✓ Saved: $(KUBECONFIG)"

kubeconfig-info:
	@if [ ! -f "$(KUBECONFIG)" ]; then \
		echo "✗ Файл $(KUBECONFIG) не найден"; \
		echo "  Сначала: make kubeconfig-fetch ENV=$(ENV) … или make kubeconfig-microk8s-local ENV=$(ENV)"; \
		exit 1; \
	fi
	@kubectl --kubeconfig "$(KUBECONFIG)" cluster-info

# Cluster overview: uses KUBECONFIG from environments/$(ENV).mk when present (see Makefile header)
status:
	@echo "$(BOLD)ENV=$(ENV)$(RESET)"
	@if [ -n "$$KUBECONFIG" ]; then echo "KUBECONFIG=$$KUBECONFIG"; else echo "KUBECONFIG: не задан (kubectl: ~/.kube/config)"; fi
	@echo ""
	@echo "$(BOLD)Nodes$(RESET)"
	@kubectl get nodes -o wide
	@echo ""
	@echo "$(BOLD)Pods (all namespaces)$(RESET)"
	@kubectl get pods -A -o wide
	@echo ""
	@echo "$(BOLD)Helm releases$(RESET)"
	@helm list -A
	@echo ""
	@echo "$(BOLD)Resource usage (kubectl top)$(RESET)"
	@kubectl top nodes 2>/dev/null || echo "  (kubectl top nodes: metrics-server недоступен или нет данных)"
	@kubectl top pods -A 2>/dev/null || echo "  (kubectl top pods: metrics-server недоступен или нет данных)"

# Занято: metrics.k8s.io/nodes; доступно: sum(status.allocatable) по нодам; нужны metrics-server, jq
top-totals:
	@command -v jq >/dev/null 2>&1 || { echo "✗ требуется jq (apt install jq / brew install jq)"; exit 1; }
	@echo "$(BOLD)ENV=$(ENV)$(RESET) — CPU/память по кластеру (занято = Metrics API; доступно = sum allocatable по нодам)"
	@if [ -n "$$KUBECONFIG" ]; then echo "KUBECONFIG=$$KUBECONFIG"; fi
	@echo ""
	@TMP=$$(mktemp -d); \
	trap 'rm -rf "$$TMP"' EXIT; \
	kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes > $$TMP/metrics.json; \
	kubectl get nodes -o json > $$TMP/nodes.json; \
	jq -n -r --slurpfile metrics $$TMP/metrics.json --slurpfile nodes $$TMP/nodes.json \
	'def cpu_to_cores(s): if s == null then 0 elif (s|type) != "string" then 0 elif (s|endswith("n")) then (s|sub("n$$";"")|tonumber)/1000000000 elif (s|endswith("m")) then (s|sub("m$$";"")|tonumber)/1000 else 0 end; def mem_to_bytes(s): if s == null then 0 elif (s|type) != "string" then 0 elif (s|endswith("Ki")) then (s|sub("Ki$$";"")|tonumber)*1024 elif (s|endswith("Mi")) then (s|sub("Mi$$";"")|tonumber)*1048576 elif (s|endswith("Gi")) then (s|sub("Gi$$";"")|tonumber)*1073741824 else 0 end; def cpu_alloc_to_cores(s): if s == null then 0 elif (s|type) != "string" then 0 elif (s|endswith("m")) then (s|sub("m$$";"")|tonumber)/1000 else (s|tonumber) end; ($$metrics[0].items) as $$mi | ($$nodes[0].items) as $$ni | ([$$mi[].usage.cpu | cpu_to_cores(.)] | add) as $$uc | ([$$mi[].usage.memory | mem_to_bytes(.)] | add) as $$um | ([$$ni[].status.allocatable.cpu | cpu_alloc_to_cores(.)] | add) as $$ac | ([$$ni[].status.allocatable.memory | mem_to_bytes(.)] | add) as $$am | ($$am - $$um) as $$fm | ($$ac - $$uc) as $$fc | "CPU:  занято " + (($$uc * 1000 | round) / 1000 | tostring) + " / доступно " + (($$ac * 1000 | round) / 1000 | tostring) + " cores  (свободно " + (($$fc * 1000 | round) / 1000 | tostring) + ")\nMemory: занято " + (($$um / 1073741824 * 100 | round) / 100 | tostring) + " / доступно " + (($$am / 1073741824 * 100 | round) / 100 | tostring) + " GiB  (свободно " + (($$fm / 1073741824 * 100 | round) / 100 | tostring) + ")"'

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
	@if [ ! -f "environments/$(ENV).yaml" ]; then \
		printf '%s\n' \
			"registry: $(REGISTRY)" \
			"" \
			"postgres:" \
			"  namespace: postgres" \
			"  release: postgres" \
			"" \
			"kafka:" \
			"  namespace: kafka" \
			"  release: kafka" \
			"" \
			"redis:" \
			"  namespace: redis" \
			"  release: redis" \
			"" \
			"minio:" \
			"  namespace: minio" \
			"  release: minio" \
			"" \
			"rabbitmq:" \
			"  namespace: rabbitmq" \
			"  release: rabbitmq" \
			"" \
			"clickhouse:" \
			"  namespace: clickhouse" \
			"  release: clickhouse" \
			"" \
			"netdata:" \
			"  namespace: monitoring" \
			"  release: netdata" \
			> "environments/$(ENV).yaml"; \
		echo "✓ created environments/$(ENV).yaml"; \
	fi
	@for s in $(SERVICES); do \
		if [ -f "$$s/values-$(ENV).yaml" ]; then \
			continue; \
		elif [ "$(ENV)" = "prod" ] && [ -f "$$s/values-prod.yaml" ]; then \
			cp "$$s/values-prod.yaml" "$$s/values-$(ENV).yaml"; \
			echo "✓ created $$s/values-$(ENV).yaml (from values-prod.yaml)"; \
		elif [ -f "$$s/values-local.yaml" ]; then \
			cp "$$s/values-local.yaml" "$$s/values-$(ENV).yaml"; \
			echo "✓ created $$s/values-$(ENV).yaml (from values-local.yaml)"; \
		else \
			echo "⚠ $$s: missing values-local.yaml (skip)"; \
		fi; \
	done
	@echo "✓ Environment skeleton created: $(ENV)"

env-backup:
	@if [ -z "$(ENV)" ]; then echo "✗ ENV не задан"; exit 1; fi
	@command -v kubectl >/dev/null 2>&1 || { echo "✗ kubectl не найден"; exit 1; }
	@if [ ! -f "$(KUBECONFIG)" ]; then \
		echo "✗ Файл kubeconfig не найден: $(KUBECONFIG)"; \
		echo "  Сначала: make kubeconfig-fetch ENV=$(ENV) … или make kubeconfig-microk8s-local ENV=$(ENV)"; \
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

# microk8s nginx ingress: hostPort + TCP ConfigMap (skill: .cursor/skills/k8s-port-expose-microk8s)
k8s-port-expose-show:
	@$(MAKE) -C k8s-port-expose show ENV=$(ENV)

k8s-port-expose-patch:
	@$(MAKE) -C k8s-port-expose patch ENV=$(ENV) \
		LAYER="$(LAYER)" HOST_PORT="$(HOST_PORT)" BACKEND="$(BACKEND)" RM="$(RM)" \
		OP="$(OP)" CONTAINER_PORT="$(CONTAINER_PORT)" PORT_NAME="$(PORT_NAME)" PROTO="$(PROTO)" \
		INGRESS_NS="$(INGRESS_NS)" INGRESS_DS="$(INGRESS_DS)" INGRESS_TCP_CM="$(INGRESS_TCP_CM)" INGRESS_CONTAINER="$(INGRESS_CONTAINER)" \
		DRY_RUN="$(DRY_RUN)"

k8s-port-expose-apply:
	@$(MAKE) -C k8s-port-expose apply-config ENV=$(ENV) REPO_ROOT="$(REPO_ROOT)" \
		PORT_EXPOSE_CONFIG="$(PORT_EXPOSE_CONFIG)" \
		DRY_RUN="$(DRY_RUN)"

## =========================
## Backup / Restore wrappers (stateful services)
## =========================
# postgres-backup / postgres-restore — определены выше (вместе с recreate-prep).
# Каждая *-backup* / *-restore* цель — тонкая обёртка над per-service Makefile.
# Документация: postgres/BACKUP.md, redis/BACKUP.md, kafka/BACKUP.md, minio/BACKUP.md, clickhouse/BACKUP.md, rabbitmq/BACKUP.md.

redis-backup:
	@$(MAKE) -C redis backup ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"
redis-restore-acl:
	@$(MAKE) -C redis restore-acl ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)" BACKUP_FILE="$(BACKUP_FILE)" SKIP_CONFIRM="$(SKIP_CONFIRM)"

kafka-backup-meta:
	@$(MAKE) -C kafka backup-meta ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"
kafka-restore-meta-topics:
	@$(MAKE) -C kafka restore-meta-topics ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)" BACKUP_FILE="$(BACKUP_FILE)" SKIP_CONFIRM="$(SKIP_CONFIRM)"

minio-backup-meta:
	@$(MAKE) -C minio backup-meta ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"
minio-restore-meta:
	@$(MAKE) -C minio restore-meta ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)" BACKUP_FILE="$(BACKUP_FILE)" SKIP_CONFIRM="$(SKIP_CONFIRM)"

clickhouse-backup:
	@$(MAKE) -C clickhouse backup ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"
clickhouse-restore:
	@$(MAKE) -C clickhouse restore ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)" BACKUP_FILE="$(BACKUP_FILE)" SKIP_CONFIRM="$(SKIP_CONFIRM)"

rabbitmq-backup-defs:
	@$(MAKE) -C rabbitmq backup-defs ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)"
rabbitmq-restore-defs:
	@$(MAKE) -C rabbitmq restore-defs ENV="$(ENV)" REGISTRY="$(REGISTRY)" KUBECONFIG="$(KUBECONFIG)" BACKUP_FILE="$(BACKUP_FILE)" SKIP_CONFIRM="$(SKIP_CONFIRM)"

# backup-all: запустить все сервисные backup-цели подряд.
# Учитывает ENABLED_SERVICES / EXCLUDE_SERVICES (как helmfile / apps-apply).
# Не падает на первой ошибке: BACKUP_ALL_CONTINUE_ON_ERROR=1 (по умолчанию 1; для останова на ошибке задайте 0).
BACKUP_ALL_CONTINUE_ON_ERROR ?= 1
backup-all:
	@FAILED=0; \
	is_active() { svc=$$1; \
		if [ -n "$(ENABLED_SERVICES)" ]; then echo ",$(ENABLED_SERVICES)," | grep -qF ",$$svc," && return 0 || return 1; fi; \
		echo ",$(EXCLUDE_SERVICES)," | grep -qF ",$$svc," && return 1 || return 0; \
	}; \
	run_step() { \
		svc=$$1; tgt=$$2; \
		if ! is_active "$$svc"; then echo "  ↷ skip $$svc (не в активных сервисах)"; return 0; fi; \
		echo ""; echo "=== $$svc: $$tgt ==="; \
		if $(MAKE) "$$tgt" ENV="$(ENV)"; then return 0; fi; \
		FAILED=$$((FAILED+1)); \
		if [ "$(BACKUP_ALL_CONTINUE_ON_ERROR)" != "1" ]; then echo "✗ Останов на ошибке (BACKUP_ALL_CONTINUE_ON_ERROR=0)"; exit 1; fi; \
		echo "  ⚠ Шаг $$svc/$$tgt упал; продолжаем (BACKUP_ALL_CONTINUE_ON_ERROR=1)"; \
	}; \
	run_step postgres   postgres-backup; \
	run_step redis      redis-backup; \
	run_step kafka      kafka-backup-meta; \
	run_step minio      minio-backup-meta; \
	run_step clickhouse clickhouse-backup; \
	run_step rabbitmq   rabbitmq-backup-defs; \
	echo ""; \
	if [ $$FAILED -gt 0 ]; then \
		echo "⚠ backup-all завершён с ошибками: $$FAILED шаг(ов)"; \
		exit 1; \
	else \
		echo "✓ backup-all: все шаги успешны"; \
	fi
