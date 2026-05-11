# Используется bash (не dash) — recipe полагаются на read -p и set -o pipefail.
SHELL := /bin/bash

.PHONY: help \
	images-verify images-pull images-tag images-push images-sync images-save images-load images-sync-from-files images-clean images-clean-files \
	install upgrade uninstall status logs shell app-create app-show-creds app-drop app-verify \
	backup restore list-backups \
	check-registry check-updates

# Локальный registry MicroK8s
REGISTRY ?= localhost:32000

# Helm release defaults
NAMESPACE ?= clickhouse
RELEASE ?= clickhouse
CHART_PATH ?= clickhouse
ENV ?= local
VALUES_FILE ?= values-$(ENV).yaml

INFRA_ROOT ?= $(abspath $(CURDIR)/..)
APPS_REGISTRY ?= $(INFRA_ROOT)/apps/registry.yaml

# KUBECONFIG: при прямом запуске из каталога сервиса берём из корня репо
# (k8s/config/<ENV>), чтобы kubectl не уходил на ~/.kube/config. Корневой
# Makefile при $(MAKE) -C ... KUBECONFIG=... переопределяет это значение.
KUBECONFIG ?= $(INFRA_ROOT)/k8s/config/$(ENV)
export KUBECONFIG

# Image tags pinned from chart values.yaml
CLICKHOUSE_TAG ?= 25.7.5-debian-12-r0
CLICKHOUSE_KEEPER_TAG ?= 25.7.5-debian-12-r0
OS_SHELL_TAG ?= 12-debian-12-r51

# Source tags (can override)
CLICKHOUSE_SRC_TAG ?= $(CLICKHOUSE_TAG)
CLICKHOUSE_KEEPER_SRC_TAG ?= $(CLICKHOUSE_KEEPER_TAG)
OS_SHELL_SRC_TAG ?= $(OS_SHELL_TAG)

# Source images (только docker.io/bitnamilegacy)
CLICKHOUSE_IMAGE_SRC := docker.io/bitnamilegacy/clickhouse:$(CLICKHOUSE_SRC_TAG)
CLICKHOUSE_KEEPER_IMAGE_SRC := docker.io/bitnamilegacy/clickhouse-keeper:$(CLICKHOUSE_KEEPER_SRC_TAG)
OS_SHELL_IMAGE_SRC := docker.io/bitnamilegacy/os-shell:$(OS_SHELL_SRC_TAG)

# Local registry tags (repository as in chart)
CLICKHOUSE_IMAGE_LOCAL := $(REGISTRY)/bitnami/clickhouse:$(CLICKHOUSE_TAG)
CLICKHOUSE_KEEPER_IMAGE_LOCAL := $(REGISTRY)/bitnami/clickhouse-keeper:$(CLICKHOUSE_KEEPER_TAG)
OS_SHELL_IMAGE_LOCAL := $(REGISTRY)/bitnami/os-shell:$(OS_SHELL_TAG)

IMAGES_SRC := $(CLICKHOUSE_IMAGE_SRC) $(CLICKHOUSE_KEEPER_IMAGE_SRC) $(OS_SHELL_IMAGE_SRC)
IMAGES_LOCAL := $(CLICKHOUSE_IMAGE_LOCAL) $(CLICKHOUSE_KEEPER_IMAGE_LOCAL) $(OS_SHELL_IMAGE_LOCAL)

IMAGES_DIR ?= images

help:
	@echo "ClickHouse"
	@echo ""
	@echo "Helm:"
	@echo "  make install            - Установить ClickHouse в namespace $(NAMESPACE)"
	@echo "  make upgrade            - Обновить ClickHouse"
	@echo "  make uninstall          - Удалить ClickHouse (⚠ удалит release)"
	@echo "  make status             - Показать статус ClickHouse"
	@echo ""
	@echo "Images:"
	@echo "  make images-verify       - проверить доступность тегов в docker.io/bitnamilegacy"
	@echo "  make images-save         - Скачать и сохранить tar"
	@echo "  make images-sync-from-files - docker load + tag + push в $(REGISTRY)"
	@echo ""
	@echo "App accounts:"
	@echo "  make app-create APP=myapp [APP_NS=myapp] [DB=myapp] [APP_USER=app_myapp]"
	@echo "  make app-show-creds APP=myapp [APP_NS=myapp] — креды из Secret приложения (APP-clickhouse)"
	@echo "  make app-drop APP=myapp — DROP DATABASE, DROP USER и Secret (⚠ y/N; SKIP_CONFIRM=1)"
	@echo "  make app-verify APP=myapp [APP_NS=...] — smoke: SELECT 1 в БД приложения под APP-кредами"
	@echo ""
	@echo "Backup / Restore (schemas + users; данные таблиц — отдельно, см. clickhouse/BACKUP.md):"
	@echo "  make backup                    - tar.gz: schemas + users + grants всех БД (кроме системных)"
	@echo "  make restore BACKUP_FILE=...   - применить schemas + users + grants (⚠ y/N; SKIP_CONFIRM=1)"
	@echo "  make list-backups              - список бэкапов"

check-registry:
	@echo "Проверка MicroK8s registry..."
	@curl -fsS http://$(REGISTRY)/v2/ >/dev/null 2>&1 && \
		echo "✓ Registry доступен: http://$(REGISTRY)/v2/" || \
		(echo "✗ Registry недоступен. Убедитесь, что выполнен: microk8s enable registry" && exit 1)

## =========================
## App accounts (per-app isolation)
## =========================

# Usage: make app-create APP=myapp — пароль только из merged (clickhouse.password).
app-create:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-create APP=myapp)"; exit 1; fi
	@{ set -euo pipefail; \
	INF="$(INFRA_ROOT)"; REG="$(APPS_REGISTRY)"; \
	MG="$${APPS_MERGED_FILE:-}"; CLEAN_MG=0; \
	if [ -z "$$MG" ]; then MG=$$(mktemp); CLEAN_MG=1; "$$INF/scripts/apps-merge-config.sh" "$$REG" "$$INF" >"$$MG"; fi; \
	trap 'if [ "$$CLEAN_MG" = 1 ]; then rm -f "$$MG"; fi' EXIT; \
	APP_NS=$${APP_NS:-$(APP)}; \
	DB=$${DB:-$(APP)}; \
	APP_USER=$${APP_USER:-app_$(APP)}; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-clickhouse}; \
	ADMIN_USER=$${ADMIN_USER:-admin}; \
	PW_RAW=$$("$$INF/scripts/app-config-get.sh" "$$MG" "$(APP)" clickhouse.password || true); \
	if [ -z "$$PW_RAW" ] || [ "$$PW_RAW" = "null" ]; then echo "✗ Для приложения \"$(APP)\" нет clickhouse.password в merged"; exit 1; fi; \
	APP_PASSWORD="$$PW_RAW"; \
	# Экранируем пароль для SQL single-quoted литерала: \\ → \\\\ (сначала!), '\'' → '\'''\''. \
	# Иначе пароль с одиночной кавычкой / backslash сломает CREATE USER ... BY '...'. \
	APP_PASSWORD_SQL=$$(printf '%s' "$$APP_PASSWORD" | sed -e 's/\\/\\\\/g' -e "s/'/''/g"); \
	ADMIN_PASSWORD=$$(kubectl get secret -n $(NAMESPACE) $(RELEASE) -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d); \
	if [ -z "$$ADMIN_PASSWORD" ]; then echo "✗ Не удалось получить admin-password из секрета"; exit 1; fi; \
	CH_HOST="$(RELEASE).$(NAMESPACE).svc.cluster.local"; \
	CH_PORT=9000; \
	CH_HTTP_PORT=8123; \
	echo "Creating/updating ClickHouse user $$APP_USER and DB $$DB"; \
	: "ALTER USER ... IDENTIFIED ... после CREATE IF NOT EXISTS делает recipe идемпотентным:"; \
	: "при повторном app-create с новым паролем (например, после ротации в apps/conf/)"; \
	: "пользователь действительно получает новый пароль, а не остаётся со старым."; \
	kubectl run clickhouse-admin-$$(date +%s) \
		--restart='Never' \
		--image=$(CLICKHOUSE_IMAGE_LOCAL) \
		--namespace=$(NAMESPACE) \
		--rm -i \
		--command -- sh -ec "\
			clickhouse-client --host $$CH_HOST --port $$CH_PORT \
			  --user \"$$ADMIN_USER\" --password \"$$ADMIN_PASSWORD\" \
			  --multiquery --query \"CREATE DATABASE IF NOT EXISTS \\\"$$DB\\\"; \
CREATE USER IF NOT EXISTS \\\"$$APP_USER\\\" IDENTIFIED WITH sha256_password BY '$$APP_PASSWORD_SQL'; \
ALTER USER \\\"$$APP_USER\\\" IDENTIFIED WITH sha256_password BY '$$APP_PASSWORD_SQL'; \
GRANT ALL ON \\\"$$DB\\\".* TO \\\"$$APP_USER\\\";\" \
		"; \
	echo "Creating Secret $$APP_SECRET_NAME in namespace $$APP_NS"; \
	kubectl create namespace "$$APP_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; \
	kubectl delete secret "$$APP_SECRET_NAME" -n "$$APP_NS" --ignore-not-found >/dev/null; \
	kubectl create secret generic "$$APP_SECRET_NAME" -n "$$APP_NS" \
		--from-literal=CLICKHOUSE_HOST="$$CH_HOST" \
		--from-literal=CLICKHOUSE_PORT="$$CH_PORT" \
		--from-literal=CLICKHOUSE_HTTP_PORT="$$CH_HTTP_PORT" \
		--from-literal=CLICKHOUSE_DB="$$DB" \
		--from-literal=CLICKHOUSE_USER="$$APP_USER" \
		--from-literal=CLICKHOUSE_PASSWORD="$$APP_PASSWORD" \
		>/dev/null; \
	printf '%s\n' \
		'clickhouse:' \
		"  password: \"$$APP_PASSWORD\"" \
		"  username: \"$$APP_USER\"" \
		"  database: \"$$DB\"" \
		"  host: \"$$CH_HOST\"" \
		"  native_port: $$CH_PORT" \
		"  http_port: $$CH_HTTP_PORT" \
	| "$$INF/scripts/app-conf-set.sh" "$$INF" "$(APP)"; \
	echo "✓ Done (Secret: $$APP_NS/$$APP_SECRET_NAME)"; \
	}

# Usage: make app-show-creds APP=myapp [APP_NS=myapp]
app-show-creds:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-show-creds APP=myapp)"; exit 1; fi
	@APP_NS=$${APP_NS:-$(APP)}; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-clickhouse}; \
	if ! kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" >/dev/null 2>&1; then \
		echo "✗ Secret $$APP_SECRET_NAME не найден в namespace $$APP_NS"; exit 1; \
	fi; \
	echo "Secret: $$APP_NS/$$APP_SECRET_NAME"; \
	echo "---"; \
	for k in CLICKHOUSE_HOST CLICKHOUSE_PORT CLICKHOUSE_HTTP_PORT CLICKHOUSE_DB CLICKHOUSE_USER CLICKHOUSE_PASSWORD; do \
		v=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath="{.data.$$k}" 2>/dev/null | base64 -d); \
		echo "$$k=$$v"; \
	done

# Usage: make app-verify APP=myapp — smoke: SELECT 1 в БД приложения под APP-кредами.
app-verify:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-verify APP=myapp)"; exit 1; fi
	@APP_NS=$${APP_NS:-$(APP)}; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-clickhouse}; \
	if ! kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" >/dev/null 2>&1; then \
		echo "✗ Secret $$APP_SECRET_NAME не найден в namespace $$APP_NS"; exit 1; \
	fi; \
	APP_USER=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.CLICKHOUSE_USER}' | base64 -d); \
	APP_PASSWORD=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.CLICKHOUSE_PASSWORD}' | base64 -d); \
	APP_DB=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.CLICKHOUSE_DB}' | base64 -d); \
	CH_HOST=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.CLICKHOUSE_HOST}' | base64 -d); \
	CH_HOST=$${CH_HOST:-$(RELEASE).$(NAMESPACE).svc.cluster.local}; \
	if [ -z "$$APP_USER" ] || [ -z "$$APP_PASSWORD" ]; then echo "✗ В Secret отсутствуют CLICKHOUSE_USER/CLICKHOUSE_PASSWORD"; exit 1; fi; \
	echo "Проверка $$APP_USER@$$APP_DB ($$CH_HOST)..."; \
	kubectl run clickhouse-verify-$$(date +%s) \
		--restart='Never' \
		--image=$(CLICKHOUSE_IMAGE_LOCAL) \
		--namespace=$(NAMESPACE) \
		--rm -i --quiet \
		--env="CLICKHOUSE_HOST=$$CH_HOST" --env="CLICKHOUSE_PORT=9000" \
		--env="CLICKHOUSE_USER=$$APP_USER" --env="CLICKHOUSE_PASSWORD=$$APP_PASSWORD" \
		--env="CLICKHOUSE_DATABASE=$${APP_DB:-default}" \
		--env="APP_DB=$$APP_DB" \
		--command -- sh -ec '\
			OUT=$$(clickhouse-client --query "SELECT 1" 2>&1) || { echo "✗ SELECT 1 не удался: $$OUT"; exit 1; }; \
			[ "$$OUT" = "1" ] && echo "✓ SELECT 1 = $$OUT (БД $$APP_DB доступна)" || { echo "✗ Unexpected output: $$OUT"; exit 1; }'

# Usage: make app-drop APP=myapp [APP_NS=myapp] [DB=myapp] [APP_USER=app_myapp] [ADMIN_USER=admin] [SKIP_CONFIRM=1]
app-drop:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-drop APP=myapp)"; exit 1; fi
	@APP_NS=$${APP_NS:-$(APP)}; \
	DB=$${DB:-$(APP)}; \
	APP_USER=$${APP_USER:-app_$(APP)}; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-clickhouse}; \
	ADMIN_USER=$${ADMIN_USER:-admin}; \
	if [ "$(SKIP_CONFIRM)" != "1" ]; then \
		echo "⚠ ВНИМАНИЕ: Будут удалены БД \"$$DB\", пользователь ClickHouse \"$$APP_USER\" и Secret \"$$APP_NS/$$APP_SECRET_NAME\"."; \
		read -p "Вы уверены? (y/N): " confirm; \
		if [ "$$confirm" != "y" ] && [ "$$confirm" != "Y" ]; then echo "Отменено."; exit 0; fi; \
	fi; \
	ADMIN_PASSWORD=$$(kubectl get secret -n $(NAMESPACE) $(RELEASE) -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d); \
	if [ -z "$$ADMIN_PASSWORD" ]; then echo "✗ Не удалось получить admin-password из секрета $(RELEASE) в namespace $(NAMESPACE)"; exit 1; fi; \
	CH_HOST="$(RELEASE).$(NAMESPACE).svc.cluster.local"; \
	CH_PORT=9000; \
	echo "Dropping database $$DB and user $$APP_USER..."; \
	kubectl run clickhouse-drop-$$(date +%s) \
		--restart='Never' \
		--image=$(CLICKHOUSE_IMAGE_LOCAL) \
		--namespace=$(NAMESPACE) \
		--rm -i \
		--command -- sh -ec "\
			clickhouse-client --host $$CH_HOST --port $$CH_PORT \
			  --user \"$$ADMIN_USER\" --password \"$$ADMIN_PASSWORD\" \
			  --multiquery --query \"DROP DATABASE IF EXISTS \\\"$$DB\\\"; DROP USER IF EXISTS \\\"$$APP_USER\\\";\" \
		"; \
	echo "Deleting Secret $$APP_SECRET_NAME in namespace $$APP_NS..."; \
	kubectl delete secret "$$APP_SECRET_NAME" -n "$$APP_NS" --ignore-not-found; \
	"$(INFRA_ROOT)/scripts/app-conf-clear.sh" "$(INFRA_ROOT)" "$(APP)" clickhouse || true; \
	echo "✓ БД $$DB, пользователь $$APP_USER и Secret $$APP_NS/$$APP_SECRET_NAME удалены"

# Usage: make app-backup APP=myapp ENV=local [DB=myapp]
# Создаёт apps/backups/$(ENV)/$(APP)/clickhouse/$(APP)-db-<TS>.tar.gz: схемы + данные
# всех таблиц БД <DB> (default: <APP>) в Native-формате. Views/MaterializedViews пропускаются.
app-backup:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-backup APP=myapp ENV=$(ENV))"; exit 1; fi
	@set -eo pipefail; \
	DB=$${DB:-$(APP)}; \
	OUT_DIR="$(INFRA_ROOT)/apps/backups/$(ENV)/$(APP)/clickhouse"; \
	install -d -m 700 "$$OUT_DIR"; \
	TS=$$(date +%Y%m%d-%H%M%S)-$$$$; \
	OUT="$$OUT_DIR/$(APP)-db-$$TS.tar.gz"; \
	echo "Создание бэкапа БД ClickHouse $$DB в $$OUT..."; \
	ADMIN_PASSWORD=$$(kubectl get secret -n $(NAMESPACE) $(RELEASE) -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d); \
	if [ -z "$$ADMIN_PASSWORD" ]; then echo "✗ Не удалось получить admin-password из секрета $(RELEASE)"; exit 1; fi; \
	CH_HOST="$(RELEASE).$(NAMESPACE).svc.cluster.local"; \
	HELPER=clickhouse-app-backup-$$TS; \
	echo "  Старт helper-pod $$HELPER..."; \
	kubectl run "$$HELPER" --restart=Never --image=$(CLICKHOUSE_IMAGE_LOCAL) --namespace=$(NAMESPACE) \
		--overrides='{"spec":{"containers":[{"name":"'$$HELPER'","image":"$(CLICKHOUSE_IMAGE_LOCAL)","command":["sleep","1800"]}]}}' \
		>/dev/null; \
	trap 'kubectl delete pod "$$HELPER" -n $(NAMESPACE) --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT INT TERM; \
	kubectl wait --namespace $(NAMESPACE) --for=condition=Ready pod/"$$HELPER" --timeout=120s >/dev/null; \
	echo "  Сбор schemas + data для БД $$DB..."; \
	kubectl exec "$$HELPER" -n $(NAMESPACE) -- env \
			CLICKHOUSE_HOST="$$CH_HOST" CLICKHOUSE_PORT=9000 \
			CLICKHOUSE_USER=admin CLICKHOUSE_PASSWORD="$$ADMIN_PASSWORD" \
			DB="$$DB" \
			bash -ec ' \
		set -eo pipefail; \
		EXISTS=$$(clickhouse-client --query "SELECT count() FROM system.databases WHERE name = '"'"'$$DB'"'"'"); \
		[ "$$EXISTS" = "1" ] || { echo "Database $$DB does not exist on server" >&2; exit 1; }; \
		mkdir -p /tmp/dump/schemas /tmp/dump/data; \
		cd /tmp/dump; \
		: "CREATE DATABASE для восстановления"; \
		clickhouse-client --query "SHOW CREATE DATABASE \"$$DB\"" | sed -e "s/$$/;/" > db-create.sql; \
		: "Список таблиц (без View/MaterializedView/LiveView/WindowView)"; \
		clickhouse-client --query "SELECT name FROM system.tables WHERE database = '"'"'$$DB'"'"' AND engine NOT IN ('"'"'View'"'"','"'"'MaterializedView'"'"','"'"'LiveView'"'"','"'"'WindowView'"'"')" > tables.list; \
		while IFS= read -r tbl; do \
			[ -z "$$tbl" ] && continue; \
			echo "    -> $$tbl (schema)"; \
			clickhouse-client --query "SHOW CREATE TABLE \"$$DB\".\"$$tbl\"" | sed -e "s/$$/;/" > "schemas/$$tbl.sql"; \
			echo "    -> $$tbl (data, Native)"; \
			clickhouse-client --query "SELECT * FROM \"$$DB\".\"$$tbl\" FORMAT Native" > "data/$$tbl.native"; \
		done < tables.list; \
		{ echo "ClickHouse per-app backup"; \
			echo "DB=$$DB"; \
			date; \
			clickhouse-client --query "SELECT version()"; } > info.txt 2>&1 || true; \
		tar -czf /tmp/app-backup.tar.gz -C /tmp/dump .; \
	'; \
	kubectl exec "$$HELPER" -n $(NAMESPACE) -- cat /tmp/app-backup.tar.gz > "$$OUT"; \
	[ -s "$$OUT" ] || { echo "✗ Архив $$OUT пуст или не скопирован"; exit 1; }; \
	SIZE=$$(du -h --apparent-size "$$OUT" | cut -f1); \
	echo "✓ Бэкап БД $$DB создан: $$OUT ($$SIZE)"; \
	echo "=> $$OUT"

# Usage: make app-restore APP=myapp ENV=local BACKUP_FILE=<path> [DB=myapp] [SKIP_CONFIRM=1]
# Восстанавливает БД приложения из архива app-backup. ⚠ DROP DATABASE + CREATE заново.
# Native format: версии ClickHouse SRC и DST должны совпадать по мажору (см. clickhouse/BACKUP.md).
app-restore:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан"; exit 1; fi
	@if [ -z "$(BACKUP_FILE)" ]; then \
		echo "✗ Укажите BACKUP_FILE=apps/backups/$(ENV)/$(APP)/clickhouse/$(APP)-db-YYYYMMDD-HHMMSS.tar.gz"; \
		exit 1; \
	fi
	@if [ ! -f "$(BACKUP_FILE)" ]; then echo "✗ Файл $(BACKUP_FILE) не найден"; exit 1; fi
	@DB=$${DB:-$(APP)}; \
	if [ "$(SKIP_CONFIRM)" != "1" ]; then \
		echo "⚠ ВНИМАНИЕ: Будет DROP DATABASE \"$$DB\" и пересоздана из $(BACKUP_FILE)."; \
		echo "  Существующие данные БД $$DB безвозвратно потеряны."; \
		read -p "Вы уверены? (yes/no): " confirm && [ "$$confirm" = "yes" ] || { echo "Отменено"; exit 1; }; \
	fi
	@set -eo pipefail; \
	DB=$${DB:-$(APP)}; \
	TS=$$(date +%Y%m%d-%H%M%S)-$$$$; \
	ADMIN_PASSWORD=$$(kubectl get secret -n $(NAMESPACE) $(RELEASE) -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d); \
	if [ -z "$$ADMIN_PASSWORD" ]; then echo "✗ Не удалось получить admin-password"; exit 1; fi; \
	CH_HOST="$(RELEASE).$(NAMESPACE).svc.cluster.local"; \
	HELPER=clickhouse-app-restore-$$TS; \
	kubectl run "$$HELPER" --restart=Never --image=$(CLICKHOUSE_IMAGE_LOCAL) --namespace=$(NAMESPACE) \
		--overrides='{"spec":{"containers":[{"name":"'$$HELPER'","image":"$(CLICKHOUSE_IMAGE_LOCAL)","command":["sleep","1800"]}]}}' \
		>/dev/null; \
	trap 'kubectl delete pod "$$HELPER" -n $(NAMESPACE) --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT INT TERM; \
	kubectl wait --namespace $(NAMESPACE) --for=condition=Ready pod/"$$HELPER" --timeout=120s >/dev/null; \
	kubectl cp "$(BACKUP_FILE)" "$(NAMESPACE)/$$HELPER:/tmp/backup.tar.gz" >/dev/null; \
	kubectl exec "$$HELPER" -n $(NAMESPACE) -- env \
			CLICKHOUSE_HOST="$$CH_HOST" CLICKHOUSE_PORT=9000 \
			CLICKHOUSE_USER=admin CLICKHOUSE_PASSWORD="$$ADMIN_PASSWORD" \
			DB="$$DB" \
			bash -ec ' \
		set -eo pipefail; \
		mkdir -p /tmp/dump && tar -xzf /tmp/backup.tar.gz -C /tmp/dump; \
		cd /tmp/dump; \
		[ -f tables.list ] || { echo "✗ tables.list отсутствует — это не valid app-backup ClickHouse"; exit 1; }; \
		echo "  DROP DATABASE \"$$DB\" + CREATE..."; \
		clickhouse-client --query "DROP DATABASE IF EXISTS \"$$DB\" SYNC"; \
		clickhouse-client --multiquery < db-create.sql; \
		echo "  Применение schemas..."; \
		while IFS= read -r tbl; do \
			[ -z "$$tbl" ] && continue; \
			echo "    schema: $$tbl"; \
			clickhouse-client --multiquery < "schemas/$$tbl.sql"; \
		done < tables.list; \
		echo "  Импорт данных (Native)..."; \
		while IFS= read -r tbl; do \
			[ -z "$$tbl" ] && continue; \
			[ -s "data/$$tbl.native" ] || { echo "    data: $$tbl (пустая, skip)"; continue; }; \
			echo "    data: $$tbl"; \
			clickhouse-client --query "INSERT INTO \"$$DB\".\"$$tbl\" FORMAT Native" < "data/$$tbl.native"; \
		done < tables.list; \
	'; \
	echo "✓ БД $$DB восстановлена из $(BACKUP_FILE)"

images-verify:
	@# Проверяем именно SRC-теги ($$(CLICKHOUSE_SRC_TAG) и т.п.) — то, что реально
	@# pull-ится. Сейчас они равны *_TAG (Bitnami ещё не выпилил mutable-теги для
	@# clickhouse), но на postgres/redis/kafka уже sha256-* — устойчивее проверять
	@# именно то, что подаётся в `docker pull` через $(IMAGES_SRC).
	@echo "Проверка доступности SRC-тегов в docker.io/bitnamilegacy..."
	@command -v docker >/dev/null 2>&1 || { echo "✗ docker не установлен"; exit 1; }
	@FAIL=0; \
	for img in $(IMAGES_SRC); do \
		echo "  - $$img"; \
		if docker manifest inspect "$$img" >/dev/null 2>&1; then \
			echo "    ✓ OK"; \
		else \
			echo "    ✗ NOT FOUND"; \
			FAIL=1; \
		fi; \
	done; \
	if [ $$FAIL -ne 0 ]; then \
		echo ""; \
		echo "✗ Некоторые SRC-теги в bitnamilegacy недоступны."; \
		echo "  Подсказка: проверьте/обновите *_SRC_TAG в Makefile (см. https://hub.docker.com/u/bitnamilegacy)."; \
		exit 1; \
	fi; \
	echo "✓ Все SRC-теги доступны в bitnamilegacy"

check-updates: ## Проверить наличие новых версий чарта и образов
	@echo "Проверка обновлений для ClickHouse..."
	@echo ""
	@CURRENT_CHART=$$(grep '^version:' $(CHART_PATH)/Chart.yaml | awk '{print $$2}'); \
	CURRENT_APP=$$(grep '^appVersion:' $(CHART_PATH)/Chart.yaml | awk '{print $$2}'); \
	echo "Текущая версия чарта: $$CURRENT_CHART (appVersion: $$CURRENT_APP)"; \
	echo "Текущие теги образов: clickhouse:$(CLICKHOUSE_TAG), clickhouse-keeper:$(CLICKHOUSE_KEEPER_TAG), os-shell:$(OS_SHELL_TAG)"; \
	echo ""; \
	echo "Проверка доступных версий чарта..."; \
	if command -v helm >/dev/null 2>&1; then \
		if ! helm repo list 2>/dev/null | grep -q bitnami; then \
			echo "  Добавляю репозиторий bitnami..."; \
			helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true; \
			helm repo update >/dev/null 2>&1 || true; \
		fi; \
		echo "  Поиск последней версии чарта..."; \
		LATEST_CHART=$$(helm search repo bitnami/clickhouse --versions --output json 2>/dev/null | jq -r '.[0].version' 2>/dev/null || helm search repo bitnami/clickhouse --versions 2>/dev/null | head -2 | tail -1 | awk '{print $$2}' || echo ""); \
		if [ -n "$$LATEST_CHART" ] && [ "$$LATEST_CHART" != "$$CURRENT_CHART" ]; then \
			echo "  ⚠ Доступна новая версия чарта: $$LATEST_CHART"; \
			echo "  Для проверки образов новой версии выполните:"; \
			echo "    helm show chart bitnami/clickhouse --version $$LATEST_CHART | grep -A 10 '^annotations:'"; \
		elif [ -n "$$LATEST_CHART" ]; then \
			echo "  ✓ Используется последняя версия чарта: $$CURRENT_CHART"; \
		else \
			echo "  ⚠ Не удалось получить версию чарта"; \
		fi; \
	else \
		echo "  ⚠ helm не установлен, проверка версий чарта пропущена"; \
		echo "  Альтернатива: проверьте https://github.com/bitnami/charts/tree/main/bitnami/clickhouse"; \
	fi; \
	echo ""; \
	echo "Примечание: После обновления чарта проверьте теги образов в Chart.yaml новой версии"

install:
	@kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	@# values-*.yaml ссылаются на auth.existingSecret: $(RELEASE) (ключ admin-password).
	@# При первом разворачивании Secret отсутствует — генерируем admin-password.
	@# В корневой цели `make up` логика та же.
	@if ! kubectl get secret -n $(NAMESPACE) $(RELEASE) >/dev/null 2>&1; then \
		echo "Secret $(NAMESPACE)/$(RELEASE) отсутствует — создаю с новым admin-password..."; \
		command -v openssl >/dev/null 2>&1 || { echo "✗ openssl не найден (нужен для генерации пароля)"; exit 1; }; \
		ADMIN_PASSWORD=$$(openssl rand -hex 16); \
		kubectl create secret generic $(RELEASE) -n $(NAMESPACE) \
			--from-literal=admin-password="$$ADMIN_PASSWORD" >/dev/null; \
		echo "✓ Secret $(NAMESPACE)/$(RELEASE) создан (admin-password)"; \
	fi
	@if [ -f $(VALUES_FILE) ]; then \
		echo "Использование файла $(VALUES_FILE)"; \
		helm install $(RELEASE) $(CHART_PATH) --namespace $(NAMESPACE) -f $(VALUES_FILE); \
	else \
		echo "Файл $(VALUES_FILE) не найден"; exit 1; \
	fi

upgrade:
	@if [ -f $(VALUES_FILE) ]; then \
		echo "Использование файла $(VALUES_FILE)"; \
		helm upgrade $(RELEASE) $(CHART_PATH) --namespace $(NAMESPACE) -f $(VALUES_FILE); \
	else \
		echo "Файл $(VALUES_FILE) не найден"; exit 1; \
	fi

uninstall:
	@echo "⚠ ВНИМАНИЕ: Это удалит Helm release $(RELEASE)."
	@echo "  Останутся в namespace $(NAMESPACE):"
	@echo "    - PVC с данными ClickHouse (schemas, объекты таблиц);"
	@echo "    - Secret $(RELEASE) (admin-password — нужен для будущего install,"
	@echo "      иначе создастся новый, и пользователи приложений из старого PV"
	@echo "      могут оказаться рассинхронизированы по паролям);"
	@echo "    - Secrets <APP>-clickhouse в namespace приложений (с APP-кредами)."
	@echo "  Полная зачистка (включая данные) — отдельными командами:"
	@echo "    kubectl delete pvc -n $(NAMESPACE) -l app.kubernetes.io/name=clickhouse"
	@echo "    kubectl delete secret $(RELEASE) -n $(NAMESPACE)"
	@read -p "Вы уверены? (y/N): " confirm && \
		if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
			helm uninstall $(RELEASE) --namespace $(NAMESPACE) || echo "Helm release не найден"; \
		else \
			echo "Отменено."; \
			exit 0; \
		fi

status:
	@helm status $(RELEASE) --namespace $(NAMESPACE) 2>/dev/null || echo "Helm release не найден"
	@kubectl get pods,svc,pvc -n $(NAMESPACE) -o wide 2>/dev/null || true

logs:
	@POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/name=clickhouse -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then \
		echo "Поды ClickHouse не найдены"; \
	else \
		echo "Логи пода: $$POD"; \
		kubectl logs -f $$POD -n $(NAMESPACE); \
	fi

shell:
	@POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/name=clickhouse -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then \
		echo "Поды ClickHouse не найдены"; \
		exit 1; \
	else \
		echo "Подключение к поду: $$POD"; \
		kubectl exec -it $$POD -n $(NAMESPACE) -- bash || kubectl exec -it $$POD -n $(NAMESPACE) -- sh; \
	fi

images-pull:
	@echo "Загрузка образов из docker.io/bitnamilegacy..."
	@docker pull $(CLICKHOUSE_IMAGE_SRC)
	@docker pull $(CLICKHOUSE_KEEPER_IMAGE_SRC)
	@docker pull $(OS_SHELL_IMAGE_SRC)
	@echo "✓ Все образы загружены"

images-tag: images-pull
	@docker tag $(CLICKHOUSE_IMAGE_SRC) $(CLICKHOUSE_IMAGE_LOCAL)
	@docker tag $(CLICKHOUSE_KEEPER_IMAGE_SRC) $(CLICKHOUSE_KEEPER_IMAGE_LOCAL)
	@docker tag $(OS_SHELL_IMAGE_SRC) $(OS_SHELL_IMAGE_LOCAL)

images-push: check-registry images-tag
	@docker push $(CLICKHOUSE_IMAGE_LOCAL)
	@docker push $(CLICKHOUSE_KEEPER_IMAGE_LOCAL)
	@docker push $(OS_SHELL_IMAGE_LOCAL)

images-sync: images-push

images-save: images-tag
	@mkdir -p $(IMAGES_DIR)
	@docker save $(CLICKHOUSE_IMAGE_LOCAL) -o $(IMAGES_DIR)/clickhouse-$(CLICKHOUSE_TAG).tar
	@docker save $(CLICKHOUSE_KEEPER_IMAGE_LOCAL) -o $(IMAGES_DIR)/clickhouse-keeper-$(CLICKHOUSE_KEEPER_TAG).tar
	@docker save $(OS_SHELL_IMAGE_LOCAL) -o $(IMAGES_DIR)/os-shell-$(OS_SHELL_TAG).tar

images-load:
	@if [ ! -d "$(IMAGES_DIR)" ]; then echo "✗ Директория $(IMAGES_DIR) не найдена"; exit 1; fi
	@for file in $(IMAGES_DIR)/*.tar; do \
		if [ -f "$$file" ]; then docker load -i $$file; fi; \
	done

images-sync-from-files: check-registry images-load
	@$(MAKE) images-tag
	@$(MAKE) images-push

images-clean:
	-@docker rmi $(IMAGES_LOCAL) 2>/dev/null || true
	-@docker rmi $(IMAGES_SRC) 2>/dev/null || true

images-clean-files:
	@if [ -d "$(IMAGES_DIR)" ]; then rm -f $(IMAGES_DIR)/*.tar 2>/dev/null || true; fi

## =========================
## Backup / Restore (schemas + users + grants)
## =========================
BACKUP_DIR ?= backups/$(ENV)

# Schema-only backup: для каждой пользовательской БД сохраняет CREATE DATABASE + CREATE TABLE
# для всех таблиц. Дополнительно — CREATE USER + GRANT для каждого non-default пользователя.
# Данные таблиц НЕ бэкапятся (см. clickhouse/BACKUP.md, варианты BACKUP TO Disk / SELECT INTO OUTFILE).
backup:
	@mkdir -p $(BACKUP_DIR)
	@set -eo pipefail; \
	TS=$$(date +%Y%m%d-%H%M%S)-$$$$; \
	OUT="$(BACKUP_DIR)/clickhouse-backup-$$TS.tar.gz"; \
	echo "Создание schema-бэкапа ClickHouse в $$OUT..."; \
	ADMIN_PASSWORD=$$(kubectl get secret -n $(NAMESPACE) $(RELEASE) -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d); \
	if [ -z "$$ADMIN_PASSWORD" ]; then echo "✗ Не удалось получить admin-password из секрета $(RELEASE)"; exit 1; fi; \
	CH_HOST="$(RELEASE).$(NAMESPACE).svc.cluster.local"; \
	HELPER=clickhouse-backup-$$TS; \
	echo "  Старт helper-pod $$HELPER..."; \
	kubectl run "$$HELPER" --restart=Never --image=$(CLICKHOUSE_IMAGE_LOCAL) --namespace=$(NAMESPACE) \
		--overrides='{"spec":{"containers":[{"name":"'$$HELPER'","image":"$(CLICKHOUSE_IMAGE_LOCAL)","command":["sleep","600"]}]}}' \
		>/dev/null; \
	trap 'kubectl delete pod "$$HELPER" -n $(NAMESPACE) --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT INT TERM; \
	kubectl wait --namespace $(NAMESPACE) --for=condition=Ready pod/"$$HELPER" --timeout=120s >/dev/null; \
	echo "  Сбор schemas + users + grants..."; \
	kubectl exec "$$HELPER" -n $(NAMESPACE) -- env \
			CLICKHOUSE_HOST="$$CH_HOST" CLICKHOUSE_PORT=9000 \
			CLICKHOUSE_USER=admin CLICKHOUSE_PASSWORD="$$ADMIN_PASSWORD" \
			bash -ec ' \
		set -eo pipefail; \
		mkdir -p /tmp/meta/schemas; cd /tmp/meta; \
		: "clickhouse-client подхватывает CLICKHOUSE_HOST/PORT/USER/PASSWORD из env — нет shell-quoting issues с паролями"; \
		clickhouse-client --query "SELECT name FROM system.databases WHERE name NOT IN ('"'"'system'"'"','"'"'INFORMATION_SCHEMA'"'"','"'"'information_schema'"'"','"'"'default'"'"')" > databases.list; \
		while IFS= read -r db; do \
			[ -z "$$db" ] && continue; \
			OUT_FILE="schemas/$$db.sql"; \
			clickhouse-client --query "SHOW CREATE DATABASE \"$$db\""               | sed -e "s/$$/;/" >  "$$OUT_FILE"; \
			clickhouse-client --query "SELECT name FROM system.tables WHERE database='"'"'$$db'"'"' AND engine NOT IN ('"'"'View'"'"','"'"'MaterializedView'"'"','"'"'LiveView'"'"','"'"'WindowView'"'"')" \
				| while IFS= read -r tbl; do \
					[ -z "$$tbl" ] && continue; \
					clickhouse-client --query "SHOW CREATE TABLE \"$$db\".\"$$tbl\"" | sed -e "s/$$/;/" >> "$$OUT_FILE"; \
				done; \
		done < databases.list; \
		: > users.sql; : > users.list; \
		clickhouse-client --query "SELECT name FROM system.users WHERE name NOT IN ('"'"'default'"'"','"'"'admin'"'"')" \
			| while IFS= read -r u; do \
				[ -z "$$u" ] && continue; \
				echo "$$u" >> users.list; \
				clickhouse-client --query "SHOW CREATE USER \"$$u\""    | sed -e "s/$$/;/" >> users.sql; \
				clickhouse-client --query "SHOW GRANTS FOR \"$$u\""     | sed -e "s/$$/;/" >> users.sql; \
				echo "" >> users.sql; \
			done; \
		: "info.txt — debug-only артефакт (версия + timestamp), при restore не используется"; \
		{ echo "ClickHouse schema backup"; date; \
			clickhouse-client --query "SELECT version()"; } > info.txt 2>&1 || true; \
		tar -czf /tmp/clickhouse-backup.tar.gz -C /tmp/meta .; \
	'; \
	: "kubectl exec ... cat устойчивее, чем kubectl cp (последний под капотом гоняет tar)"; \
	kubectl exec "$$HELPER" -n $(NAMESPACE) -- cat /tmp/clickhouse-backup.tar.gz > "$$OUT"; \
	[ -s "$$OUT" ] || { echo "✗ Архив $$OUT пуст или не скопирован"; exit 1; }; \
	SIZE=$$(du -h --apparent-size "$$OUT" | cut -f1); \
	echo "✓ Schema-бэкап создан: $$OUT ($$SIZE)"

list-backups:
	@echo "Список бэкапов ClickHouse в $(BACKUP_DIR):"
	@if [ -d "$(BACKUP_DIR)" ]; then \
		ls -lht "$(BACKUP_DIR)"/clickhouse-backup-*.tar.gz 2>/dev/null | awk '{print $$9, "(" $$5, $$6, $$7, $$8 ")"}' || echo "  Бэкапы не найдены"; \
	else \
		echo "  Директория $(BACKUP_DIR) не существует"; \
	fi

# Применяет schemas + users.sql из бэкапа. Используются IF NOT EXISTS варианты,
# поэтому существующие БД/таблицы не пересоздаются. Для пользователей
# CREATE USER падает, если пользователь уже существует — поэтому restore
# делает DROP USER IF EXISTS перед каждым (см. ниже сценарий).
restore:
	@if [ -z "$(BACKUP_FILE)" ]; then \
		echo "✗ Укажите файл: make restore BACKUP_FILE=$(BACKUP_DIR)/clickhouse-backup-YYYYMMDD-HHMMSS.tar.gz"; \
		exit 1; \
	fi
	@if [ ! -f "$(BACKUP_FILE)" ]; then echo "✗ Файл $(BACKUP_FILE) не найден"; exit 1; fi
	@if [ "$(SKIP_CONFIRM)" != "1" ]; then \
		echo "⚠ Будут применены schemas + users + grants из $(BACKUP_FILE)."; \
		echo "  Существующие БД/таблицы (IF NOT EXISTS) не трогаются. Пользователи пересоздаются (DROP USER IF EXISTS + CREATE)."; \
		read -p "Продолжить? (y/N): " confirm; \
		if [ "$$confirm" != "y" ] && [ "$$confirm" != "Y" ]; then echo "Отменено."; exit 0; fi; \
	fi
	@TS=$$(date +%Y%m%d-%H%M%S)-$$$$; \
	ADMIN_PASSWORD=$$(kubectl get secret -n $(NAMESPACE) $(RELEASE) -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d); \
	if [ -z "$$ADMIN_PASSWORD" ]; then echo "✗ Не удалось получить admin-password"; exit 1; fi; \
	CH_HOST="$(RELEASE).$(NAMESPACE).svc.cluster.local"; \
	HELPER=clickhouse-restore-$$TS; \
	kubectl run "$$HELPER" --restart=Never --image=$(CLICKHOUSE_IMAGE_LOCAL) --namespace=$(NAMESPACE) \
		--overrides='{"spec":{"containers":[{"name":"'$$HELPER'","image":"$(CLICKHOUSE_IMAGE_LOCAL)","command":["sleep","300"]}]}}' \
		>/dev/null; \
	trap 'kubectl delete pod "$$HELPER" -n $(NAMESPACE) --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT INT TERM; \
	kubectl wait --namespace $(NAMESPACE) --for=condition=Ready pod/"$$HELPER" --timeout=120s >/dev/null; \
	kubectl cp "$(BACKUP_FILE)" "$(NAMESPACE)/$$HELPER:/tmp/backup.tar.gz" >/dev/null; \
	kubectl exec "$$HELPER" -n $(NAMESPACE) -- env \
			CLICKHOUSE_HOST="$$CH_HOST" CLICKHOUSE_PORT=9000 \
			CLICKHOUSE_USER=admin CLICKHOUSE_PASSWORD="$$ADMIN_PASSWORD" \
			bash -ec ' \
		set -eo pipefail; \
		mkdir -p /tmp/meta && tar -xzf /tmp/backup.tar.gz -C /tmp/meta; \
		cd /tmp/meta; \
		: "Хотя бы один из schemas/ или users.sql должен присутствовать — иначе архив битый/чужой"; \
		if [ ! -d schemas ] && [ ! -f users.sql ]; then \
			echo "✗ В архиве нет ни schemas/, ни users.sql — это не valid clickhouse-backup"; exit 1; \
		fi; \
		: "clickhouse-client читает CLICKHOUSE_HOST/PORT/USER/PASSWORD из env (нет shell-quoting issues)"; \
		: "1) schemas: каждый файл — multiquery"; \
		APPLIED_SCHEMAS=0; \
		if [ -d schemas ]; then \
			for f in schemas/*.sql; do [ -f "$$f" ] || continue; \
				echo "  schema: $$(basename $$f)"; \
				clickhouse-client --multiquery < "$$f"; \
				APPLIED_SCHEMAS=$$((APPLIED_SCHEMAS+1)); \
			done; \
		fi; \
		: "2) users: сначала DROP USER IF EXISTS для имён из users.list (точные имена из system.users во время backup — не зависят от awk-парсинга SQL DDL, корректно работают с пробелами/backticks). Затем применить users.sql (CREATE USER + GRANTS)"; \
		APPLIED_USERS=0; \
		if [ -f users.sql ] && [ -s users.sql ]; then \
			: > /tmp/users-drop.sql; \
			if [ -f users.list ]; then \
				while IFS= read -r u; do \
					[ -z "$$u" ] && continue; \
					printf "DROP USER IF EXISTS \"%s\";\n" "$$u" >> /tmp/users-drop.sql; \
					APPLIED_USERS=$$((APPLIED_USERS+1)); \
				done < users.list; \
			fi; \
			cat /tmp/users-drop.sql users.sql | clickhouse-client --multiquery; \
		fi; \
		echo "  Restore: схем применено $$APPLIED_SCHEMAS, пользователей $$APPLIED_USERS"; \
	'; \
	echo "✓ Restore schemas + users завершён"

