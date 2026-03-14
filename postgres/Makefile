# Makefile для загрузки Docker образов в local repository (microk8s)
# Использует образы из https://hub.docker.com/u/bitnamilegacy
SHELL := /bin/bash

# Регистр microk8s (по умолчанию localhost:32000)
REGISTRY ?= localhost:32000

# Helm release defaults
NAMESPACE ?= postgres
RELEASE ?= postgres
CHART_PATH ?= postgresql
ENV ?= dev
VALUES_FILE ?= values-$(ENV).yaml

# Локальные теги, которые будут использоваться в chart'е (НЕ latest)
POSTGRESQL_TAG ?= 18.0.0
OS_SHELL_TAG ?= 12-debian-12-r51
POSTGRES_EXPORTER_TAG ?= 0.18.1

# Source-теги для скачивания (НЕ latest). Bitnami сейчас публикует immutable sha256-* теги.
# При желании можно переопределить своими тегами.
POSTGRESQL_SRC_TAG ?= sha256-6cd40dfda6ab6c08acfe7c965231f814e7003ea3a3ff0fbad3322f010f241d70
OS_SHELL_SRC_TAG ?= 12-debian-12-r51
POSTGRES_EXPORTER_SRC_TAG ?= sha256-f3c2274492470e718af1bb22bd79b5c7bca2d24058bf0ea4e595d2d22347e5ed

# Source images (пытаемся скачать из bitnamilegacy; fallback на bitnami)
POSTGRESQL_IMAGE = bitnamilegacy/postgresql:$(POSTGRESQL_SRC_TAG)
OS_SHELL_IMAGE = bitnamilegacy/os-shell:$(OS_SHELL_SRC_TAG)
POSTGRES_EXPORTER_IMAGE = bitnamilegacy/postgres-exporter:$(POSTGRES_EXPORTER_SRC_TAG)

# Имена для local registry (repository как в chart: bitnami/*)
POSTGRESQL_LOCAL = $(REGISTRY)/bitnami/postgresql:$(POSTGRESQL_TAG)
OS_SHELL_LOCAL = $(REGISTRY)/bitnami/os-shell:$(OS_SHELL_TAG)
POSTGRES_EXPORTER_LOCAL = $(REGISTRY)/bitnami/postgres-exporter:$(POSTGRES_EXPORTER_TAG)

.PHONY: help \
	images-verify images-pull images-tag images-push images-sync images-save images-load images-sync-from-files images-clean images-clean-files \
	pull-images tag-images push-images load-all save-images save-all load-from-files clean clean-images clean-all \
	check-registry list-images list-saved-images \
	install upgrade uninstall helm-status app-create app-show-creds app-drop app-verify \
	delete-pvcs \
	troubleshoot status logs shell describe events \
	backup backup-single view-backup view-backup-head view-backup-search list-backups restore restore-single restore-from-file \
	check-updates

help: ## Показать справку
	@echo "Доступные команды:"
	@echo ""
	@echo "### Helm:"
	@echo "  make install      - Установить PostgreSQL (release $(RELEASE) в namespace $(NAMESPACE))"
	@echo "  make upgrade      - Обновить PostgreSQL"
	@echo "  make uninstall    - Удалить PostgreSQL (⚠ удалит release)"
	@echo "  make helm-status  - Показать helm status"
	@echo "  make pull-images       - Скачать все образы с hub.docker.com/u/bitnamilegacy"
	@echo "  make images-verify     - Проверить доступность тегов в docker.io/bitnamilegacy"
	@echo "  make tag-images        - Тегировать образы для local registry"
	@echo "  make push-images       - Загрузить образы в microk8s registry"
	@echo "  make load-all          - Выполнить все шаги (pull, tag, push)"
	@echo "  make check-registry    - Проверить доступность microk8s registry"
	@echo "  make save-images       - Сохранить все образы в tar файлы"
	@echo "  make save-all          - Скачать и сохранить все образы в файлы"
	@echo "  make load-from-files   - Загрузить все образы из tar файлов"
	@echo "  make list-saved-images - Показать список сохраненных tar файлов"
	@echo ""
	@echo "### Диагностика:"
	@echo "  make troubleshoot - Запустить автоматическую диагностику"
	@echo "  make status       - Показать статус PostgreSQL deployment"
	@echo "  make logs         - Показать логи первого пода PostgreSQL"
	@echo "  make describe     - Показать детальную информацию о поде"
	@echo "  make events       - Показать последние события namespace"
	@echo ""
	@echo "### Бэкапы и восстановление:"
	@echo "  make backup              - Создать бэкап всех БД"
	@echo "  make backup-single       - Создать бэкап одной БД (DB_NAME=app_db)"
	@echo "  make view-backup         - Просмотреть бэкап (BACKUP_FILE=backups/...)"
	@echo "  make view-backup-head    - Показать начало бэкапа"
	@echo "  make view-backup-search  - Поиск в бэкапе (SEARCH='CREATE TABLE')"
	@echo "  make list-backups        - Список всех бэкапов"
	@echo "  make restore             - Восстановить из бэкапа (BACKUP_FILE=...)"
	@echo "  make restore-single      - Восстановить одну БД (BACKUP_FILE=... DB_NAME=...)"
	@echo ""
	@echo "Переменные окружения:"
	@echo "  REGISTRY=localhost:32000        - Адрес local registry"
	@echo "  IMAGES_DIR=images              - Директория для сохранения образов"
	@echo "  BACKUP_DIR=backups             - Директория для бэкапов"
	@echo "  BACKUP_FILE=backups/backup.sql.gz - Путь к файлу бэкапа"
	@echo "  DB_NAME=app_db                 - Имя базы данных"
	@echo "  POSTGRESQL_TAG=18.0.0          - Локальный тег (используется в chart/registry)"
	@echo "  OS_SHELL_TAG=5                 - Локальный тег (используется в chart/registry)"
	@echo "  POSTGRES_EXPORTER_TAG=0.18.1   - Локальный тег (используется в chart/registry)"
	@echo "  POSTGRESQL_SRC_TAG=latest      - Source тег (скачивание)"
	@echo "  OS_SHELL_SRC_TAG=latest        - Source тег (скачивание)"
	@echo "  POSTGRES_EXPORTER_SRC_TAG=latest - Source тег (скачивание)"
	@echo "  VALUES_FILE=values-dev.yaml    - Values файл для helm install/upgrade"

check-registry: ## Проверить доступность microk8s registry
	@echo "Проверка доступности registry $(REGISTRY)..."
	@curl -fsS http://$(REGISTRY)/v2/ > /dev/null && \
		echo "✓ Registry доступен" || \
		(echo "✗ Registry недоступен. Убедитесь, что выполнен: microk8s enable registry" && exit 1)

images-verify:
	@echo "Проверка доступности тегов в docker.io/bitnamilegacy..."
	@command -v docker >/dev/null 2>&1 || { echo "✗ docker не установлен"; exit 1; }
	@FAIL=0; \
	for img in docker.io/bitnamilegacy/postgresql:$(POSTGRESQL_TAG) docker.io/bitnamilegacy/os-shell:$(OS_SHELL_TAG) docker.io/bitnamilegacy/postgres-exporter:$(POSTGRES_EXPORTER_TAG); do \
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
		echo "✗ Некоторые теги в bitnamilegacy недоступны."; \
		exit 1; \
	fi; \
	echo "✓ Все теги доступны в bitnamilegacy"

check-updates: ## Проверить наличие новых версий чарта и образов
	@echo "Проверка обновлений для PostgreSQL..."
	@echo ""
	@CURRENT_CHART=$$(grep '^version:' $(CHART_PATH)/Chart.yaml | awk '{print $$2}'); \
	CURRENT_APP=$$(grep '^appVersion:' $(CHART_PATH)/Chart.yaml | awk '{print $$2}'); \
	echo "Текущая версия чарта: $$CURRENT_CHART (appVersion: $$CURRENT_APP)"; \
	echo "Текущие теги образов: postgresql:$(POSTGRESQL_TAG), os-shell:$(OS_SHELL_TAG), postgres-exporter:$(POSTGRES_EXPORTER_TAG)"; \
	echo ""; \
	echo "Проверка доступных версий чарта..."; \
	if command -v helm >/dev/null 2>&1; then \
		if ! helm repo list 2>/dev/null | grep -q bitnami; then \
			echo "  Добавляю репозиторий bitnami..."; \
			helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true; \
			helm repo update >/dev/null 2>&1 || true; \
		fi; \
		echo "  Поиск последней версии чарта..."; \
		LATEST_CHART=$$(helm search repo bitnami/postgresql --versions --output json 2>/dev/null | jq -r '.[0].version' 2>/dev/null || helm search repo bitnami/postgresql --versions 2>/dev/null | head -2 | tail -1 | awk '{print $$2}' || echo ""); \
		if [ -n "$$LATEST_CHART" ] && [ "$$LATEST_CHART" != "$$CURRENT_CHART" ]; then \
			echo "  ⚠ Доступна новая версия чарта: $$LATEST_CHART"; \
			echo ""; \
			echo "Получение информации о тегах образов из новой версии чарта..."; \
			CHART_INFO=$$(helm show chart bitnami/postgresql --version $$LATEST_CHART 2>/dev/null); \
			if [ -n "$$CHART_INFO" ]; then \
				ANNOTATIONS_SECTION=$$(echo "$$CHART_INFO" | sed -n '/^annotations:/,/^[^ ]/p' | grep -A 20 'images:'); \
				NEW_POSTGRESQL_VERSION=$$(echo "$$ANNOTATIONS_SECTION" | awk '/name: postgresql/{found=1; next} found && /version:/{print $$2; exit}' | tr -d '"' || echo ""); \
				NEW_EXPORTER_VERSION=$$(echo "$$ANNOTATIONS_SECTION" | awk '/name: postgres-exporter/{found=1; next} found && /version:/{print $$2; exit}' | tr -d '"' || echo ""); \
				NEW_OS_SHELL_VERSION=$$(echo "$$ANNOTATIONS_SECTION" | awk '/name: os-shell/{found=1; next} found && /version:/{print $$2; exit}' | tr -d '"' || echo ""); \
				echo ""; \
				echo "Версии образов в новой версии чарта:"; \
				if [ -n "$$NEW_POSTGRESQL_VERSION" ]; then \
					echo "  postgresql: $$NEW_POSTGRESQL_VERSION"; \
				fi; \
				if [ -n "$$NEW_EXPORTER_VERSION" ]; then \
					echo "  postgres-exporter: $$NEW_EXPORTER_VERSION"; \
				fi; \
				if [ -n "$$NEW_OS_SHELL_VERSION" ]; then \
					echo "  os-shell: $$NEW_OS_SHELL_VERSION"; \
				fi; \
				echo ""; \
				echo "Команды для проверки наличия образов в bitnamilegacy:"; \
				HAS_NEW=0; \
				if [ -n "$$NEW_POSTGRESQL_VERSION" ] && [ "$$NEW_POSTGRESQL_VERSION" != "$(POSTGRESQL_TAG)" ]; then \
					echo "  docker manifest inspect docker.io/bitnamilegacy/postgresql:$$NEW_POSTGRESQL_VERSION"; \
					HAS_NEW=1; \
				fi; \
				if [ -n "$$NEW_EXPORTER_VERSION" ] && [ "$$NEW_EXPORTER_VERSION" != "$(POSTGRES_EXPORTER_TAG)" ]; then \
					echo "  docker manifest inspect docker.io/bitnamilegacy/postgres-exporter:$$NEW_EXPORTER_VERSION"; \
					HAS_NEW=1; \
				fi; \
				if [ -n "$$NEW_OS_SHELL_VERSION" ] && [ "$$NEW_OS_SHELL_VERSION" != "$(OS_SHELL_TAG)" ]; then \
					echo "  docker manifest inspect docker.io/bitnamilegacy/os-shell:$$NEW_OS_SHELL_VERSION"; \
					HAS_NEW=1; \
				fi; \
				if [ $$HAS_NEW -eq 0 ]; then \
					echo "  (все версии образов остались прежними)"; \
					echo "  Примечание: для os-shell и других образов могут использоваться полные теги (например, 12-debian-12-r51)"; \
					echo "  Проверьте Chart.yaml новой версии для точных тегов"; \
				fi; \
			else \
				echo "  ⚠ Не удалось получить информацию о чарте"; \
				echo "  Попробуйте вручную: helm show chart bitnami/postgresql --version $$LATEST_CHART | grep -A 20 '^annotations:'"; \
			fi; \
		elif [ -n "$$LATEST_CHART" ]; then \
			echo "  ✓ Используется последняя версия чарта: $$CURRENT_CHART"; \
		else \
			echo "  ⚠ Не удалось получить версию чарта"; \
		fi; \
	else \
		echo "  ⚠ helm не установлен, проверка версий чарта пропущена"; \
		echo "  Альтернатива: проверьте https://github.com/bitnami/charts/tree/main/bitnami/postgresql"; \
	fi; \
	echo ""; \
	echo "Примечание: После проверки образов обновите теги в Makefile и выполните make images-verify"

## =========================
## Helm (для независимого использования)
## =========================

install:
	@echo "Установка PostgreSQL (release $(RELEASE) в namespace $(NAMESPACE))..."
	@kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	@helm upgrade --install $(RELEASE) ./$(CHART_PATH) --namespace $(NAMESPACE) -f $(VALUES_FILE)

upgrade:
	@echo "Обновление PostgreSQL (release $(RELEASE) в namespace $(NAMESPACE))..."
	@helm upgrade --install $(RELEASE) ./$(CHART_PATH) --namespace $(NAMESPACE) -f $(VALUES_FILE)

uninstall:
	@echo "⚠ ВНИМАНИЕ: Это удалит Helm release $(RELEASE)!"
	@read -p "Вы уверены? (y/N): " confirm && \
		if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
			helm uninstall $(RELEASE) --namespace $(NAMESPACE) || echo "Helm release не найден"; \
		else \
			echo "Отменено."; \
			exit 0; \
		fi

helm-status:
	@helm status $(RELEASE) --namespace $(NAMESPACE) 2>/dev/null || echo "Helm release не найден"

## Пересоздание с новым размером PVC
delete-pvcs:
	@kubectl delete pvc -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE) --ignore-not-found
	@echo "✓ PVC удалены. Обновите primary.persistence.size в values-$(ENV).yaml и выполните make postgres-up ENV=$(ENV)"

## =========================
## App accounts (per-app isolation)
## =========================

# Usage: make app-create APP=myapp [APP_NS=myapp] [POSTGRES_ADMIN_PASSWORD=...]
app-create:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-create APP=myapp)"; exit 1; fi
	@APP_NS=$${APP_NS:-$(APP)}; \
	APP_DB=$${APP_DB:-app_$(APP)}; \
	APP_USER=$${APP_USER:-app_$(APP)}; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-postgres}; \
	APP_PASSWORD=$${APP_PASSWORD:-}; \
	if [ -z "$$APP_PASSWORD" ]; then \
		command -v openssl >/dev/null 2>&1 || { echo "✗ openssl не найден (передайте APP_PASSWORD=... или установите openssl)"; exit 1; }; \
		APP_PASSWORD=$$(openssl rand -hex 16); \
	fi; \
	POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE),app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then echo "✗ PostgreSQL pod не найден в namespace $(NAMESPACE)"; exit 1; fi; \
	ADMIN_PASSWORD="$(POSTGRES_ADMIN_PASSWORD)"; \
	PG_HOST="$(RELEASE)-postgresql.$(NAMESPACE).svc.cluster.local"; \
	PG_PORT=5432; \
	echo "Creating role/db: $$APP_USER / $$APP_DB"; \
	kubectl exec -i "$$POD" -n $(NAMESPACE) -- env ADMIN_PASSWORD="$$ADMIN_PASSWORD" APP_USER="$$APP_USER" APP_DB="$$APP_DB" APP_PASSWORD="$$APP_PASSWORD" bash -s < "scripts/app-create-in-pod.sh"; \
	echo "Creating Secret $$APP_SECRET_NAME in namespace $$APP_NS"; \
	kubectl create namespace "$$APP_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; \
	kubectl delete secret "$$APP_SECRET_NAME" -n "$$APP_NS" --ignore-not-found >/dev/null; \
	kubectl create secret generic "$$APP_SECRET_NAME" -n "$$APP_NS" \
		--from-literal=PGHOST="$$PG_HOST" \
		--from-literal=PGPORT="$$PG_PORT" \
		--from-literal=PGDATABASE="$$APP_DB" \
		--from-literal=PGUSER="$$APP_USER" \
		--from-literal=PGPASSWORD="$$APP_PASSWORD" \
		--from-literal=DATABASE_URL="postgresql://$$APP_USER:$$APP_PASSWORD@$$PG_HOST:$$PG_PORT/$$APP_DB?sslmode=disable" \
		>/dev/null; \
	echo "✓ Done (Secret: $$APP_NS/$$APP_SECRET_NAME)"

app-show-creds:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-show-creds APP=mcp)"; exit 1; fi
	@APP_NS=$${APP_NS:-$(APP)}; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-postgres}; \
	if ! kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" >/dev/null 2>&1; then \
		echo "✗ Secret $$APP_SECRET_NAME не найден в namespace $$APP_NS"; exit 1; \
	fi; \
	echo "Secret: $$APP_NS/$$APP_SECRET_NAME"; \
	echo "---"; \
	echo "PGHOST=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.PGHOST}' 2>/dev/null | base64 -d)"; \
	echo "PGPORT=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.PGPORT}' 2>/dev/null | base64 -d)"; \
	echo "PGDATABASE=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.PGDATABASE}' 2>/dev/null | base64 -d)"; \
	echo "PGUSER=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.PGUSER}' 2>/dev/null | base64 -d)"; \
	echo "PGPASSWORD=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.PGPASSWORD}' 2>/dev/null | base64 -d)"; \
	URL=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.DATABASE_URL}' 2>/dev/null | base64 -d); \
	if echo "$$URL" | grep -q 'sslmode='; then echo "DATABASE_URL=$$URL"; elif echo "$$URL" | grep -q '?'; then echo "DATABASE_URL=$$URL\&sslmode=disable"; else echo "DATABASE_URL=$$URL?sslmode=disable"; fi

# Usage: make app-drop APP=myapp [APP_NS=myapp] [POSTGRES_ADMIN_PASSWORD=...]
app-drop:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-drop APP=myapp)"; exit 1; fi
	@APP_NS=$${APP_NS:-$(APP)}; \
	APP_DB=$${APP_DB:-app_$(APP)}; \
	APP_USER=$${APP_USER:-app_$(APP)}; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-postgres}; \
	POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE),app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then echo "✗ PostgreSQL pod не найден в namespace $(NAMESPACE)"; exit 1; fi; \
	ADMIN_PASSWORD="$(POSTGRES_ADMIN_PASSWORD)"; \
	if [ -z "$$ADMIN_PASSWORD" ]; then \
		ADMIN_PASSWORD=$$(kubectl exec "$$POD" -n $(NAMESPACE) -- cat /opt/bitnami/postgresql/secrets/postgres-password 2>/dev/null | tr -d '\n'); \
	fi; \
	if [ -z "$$ADMIN_PASSWORD" ]; then \
		ADMIN_PASSWORD=$$(kubectl get secret $(RELEASE)-postgresql -n $(NAMESPACE) -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d); \
	fi; \
	if [ -z "$$ADMIN_PASSWORD" ]; then echo "✗ Не удалось получить пароль postgres (задайте POSTGRES_ADMIN_PASSWORD=... или проверьте секрет $(RELEASE)-postgresql)"; exit 1; fi; \
	echo "Dropping database $$APP_DB and role $$APP_USER..."; \
	kubectl exec "$$POD" -n $(NAMESPACE) -- env PGPASSWORD="$$ADMIN_PASSWORD" psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$$APP_DB' AND pid <> pg_backend_pid();" 2>/dev/null || true; \
	kubectl exec "$$POD" -n $(NAMESPACE) -- env PGPASSWORD="$$ADMIN_PASSWORD" psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "DROP DATABASE IF EXISTS \"$$APP_DB\";"; \
	kubectl exec "$$POD" -n $(NAMESPACE) -- env PGPASSWORD="$$ADMIN_PASSWORD" psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "DROP ROLE IF EXISTS \"$$APP_USER\";"; \
	echo "Deleting Secret $$APP_SECRET_NAME in namespace $$APP_NS..."; \
	kubectl delete secret "$$APP_SECRET_NAME" -n "$$APP_NS" --ignore-not-found; \
	echo "✓ БД $$APP_DB, роль $$APP_USER и Secret $$APP_NS/$$APP_SECRET_NAME удалены"

# Usage: make app-verify APP=mcp
app-verify:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-verify APP=mcp)"; exit 1; fi
	@APP_NS=$${APP_NS:-$(APP)}; \
	APP_DB=$${APP_DB:-app_$(APP)}; \
	APP_USER=$${APP_USER:-app_$(APP)}; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-postgres}; \
	POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE),app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then echo "✗ PostgreSQL pod не найден в namespace $(NAMESPACE)"; exit 1; fi; \
	APP_PASSWORD=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.PGPASSWORD}' 2>/dev/null | base64 -d); \
	if [ -z "$$APP_PASSWORD" ]; then echo "✗ Secret $$APP_SECRET_NAME не найден или нет PGPASSWORD в namespace $$APP_NS"; exit 1; fi; \
	echo "Проверка подключения $$APP_USER@$$APP_DB..."; \
	if kubectl exec "$$POD" -n $(NAMESPACE) -- env PGPASSWORD="$$APP_PASSWORD" psql -v ON_ERROR_STOP=1 -U "$$APP_USER" -d "$$APP_DB" -t -c 'SELECT 1' | grep -q 1; then \
		echo "✓ Подключение успешно"; \
	else \
		echo "✗ Подключение не удалось (пароль или роль не совпадают)"; exit 1; \
	fi

## =========================
## Images (унифицированные targets)
## =========================

images-pull: pull-images
images-tag: tag-images
images-push: push-images
images-sync: load-all
images-save: save-images
images-load: load-from-files
images-sync-from-files: images-load images-tag images-push
images-clean: clean
images-clean-files: clean-images

pull-postgresql: ## Скачать образ PostgreSQL
	@echo "Скачивание образа PostgreSQL..."
	@if docker pull $(POSTGRESQL_IMAGE) 2>/dev/null; then \
		echo "✓ Загружен с bitnamilegacy"; \
	elif docker pull bitnami/postgresql:$(POSTGRESQL_SRC_TAG); then \
		echo "✓ Загружен с bitnami (fallback)"; \
		docker tag bitnami/postgresql:$(POSTGRESQL_SRC_TAG) $(POSTGRESQL_IMAGE); \
	else \
		echo "✗ Ошибка: образ не найден ни в bitnamilegacy, ни в bitnami"; \
		exit 1; \
	fi

pull-os-shell: ## Скачать образ os-shell
	@echo "Скачивание образа os-shell..."
	@if docker pull $(OS_SHELL_IMAGE) 2>/dev/null; then \
		echo "✓ Загружен с bitnamilegacy"; \
	elif docker pull bitnami/os-shell:$(OS_SHELL_SRC_TAG); then \
		echo "✓ Загружен с bitnami (fallback)"; \
		docker tag bitnami/os-shell:$(OS_SHELL_SRC_TAG) $(OS_SHELL_IMAGE); \
	else \
		echo "✗ Ошибка: образ не найден ни в bitnamilegacy, ни в bitnami"; \
		exit 1; \
	fi

pull-postgres-exporter: ## Скачать образ postgres-exporter
	@echo "Скачивание образа postgres-exporter..."
	@if docker pull $(POSTGRES_EXPORTER_IMAGE) 2>/dev/null; then \
		echo "✓ Загружен с bitnamilegacy"; \
	elif docker pull bitnami/postgres-exporter:$(POSTGRES_EXPORTER_SRC_TAG); then \
		echo "✓ Загружен с bitnami (fallback)"; \
		docker tag bitnami/postgres-exporter:$(POSTGRES_EXPORTER_SRC_TAG) $(POSTGRES_EXPORTER_IMAGE); \
	else \
		echo "✗ Ошибка: образ не найден ни в bitnamilegacy, ни в bitnami"; \
		exit 1; \
	fi

pull-images: pull-postgresql pull-os-shell pull-postgres-exporter ## Скачать все образы

tag-postgresql: pull-postgresql ## Тегировать образ PostgreSQL для local registry
	@echo "Тегирование $(POSTGRESQL_IMAGE) -> $(POSTGRESQL_LOCAL)..."
	@docker tag $(POSTGRESQL_IMAGE) $(POSTGRESQL_LOCAL)

tag-os-shell: pull-os-shell ## Тегировать образ os-shell для local registry
	@echo "Тегирование $(OS_SHELL_IMAGE) -> $(OS_SHELL_LOCAL)..."
	@docker tag $(OS_SHELL_IMAGE) $(OS_SHELL_LOCAL)

tag-postgres-exporter: pull-postgres-exporter ## Тегировать образ postgres-exporter для local registry
	@echo "Тегирование $(POSTGRES_EXPORTER_IMAGE) -> $(POSTGRES_EXPORTER_LOCAL)..."
	@docker tag $(POSTGRES_EXPORTER_IMAGE) $(POSTGRES_EXPORTER_LOCAL)

tag-images: tag-postgresql tag-os-shell tag-postgres-exporter ## Тегировать все образы

push-postgresql: tag-postgresql ## Загрузить образ PostgreSQL в registry
	@echo "Загрузка $(POSTGRESQL_LOCAL) в registry..."
	@docker push $(POSTGRESQL_LOCAL)

push-os-shell: tag-os-shell ## Загрузить образ os-shell в registry
	@echo "Загрузка $(OS_SHELL_LOCAL) в registry..."
	@docker push $(OS_SHELL_LOCAL)

push-postgres-exporter: tag-postgres-exporter ## Загрузить образ postgres-exporter в registry
	@echo "Загрузка $(POSTGRES_EXPORTER_LOCAL) в registry..."
	@docker push $(POSTGRES_EXPORTER_LOCAL)

push-images: push-postgresql push-os-shell push-postgres-exporter ## Загрузить все образы в registry

# Альтернативный способ через microk8s ctr (для использования без registry)
# Использует те же теги что и в chart (registry-1.docker.io/bitnami/*)
import-postgresql: pull-postgresql ## Импортировать образ PostgreSQL напрямую в containerd
	@echo "Импорт $(POSTGRESQL_IMAGE) в microk8s containerd..."
	@docker save $(POSTGRESQL_IMAGE) | microk8s ctr image import - 2>/dev/null || \
		docker save bitnami/postgresql:$(POSTGRESQL_TAG) | microk8s ctr image import -
	@echo "Тегирование для использования в кластере (registry-1.docker.io/bitnami/postgresql:$(POSTGRESQL_TAG))..."
	@microk8s ctr image tag $(POSTGRESQL_IMAGE) registry-1.docker.io/bitnami/postgresql:$(POSTGRESQL_TAG) 2>/dev/null || \
		microk8s ctr image tag bitnami/postgresql:$(POSTGRESQL_TAG) registry-1.docker.io/bitnami/postgresql:$(POSTGRESQL_TAG) 2>/dev/null || true

import-os-shell: pull-os-shell ## Импортировать образ os-shell напрямую в containerd
	@echo "Импорт $(OS_SHELL_IMAGE) в microk8s containerd..."
	@docker save $(OS_SHELL_IMAGE) | microk8s ctr image import - 2>/dev/null || \
		docker save bitnami/os-shell:$(OS_SHELL_TAG) | microk8s ctr image import -
	@echo "Тегирование для использования в кластере (registry-1.docker.io/bitnami/os-shell:$(OS_SHELL_TAG))..."
	@microk8s ctr image tag $(OS_SHELL_IMAGE) registry-1.docker.io/bitnami/os-shell:$(OS_SHELL_TAG) 2>/dev/null || \
		microk8s ctr image tag bitnami/os-shell:$(OS_SHELL_TAG) registry-1.docker.io/bitnami/os-shell:$(OS_SHELL_TAG) 2>/dev/null || true

import-postgres-exporter: pull-postgres-exporter ## Импортировать образ postgres-exporter напрямую в containerd
	@echo "Импорт $(POSTGRES_EXPORTER_IMAGE) в microk8s containerd..."
	@docker save $(POSTGRES_EXPORTER_IMAGE) | microk8s ctr image import - 2>/dev/null || \
		docker save bitnami/postgres-exporter:$(POSTGRES_EXPORTER_TAG) | microk8s ctr image import -
	@echo "Тегирование для использования в кластере (registry-1.docker.io/bitnami/postgres-exporter:$(POSTGRES_EXPORTER_TAG))..."
	@microk8s ctr image tag $(POSTGRES_EXPORTER_IMAGE) registry-1.docker.io/bitnami/postgres-exporter:$(POSTGRES_EXPORTER_TAG) 2>/dev/null || \
		microk8s ctr image tag bitnami/postgres-exporter:$(POSTGRES_EXPORTER_TAG) registry-1.docker.io/bitnami/postgres-exporter:$(POSTGRES_EXPORTER_TAG) 2>/dev/null || true

import-images: import-postgresql import-os-shell import-postgres-exporter ## Импортировать все образы в containerd

load-all: pull-images tag-images push-images ## Выполнить все шаги (pull, tag, push)

load-containerd: import-images ## Загрузить все образы через containerd (альтернативный способ)

# Сохранение образов в файлы
IMAGES_DIR ?= images

save-postgresql: pull-postgresql ## Сохранить образ PostgreSQL в tar файл
	@mkdir -p $(IMAGES_DIR)
	@echo "Сохранение образа PostgreSQL в $(IMAGES_DIR)/postgresql-$(POSTGRESQL_TAG).tar..."
	@$(MAKE) tag-postgresql >/dev/null
	@docker save $(POSTGRESQL_LOCAL) -o $(IMAGES_DIR)/postgresql-$(POSTGRESQL_TAG).tar
	@echo "✓ Образ сохранен: $(IMAGES_DIR)/postgresql-$(POSTGRESQL_TAG).tar"
	@ls -lh $(IMAGES_DIR)/postgresql-$(POSTGRESQL_TAG).tar

save-os-shell: pull-os-shell ## Сохранить образ os-shell в tar файл
	@mkdir -p $(IMAGES_DIR)
	@echo "Сохранение образа os-shell в $(IMAGES_DIR)/os-shell-$(OS_SHELL_TAG).tar..."
	@$(MAKE) tag-os-shell >/dev/null
	@docker save $(OS_SHELL_LOCAL) -o $(IMAGES_DIR)/os-shell-$(OS_SHELL_TAG).tar
	@echo "✓ Образ сохранен: $(IMAGES_DIR)/os-shell-$(OS_SHELL_TAG).tar"
	@ls -lh $(IMAGES_DIR)/os-shell-$(OS_SHELL_TAG).tar

save-postgres-exporter: pull-postgres-exporter ## Сохранить образ postgres-exporter в tar файл
	@mkdir -p $(IMAGES_DIR)
	@echo "Сохранение образа postgres-exporter в $(IMAGES_DIR)/postgres-exporter-$(POSTGRES_EXPORTER_TAG).tar..."
	@$(MAKE) tag-postgres-exporter >/dev/null
	@docker save $(POSTGRES_EXPORTER_LOCAL) -o $(IMAGES_DIR)/postgres-exporter-$(POSTGRES_EXPORTER_TAG).tar
	@echo "✓ Образ сохранен: $(IMAGES_DIR)/postgres-exporter-$(POSTGRES_EXPORTER_TAG).tar"
	@ls -lh $(IMAGES_DIR)/postgres-exporter-$(POSTGRES_EXPORTER_TAG).tar

save-images: save-postgresql save-os-shell save-postgres-exporter ## Сохранить все образы в tar файлы

save-all: pull-images save-images ## Скачать и сохранить все образы в файлы

# Загрузка образов из файлов
load-from-file-postgresql: ## Загрузить образ PostgreSQL из tar файла
	@if [ ! -f "$(IMAGES_DIR)/postgresql-$(POSTGRESQL_TAG).tar" ]; then \
		echo "✗ Файл $(IMAGES_DIR)/postgresql-$(POSTGRESQL_TAG).tar не найден"; \
		exit 1; \
	fi
	@echo "Загрузка образа из $(IMAGES_DIR)/postgresql-$(POSTGRESQL_TAG).tar..."
	@docker load -i $(IMAGES_DIR)/postgresql-$(POSTGRESQL_TAG).tar
	@echo "✓ Образ загружен"

load-from-file-os-shell: ## Загрузить образ os-shell из tar файла
	@if [ ! -f "$(IMAGES_DIR)/os-shell-$(OS_SHELL_TAG).tar" ]; then \
		echo "✗ Файл $(IMAGES_DIR)/os-shell-$(OS_SHELL_TAG).tar не найден"; \
		exit 1; \
	fi
	@echo "Загрузка образа из $(IMAGES_DIR)/os-shell-$(OS_SHELL_TAG).tar..."
	@docker load -i $(IMAGES_DIR)/os-shell-$(OS_SHELL_TAG).tar
	@echo "✓ Образ загружен"

load-from-file-postgres-exporter: ## Загрузить образ postgres-exporter из tar файла
	@if [ ! -f "$(IMAGES_DIR)/postgres-exporter-$(POSTGRES_EXPORTER_TAG).tar" ]; then \
		echo "✗ Файл $(IMAGES_DIR)/postgres-exporter-$(POSTGRES_EXPORTER_TAG).tar не найден"; \
		exit 1; \
	fi
	@echo "Загрузка образа из $(IMAGES_DIR)/postgres-exporter-$(POSTGRES_EXPORTER_TAG).tar..."
	@docker load -i $(IMAGES_DIR)/postgres-exporter-$(POSTGRES_EXPORTER_TAG).tar
	@echo "✓ Образ загружен"

load-from-files: load-from-file-postgresql load-from-file-os-shell load-from-file-postgres-exporter ## Загрузить все образы из tar файлов

list-images: ## Показать список загруженных образов в microk8s
	@echo "Образы в microk8s containerd:"
	@microk8s ctr images list | grep -E "bitnami/(postgresql|os-shell|postgres-exporter)" || echo "Образы не найдены"

list-saved-images: ## Показать список сохраненных tar файлов
	@if [ -d "$(IMAGES_DIR)" ]; then \
		echo "Сохраненные образы в $(IMAGES_DIR):"; \
		ls -lh $(IMAGES_DIR)/*.tar 2>/dev/null || echo "Файлы не найдены"; \
	else \
		echo "Директория $(IMAGES_DIR) не существует"; \
	fi

clean: ## Удалить локальные Docker образы
	@echo "Удаление локальных образов..."
	@docker rmi $(POSTGRESQL_LOCAL) $(OS_SHELL_LOCAL) $(POSTGRES_EXPORTER_LOCAL) 2>/dev/null || true
	@docker rmi $(POSTGRESQL_IMAGE) $(OS_SHELL_IMAGE) $(POSTGRES_EXPORTER_IMAGE) 2>/dev/null || true
	@docker rmi bitnami/postgresql:$(POSTGRESQL_TAG) bitnami/os-shell:$(OS_SHELL_TAG) bitnami/postgres-exporter:$(POSTGRES_EXPORTER_TAG) 2>/dev/null || true
	@echo "Готово"

clean-images: ## Удалить сохраненные tar файлы образов
	@if [ -d "$(IMAGES_DIR)" ]; then \
		echo "Удаление tar файлов из $(IMAGES_DIR)..."; \
		rm -f $(IMAGES_DIR)/*.tar; \
		echo "Готово"; \
	else \
		echo "Директория $(IMAGES_DIR) не существует"; \
	fi

clean-all: clean clean-images ## Удалить локальные образы и сохраненные файлы

# Диагностика и troubleshooting
troubleshoot: ## Запустить автоматическую диагностику PostgreSQL
	@./scripts/troubleshoot.sh

status: ## Показать статус PostgreSQL deployment
	@echo "Статус PostgreSQL в namespace $(NAMESPACE):"
	@kubectl get pods,statefulset,svc,pvc -n $(NAMESPACE) -o wide 2>/dev/null || echo "PostgreSQL не развернут или namespace не существует"

logs: ## Показать логи первого пода PostgreSQL
	@POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then \
		echo "Поды PostgreSQL не найдены"; \
	else \
		echo "Логи пода: $$POD"; \
		kubectl logs -f $$POD -n $(NAMESPACE); \
	fi

shell: ## Зайти в shell первого пода PostgreSQL
	@POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then \
		echo "Поды PostgreSQL не найдены"; \
		exit 1; \
	else \
		echo "Подключение к поду: $$POD"; \
		kubectl exec -it $$POD -n $(NAMESPACE) -- bash || kubectl exec -it $$POD -n $(NAMESPACE) -- sh; \
	fi

describe: ## Показать детальную информацию о первом поде PostgreSQL
	@POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then \
		echo "Поды PostgreSQL не найдены"; \
	else \
		kubectl describe pod $$POD -n $(NAMESPACE); \
	fi

events: ## Показать последние события namespace postgres
	@kubectl get events -n $(NAMESPACE) --sort-by='.lastTimestamp' | tail -20

# Бэкапы и восстановление БД
BACKUP_DIR ?= backups
BACKUP_FILE ?= $(BACKUP_DIR)/postgres-backup-$(shell date +%Y%m%d-%H%M%S)

backup: ## Создать бэкап всех баз данных PostgreSQL
	@mkdir -p $(BACKUP_DIR)
	@echo "Создание бэкапа PostgreSQL..."
	@POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then \
		echo "✗ Поды PostgreSQL не найдены"; \
		exit 1; \
	fi; \
	PASSWORD=$$(kubectl get secret $(RELEASE)-postgresql -n $(NAMESPACE) -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d); \
	if [ -z "$$PASSWORD" ]; then \
		echo "✗ Не удалось получить пароль из секрета"; \
		exit 1; \
	fi; \
	echo "Создание бэкапа в $(BACKUP_FILE).sql.gz..."; \
	kubectl exec $$POD -n $(NAMESPACE) -- env PGPASSWORD=$$PASSWORD pg_dumpall -U postgres | gzip > $(BACKUP_FILE).sql.gz && \
	SIZE=$$(ls -lh $(BACKUP_FILE).sql.gz | awk '{print $$5}'); \
	echo "✓ Бэкап создан: $(BACKUP_FILE).sql.gz ($$SIZE)" || \
		(echo "✗ Ошибка при создании бэкапа" && exit 1)

backup-single: ## Создать бэкап конкретной базы данных
	@if [ -z "$(DB_NAME)" ]; then \
		echo "✗ Укажите имя базы данных: make backup-single DB_NAME=app_db"; \
		exit 1; \
	fi
	@mkdir -p $(BACKUP_DIR)
	@echo "Создание бэкапа базы данных $(DB_NAME)..."
	@POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then \
		echo "✗ Поды PostgreSQL не найдены"; \
		exit 1; \
	fi; \
	PASSWORD=$$(kubectl get secret $(RELEASE)-postgresql -n $(NAMESPACE) -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d); \
	if [ -z "$$PASSWORD" ]; then \
		echo "✗ Не удалось получить пароль из секрета"; \
		exit 1; \
	fi; \
	BACKUP_FILE=$(BACKUP_DIR)/$(DB_NAME)-backup-$(shell date +%Y%m%d-%H%M%S).sql.gz; \
	echo "Создание бэкапа в $$BACKUP_FILE..."; \
	kubectl exec $$POD -n $(NAMESPACE) -- env PGPASSWORD=$$PASSWORD pg_dump -U postgres $(DB_NAME) | gzip > $$BACKUP_FILE && \
	SIZE=$$(ls -lh $$BACKUP_FILE | awk '{print $$5}'); \
	echo "✓ Бэкап создан: $$BACKUP_FILE ($$SIZE)" || \
		(echo "✗ Ошибка при создании бэкапа" && exit 1)

view-backup: ## Просмотреть содержимое бэкапа (с потоковой декомпрессией)
	@if [ -z "$(BACKUP_FILE)" ]; then \
		echo "✗ Укажите файл бэкапа: make view-backup BACKUP_FILE=backups/postgres-backup-20231103.sql.gz"; \
		echo "Доступные бэкапы:"; \
		ls -lh $(BACKUP_DIR)/*.sql.gz 2>/dev/null || echo "  Бэкапы не найдены"; \
		exit 1; \
	fi
	@if [ ! -f "$(BACKUP_FILE)" ]; then \
		echo "✗ Файл $(BACKUP_FILE) не найден"; \
		exit 1; \
	fi
	@echo "Просмотр бэкапа $(BACKUP_FILE) (используйте q для выхода)..."
	@gunzip -c $(BACKUP_FILE) | less

view-backup-head: ## Показать начало бэкапа (первые N строк)
	@if [ -z "$(BACKUP_FILE)" ]; then \
		echo "✗ Укажите файл бэкапа: make view-backup-head BACKUP_FILE=backups/postgres-backup-20231103.sql.gz"; \
		exit 1; \
	fi
	@LINES=$${LINES:-50}; \
	echo "Первые $$LINES строк бэкапа $(BACKUP_FILE):"; \
	echo "-----------------------------------"; \
	gunzip -c $(BACKUP_FILE) | head -n $$LINES

view-backup-search: ## Поиск в бэкапе (с потоковой декомпрессией)
	@if [ -z "$(BACKUP_FILE)" ] || [ -z "$(SEARCH)" ]; then \
		echo "✗ Использование: make view-backup-search BACKUP_FILE=backups/postgres-backup-20231103.sql.gz SEARCH='CREATE TABLE'"; \
		exit 1; \
	fi
	@echo "Поиск '$(SEARCH)' в бэкапе $(BACKUP_FILE)..."
	@gunzip -c $(BACKUP_FILE) | grep -i "$(SEARCH)" | head -20

list-backups: ## Показать список всех бэкапов
	@echo "Список бэкапов в $(BACKUP_DIR):"
	@if [ -d "$(BACKUP_DIR)" ]; then \
		ls -lht $(BACKUP_DIR)/*.sql.gz 2>/dev/null | awk '{print $$9, "(" $$5, $$6, $$7, $$8 ")"}' || echo "Бэкапы не найдены"; \
	else \
		echo "Директория $(BACKUP_DIR) не существует"; \
	fi

restore: ## Восстановить БД из бэкапа (⚠️ ПЕРЕЗАПИСЫВАЕТ СУЩЕСТВУЮЩИЕ ДАННЫЕ!)
	@if [ -z "$(BACKUP_FILE)" ]; then \
		echo "✗ Укажите файл бэкапа: make restore BACKUP_FILE=backups/postgres-backup-20231103.sql.gz"; \
		echo "Доступные бэкапы:"; \
		ls -lh $(BACKUP_DIR)/*.sql.gz 2>/dev/null || echo "  Бэкапы не найдены"; \
		exit 1; \
	fi
	@if [ ! -f "$(BACKUP_FILE)" ]; then \
		echo "✗ Файл $(BACKUP_FILE) не найден"; \
		exit 1; \
	fi
	@echo "⚠️  ВНИМАНИЕ: Восстановление из $(BACKUP_FILE) перезапишет существующие данные!"
	@read -p "Вы уверены? (yes/no): " confirm && [ "$$confirm" = "yes" ] || (echo "Отменено" && exit 1)
	@POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then \
		echo "✗ Поды PostgreSQL не найдены"; \
		exit 1; \
	fi; \
	PASSWORD=$$(kubectl get secret $(RELEASE)-postgresql -n $(NAMESPACE) -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d); \
	if [ -z "$$PASSWORD" ]; then \
		echo "✗ Не удалось получить пароль из секрета"; \
		exit 1; \
	fi; \
	echo "Восстановление из $(BACKUP_FILE)..."; \
	gunzip -c $(BACKUP_FILE) | kubectl exec -i $$POD -n $(NAMESPACE) -- env PGPASSWORD=$$PASSWORD psql -U postgres && \
	echo "✓ Восстановление завершено" || \
		(echo "✗ Ошибка при восстановлении" && exit 1)

restore-single: ## Восстановить конкретную БД из бэкапа (⚠️ ПЕРЕЗАПИСЫВАЕТ ДАННЫЕ!)
	@if [ -z "$(BACKUP_FILE)" ] || [ -z "$(DB_NAME)" ]; then \
		echo "✗ Использование: make restore-single BACKUP_FILE=backups/app_db-backup-20231103.sql.gz DB_NAME=app_db"; \
		exit 1; \
	fi
	@if [ ! -f "$(BACKUP_FILE)" ]; then \
		echo "✗ Файл $(BACKUP_FILE) не найден"; \
		exit 1; \
	fi
	@echo "⚠️  ВНИМАНИЕ: Восстановление БД $(DB_NAME) из $(BACKUP_FILE) перезапишет существующие данные!"
	@read -p "Вы уверены? (yes/no): " confirm && [ "$$confirm" = "yes" ] || (echo "Отменено" && exit 1)
	@POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then \
		echo "✗ Поды PostgreSQL не найдены"; \
		exit 1; \
	fi; \
	PASSWORD=$$(kubectl get secret $(RELEASE)-postgresql -n $(NAMESPACE) -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d); \
	if [ -z "$$PASSWORD" ]; then \
		echo "✗ Не удалось получить пароль из секрета"; \
		exit 1; \
	fi; \
	echo "Восстановление БД $(DB_NAME) из $(BACKUP_FILE)..."; \
	gunzip -c $(BACKUP_FILE) | kubectl exec -i $$POD -n $(NAMESPACE) -- env PGPASSWORD=$$PASSWORD psql -U postgres -d $(DB_NAME) && \
	echo "✓ Восстановление завершено" || \
		(echo "✗ Ошибка при восстановлении" && exit 1)

restore-from-file: ## Восстановить БД из неархивированного SQL файла
	@if [ -z "$(BACKUP_FILE)" ]; then \
		echo "✗ Укажите файл: make restore-from-file BACKUP_FILE=backup.sql"; \
		exit 1; \
	fi
	@if [ ! -f "$(BACKUP_FILE)" ]; then \
		echo "✗ Файл $(BACKUP_FILE) не найден"; \
		exit 1; \
	fi
	@echo "⚠️  ВНИМАНИЕ: Восстановление из $(BACKUP_FILE) перезапишет существующие данные!"
	@read -p "Вы уверены? (yes/no): " confirm && [ "$$confirm" = "yes" ] || (echo "Отменено" && exit 1)
	@POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then \
		echo "✗ Поды PostgreSQL не найдены"; \
		exit 1; \
	fi; \
	PASSWORD=$$(kubectl get secret $(RELEASE)-postgresql -n $(NAMESPACE) -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d); \
	if [ -z "$$PASSWORD" ]; then \
		echo "✗ Не удалось получить пароль из секрета"; \
		exit 1; \
	fi; \
	echo "Восстановление из $(BACKUP_FILE)..."; \
	cat $(BACKUP_FILE) | kubectl exec -i $$POD -n $(NAMESPACE) -- env PGPASSWORD=$$PASSWORD psql -U postgres && \
	echo "✓ Восстановление завершено" || \
		(echo "✗ Ошибка при восстановлении" && exit 1)

