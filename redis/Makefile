# Используется bash (не dash) — recipe полагаются на `set -o pipefail`.
SHELL := /bin/bash

.PHONY: help \
	images-verify images-pull images-tag images-push images-sync images-save images-load images-sync-from-files images-clean images-clean-files \
	install upgrade uninstall status logs shell app-create app-show-creds app-drop app-verify acl-reconcile \
	backup restore-acl list-backups \
	check-registry check-updates

# Локальный registry MicroK8s
REGISTRY ?= localhost:32000

# Helm release defaults
NAMESPACE ?= redis
RELEASE ?= redis
CHART_PATH ?= redis
ENV ?= local
VALUES_FILE ?= values-$(ENV).yaml

INFRA_ROOT ?= $(abspath $(CURDIR)/..)

# KUBECONFIG: при прямом запуске из каталога сервиса берём из корня репо
# (k8s/config/<ENV>), чтобы kubectl не уходил на ~/.kube/config. Корневой
# Makefile при $(MAKE) -C ... KUBECONFIG=... переопределяет это значение.
KUBECONFIG ?= $(INFRA_ROOT)/k8s/config/$(ENV)
export KUBECONFIG

# Имя и ключ Secret с паролем админа — как в values-*.yaml: auth.existingSecret / auth.existingSecretPasswordKey
REDIS_AUTH_SECRET_NAME ?= redis
REDIS_AUTH_SECRET_PASSWORD_KEY ?= redis-password

# Локальные теги (НЕ latest)
REDIS_TAG ?= 8.4.0
REDIS_SENTINEL_TAG ?= 8.4.0
REDIS_EXPORTER_TAG ?= 1.80.1
OS_SHELL_TAG ?= 12-debian-12-r51
KUBECTL_TAG ?= 1.35.0

# Source-теги для скачивания (НЕ latest). Bitnami сейчас публикует immutable sha256-* теги.
REDIS_SRC_TAG ?= sha256-d92ea14fbdd2fd0e0e3a5f3e657261ba2bd63a1d69d1eda32b1cc3ae6451bc1f
REDIS_SENTINEL_SRC_TAG ?= sha256-4dea9221a23650c63edb623c40e4335b5832099604674a3ce29be0cafcc57e13
REDIS_EXPORTER_SRC_TAG ?= sha256-ba2c6a47fd1dc87bd76755b3bce0bdd58381c940e218b688334626ddc609af4e
OS_SHELL_SRC_TAG ?= 12-debian-12-r51
KUBECTL_SRC_TAG ?= sha256-f79ebae1ff869758d46262ecb417e3526805669a2c61623e74ff6e4cf1d82bca

# Source images (только docker.io/bitnamilegacy)
REDIS_IMAGE_SRC := docker.io/bitnamilegacy/redis:$(REDIS_SRC_TAG)
REDIS_SENTINEL_IMAGE_SRC := docker.io/bitnamilegacy/redis-sentinel:$(REDIS_SENTINEL_SRC_TAG)
REDIS_EXPORTER_IMAGE_SRC := docker.io/bitnamilegacy/redis-exporter:$(REDIS_EXPORTER_SRC_TAG)
OS_SHELL_IMAGE_SRC := docker.io/bitnamilegacy/os-shell:$(OS_SHELL_SRC_TAG)
KUBECTL_IMAGE_SRC := docker.io/bitnamilegacy/kubectl:$(KUBECTL_SRC_TAG)

# Local registry tags (repository как в chart: bitnami/*)
REDIS_IMAGE_LOCAL := $(REGISTRY)/bitnami/redis:$(REDIS_TAG)
REDIS_SENTINEL_IMAGE_LOCAL := $(REGISTRY)/bitnami/redis-sentinel:$(REDIS_SENTINEL_TAG)
REDIS_EXPORTER_IMAGE_LOCAL := $(REGISTRY)/bitnami/redis-exporter:$(REDIS_EXPORTER_TAG)
OS_SHELL_IMAGE_LOCAL := $(REGISTRY)/bitnami/os-shell:$(OS_SHELL_TAG)
KUBECTL_IMAGE_LOCAL := $(REGISTRY)/bitnami/kubectl:$(KUBECTL_TAG)

IMAGES_SRC := $(REDIS_IMAGE_SRC) $(REDIS_SENTINEL_IMAGE_SRC) $(REDIS_EXPORTER_IMAGE_SRC) $(OS_SHELL_IMAGE_SRC) $(KUBECTL_IMAGE_SRC)
IMAGES_LOCAL := $(REDIS_IMAGE_LOCAL) $(REDIS_SENTINEL_IMAGE_LOCAL) $(REDIS_EXPORTER_IMAGE_LOCAL) $(OS_SHELL_IMAGE_LOCAL) $(KUBECTL_IMAGE_LOCAL)

IMAGES_DIR ?= images

help:
	@echo "Доступные команды:"
	@echo ""
	@echo "Helm:"
	@echo "  make install            - Установить Redis в namespace $(NAMESPACE)"
	@echo "  make upgrade            - Обновить Redis"
	@echo "  make uninstall          - Удалить Redis (⚠ удалит release)"
	@echo "  make status             - Показать статус Redis"
	@echo ""
	@echo "Образы (offline / microk8s registry):"
	@echo "  make check-registry         - Проверить доступность registry $(REGISTRY)"
	@echo "  make images-verify          - Проверить доступность тегов в docker.io/bitnamilegacy"
	@echo "  make images-pull            - Скачать все образы (docker.io/bitnamilegacy)"
	@echo "  make images-tag             - Тегировать образы для $(REGISTRY)/bitnami/*"
	@echo "  make images-push            - Загрузить образы в microk8s registry"
	@echo "  make images-sync            - pull + tag + push"
	@echo "  make images-save            - Сохранить образы в tar (директория $(IMAGES_DIR)/)"
	@echo "  make images-load            - Загрузить образы из tar"
	@echo "  make images-sync-from-files - load + tag + push"
	@echo "  make images-clean           - Удалить локальные docker-образы"
	@echo "  make images-clean-files     - Удалить сохраненные tar"
	@echo ""
	@echo "App accounts:"
	@echo "  make app-show-creds APP=myapp [APP_NS=...] — показать креды из Secret app-redis"
	@echo "  make app-create APP=myapp [REDIS_DB=0] — REDIS_DB из CLI; иначе следующий свободный 1..127 по $(APPS_REGISTRY) (yq); без yq — предупреждение и 0"
	@echo "  make app-drop APP=myapp — удалить запись из apps/conf, Secret, реконсилировать ACL (⚠ y/N; SKIP_CONFIRM=1). Ключи по префиксу не удаляются"
	@echo "  make app-verify APP=myapp [APP_NS=...] — smoke: PING + DBSIZE под APP-кредами из Secret"
	@echo "  make acl-reconcile ENV=... — полная реконсилиация ACL из apps/registry+conf (ConfigMap + aclfile + ACL LOAD)"
	@echo ""
	@echo "Бэкапы и восстановление (RDB + ACL):"
	@echo "  make backup              - RDB снимок + ACL LIST + INFO (tar.gz в $(BACKUP_DIR)/)"
	@echo "  make list-backups        - список бэкапов"
	@echo "  make restore-acl BACKUP_FILE=... — применить ACL-пользователей из бэкапа (default не трогается; ⚠ y/N; SKIP_CONFIRM=1)"
	@echo "  Восстановление данных RDB — см. redis/BACKUP.md (scale 0 + замена в PVC)"

check-registry:
	@echo "Проверка MicroK8s registry..."
	@curl -fsS http://$(REGISTRY)/v2/ >/dev/null 2>&1 && \
		echo "✓ Registry доступен: http://$(REGISTRY)/v2/" || \
		(echo "✗ Registry недоступен. Убедитесь, что выполнен: microk8s enable registry" && exit 1)

## =========================
## App accounts (per-app isolation)
## =========================

# Корень репозитория (make -C redis из корня или из redis/)
INFRA_ROOT ?= $(abspath $(CURDIR)/..)
# Поле redis_db для APP задаётся в apps/registry.yaml. Переопределение: APPS_REGISTRY=...
APPS_REGISTRY ?= $(INFRA_ROOT)/apps/registry.yaml
# Логический номер БД Redis (SELECT n). CLI REDIS_DB — приоритет; иначе при наличии merged и yq — scripts/redis-next-db.sh.
# REDIS_DB не задаём через ?= — корневой Makefile передаёт REDIS_DB только при явном REDIS_DB= в вызове.

# Usage: make app-create APP=myapp [REDIS_DB=…] … — пароль только из merged (redis.password).
#
# Этот recipe обновляет per-app состояние (apps/conf, k8s Secret), а кластерный ACL
# применяется через acl-reconcile (полная реконсилиация из apps/registry+conf).
# Если REDIS_SKIP_ACL_RECONCILE=1 — reconcile не вызывается (используется в apps-apply,
# который дёргает reconcile один раз после прохода всех приложений).
app-create:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-create APP=myapp)"; exit 1; fi
	@{ set -euo pipefail; \
	INF="$(INFRA_ROOT)"; REG="$(APPS_REGISTRY)"; \
	MG="$${APPS_MERGED_FILE:-}"; CLEAN_MG=0; \
	if [ -z "$$MG" ]; then MG=$$(mktemp); CLEAN_MG=1; "$$INF/scripts/apps-merge-config.sh" "$$REG" "$$INF" "$(ENV)" >"$$MG"; fi; \
	trap 'if [ "$$CLEAN_MG" = 1 ]; then rm -f "$$MG"; fi' EXIT; \
	APP_NS=$${APP_NS:-$(APP)}; \
	APP_USER=$${APP_USER:-app_$(APP)}; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-redis}; \
	PW_RAW=$$("$$INF/scripts/app-config-get.sh" "$$MG" "$(APP)" redis.password || true); \
	if [ -z "$$PW_RAW" ] || [ "$$PW_RAW" = "null" ]; then echo "✗ Для приложения \"$(APP)\" нет redis.password в merged конфигурации"; exit 1; fi; \
	APP_PASSWORD="$$PW_RAW"; \
	if [ -n "$(REDIS_DB)" ]; then REDIS_DB_VAL="$(REDIS_DB)"; echo "  → REDIS_DB=$$REDIS_DB_VAL (CLI)"; \
	else REDIS_DB_VAL=$$("$$INF/scripts/redis-next-db.sh" "$$MG" "$(APP)") || exit 1; echo "  → REDIS_DB=$$REDIS_DB_VAL (merged)"; fi; \
	case "$$REDIS_DB_VAL" in ''|*[!0-9]*) echo "✗ REDIS_DB должен быть целым числом ≥ 0"; exit 1;; esac; \
	if [ "$$REDIS_DB_VAL" -gt 127 ]; then echo "✗ REDIS_DB не должен превышать 127"; exit 1; fi; \
	REDIS_SVC=$$(kubectl get svc -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE),app.kubernetes.io/name=redis,app.kubernetes.io/component=master -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$REDIS_SVC" ]; then echo "✗ Redis master service не найден"; exit 1; fi; \
	REDIS_HOST="$$REDIS_SVC.$(NAMESPACE).svc.cluster.local"; \
	REDIS_PORT=6379; \
	echo "Creating Secret $$APP_SECRET_NAME in namespace $$APP_NS"; \
	kubectl create namespace "$$APP_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; \
	kubectl delete secret "$$APP_SECRET_NAME" -n "$$APP_NS" --ignore-not-found >/dev/null; \
	kubectl create secret generic "$$APP_SECRET_NAME" -n "$$APP_NS" \
		--from-literal=REDIS_HOST="$$REDIS_HOST" \
		--from-literal=REDIS_PORT="$$REDIS_PORT" \
		--from-literal=REDIS_USERNAME="$$APP_USER" \
		--from-literal=REDIS_PASSWORD="$$APP_PASSWORD" \
		--from-literal=REDIS_KEY_PREFIX="$(APP):" \
		--from-literal=REDIS_DB="$$REDIS_DB_VAL" \
		>/dev/null; \
	printf '%s\n' \
		'redis:' \
		"  password: \"$$APP_PASSWORD\"" \
		"  username: \"$$APP_USER\"" \
		"  redis_db: $$REDIS_DB_VAL" \
		"  key_prefix: \"$(APP):\"" \
		"  host: \"$$REDIS_HOST\"" \
		"  port: $$REDIS_PORT" \
	| "$$INF/scripts/app-conf-set.sh" "$$INF" "$(APP)" "$(ENV)"; \
	if [ "$${REDIS_SKIP_ACL_RECONCILE:-0}" != "1" ]; then \
		APPS_REGISTRY="$$REG" REPO_ROOT="$$INF" ENV="$(ENV)" APPS_MERGED_FILE="$$MG" \
			NAMESPACE="$(NAMESPACE)" RELEASE="$(RELEASE)" \
			REDIS_AUTH_SECRET_NAME="$(REDIS_AUTH_SECRET_NAME)" \
			REDIS_AUTH_SECRET_PASSWORD_KEY="$(REDIS_AUTH_SECRET_PASSWORD_KEY)" \
			"$$INF/scripts/redis-acl-reconcile.sh"; \
	else \
		echo "  (REDIS_SKIP_ACL_RECONCILE=1 — ACL применит agg-reconcile в apps-apply)"; \
	fi; \
	echo "✓ Done (Secret: $$APP_NS/$$APP_SECRET_NAME, REDIS_DB=$$REDIS_DB_VAL)"; \
	}

# Полная реконсилиация ACL в Redis из apps/registry.yaml + apps/conf/<APP>/<ENV>/.
# Источник истины — merged конфиг. Идемпотентно. Используется apps-apply (один вызов
# после прохода всех redis-приложений) и доступно вручную для починки drift.
acl-reconcile:
	@APPS_REGISTRY="$(APPS_REGISTRY)" REPO_ROOT="$(INFRA_ROOT)" ENV="$(ENV)" \
		NAMESPACE="$(NAMESPACE)" RELEASE="$(RELEASE)" \
		REDIS_AUTH_SECRET_NAME="$(REDIS_AUTH_SECRET_NAME)" \
		REDIS_AUTH_SECRET_PASSWORD_KEY="$(REDIS_AUTH_SECRET_PASSWORD_KEY)" \
		"$(INFRA_ROOT)/scripts/redis-acl-reconcile.sh"

# Usage: make app-drop APP=myapp [APP_NS=myapp] [SKIP_CONFIRM=1]
#
# Удаляет per-app состояние: запись redis.* из apps/conf/<APP>/<ENV>/secrets.yaml,
# Secret <APP>-redis в namespace приложения, и реконсилирует ACL в Redis.
# Поскольку запись apps/conf удалена до reconcile, пользователь app_<APP> не попадёт
# в новый users.acl и удалится из памяти (ACL LOAD).
# REDIS_SKIP_ACL_RECONCILE=1 — пропустить reconcile (используется apps-apply при массовом drop).
app-drop:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-drop APP=myapp)"; exit 1; fi
	@{ set -euo pipefail; \
	APP_NS=$${APP_NS:-$(APP)}; \
	APP_USER=$${APP_USER:-app_$(APP)}; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-redis}; \
	if [ "$(SKIP_CONFIRM)" != "1" ]; then \
		echo "⚠ ВНИМАНИЕ: будут удалены запись redis.* из apps/conf/$(APP)/$(ENV)/, Secret \"$$APP_NS/$$APP_SECRET_NAME\" и ACL-пользователь \"$$APP_USER\" в Redis. Ключи с префиксом приложения остаются в Redis до ручной очистки."; \
		read -p "Вы уверены? (y/N): " confirm; \
		if [ "$$confirm" != "y" ] && [ "$$confirm" != "Y" ]; then echo "Отменено."; exit 0; fi; \
	fi; \
	echo "Deleting Secret $$APP_SECRET_NAME in namespace $$APP_NS..."; \
	kubectl delete secret "$$APP_SECRET_NAME" -n "$$APP_NS" --ignore-not-found; \
	"$(INFRA_ROOT)/scripts/app-conf-clear.sh" "$(INFRA_ROOT)" "$(APP)" "$(ENV)" redis || true; \
	if [ "$${REDIS_SKIP_ACL_RECONCILE:-0}" != "1" ]; then \
		APPS_REGISTRY="$(APPS_REGISTRY)" REPO_ROOT="$(INFRA_ROOT)" ENV="$(ENV)" \
			NAMESPACE="$(NAMESPACE)" RELEASE="$(RELEASE)" \
			REDIS_AUTH_SECRET_NAME="$(REDIS_AUTH_SECRET_NAME)" \
			REDIS_AUTH_SECRET_PASSWORD_KEY="$(REDIS_AUTH_SECRET_PASSWORD_KEY)" \
			"$(INFRA_ROOT)/scripts/redis-acl-reconcile.sh"; \
	else \
		echo "  (REDIS_SKIP_ACL_RECONCILE=1 — ACL применит agg-reconcile в apps-apply)"; \
	fi; \
	echo "✓ App-state очищен ($$APP_NS/$$APP_SECRET_NAME, apps/conf/$(APP)/$(ENV)/.redis), ACL реконсилирован"; \
	}

app-show-creds:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-show-creds APP=myapp)"; exit 1; fi
	@APP_NS=$${APP_NS:-$(APP)}; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-redis}; \
	if ! kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" >/dev/null 2>&1; then \
		echo "✗ Secret $$APP_SECRET_NAME не найден в namespace $$APP_NS"; exit 1; \
	fi; \
	echo "Secret: $$APP_NS/$$APP_SECRET_NAME"; \
	echo "---"; \
	echo "REDIS_HOST=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.REDIS_HOST}' 2>/dev/null | base64 -d)"; \
	echo "REDIS_PORT=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.REDIS_PORT}' 2>/dev/null | base64 -d)"; \
	echo "REDIS_USERNAME=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.REDIS_USERNAME}' 2>/dev/null | base64 -d)"; \
	echo "REDIS_PASSWORD=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.REDIS_PASSWORD}' 2>/dev/null | base64 -d)"; \
	echo "REDIS_KEY_PREFIX=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.REDIS_KEY_PREFIX}' 2>/dev/null | base64 -d)"; \
	echo "REDIS_DB=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.REDIS_DB}' 2>/dev/null | base64 -d)"; \
	echo "Изоляция: ACL по префиксу REDIS_KEY_PREFIX; REDIS_DB — логический номер БД (не отдельный сервер и не аналог отдельной БД Postgres)."

# Usage: make app-verify APP=myapp — smoke-тест: PING + DBSIZE под APP-кредами.
app-verify:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-verify APP=myapp)"; exit 1; fi
	@APP_NS=$${APP_NS:-$(APP)}; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-redis}; \
	if ! kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" >/dev/null 2>&1; then \
		echo "✗ Secret $$APP_SECRET_NAME не найден в namespace $$APP_NS"; exit 1; \
	fi; \
	APP_USER=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.REDIS_USERNAME}' | base64 -d); \
	APP_PASSWORD=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.REDIS_PASSWORD}' | base64 -d); \
	REDIS_DB_VAL=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.REDIS_DB}' | base64 -d); \
	REDIS_DB_VAL=$${REDIS_DB_VAL:-0}; \
	if [ -z "$$APP_USER" ] || [ -z "$$APP_PASSWORD" ]; then echo "✗ В Secret отсутствуют REDIS_USERNAME/REDIS_PASSWORD"; exit 1; fi; \
	POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE),app.kubernetes.io/name=redis,app.kubernetes.io/component=master -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then echo "✗ Redis master pod не найден в namespace $(NAMESPACE)"; exit 1; fi; \
	echo "Проверка $$APP_USER (db=$$REDIS_DB_VAL)..."; \
	OUT=$$(kubectl exec "$$POD" -n $(NAMESPACE) -- env REDISCLI_AUTH="$$APP_PASSWORD" sh -c \
		'redis-cli --user "$$1" --no-auth-warning -n "$$2" PING' \
		sh "$$APP_USER" "$$REDIS_DB_VAL" 2>&1) || { echo "✗ PING не удался: $$OUT"; exit 1; }; \
	if ! echo "$$OUT" | grep -q PONG; then echo "✗ PING ответил: $$OUT"; exit 1; fi; \
	SIZE=$$(kubectl exec "$$POD" -n $(NAMESPACE) -- env REDISCLI_AUTH="$$APP_PASSWORD" sh -c \
		'redis-cli --user "$$1" --no-auth-warning -n "$$2" DBSIZE' \
		sh "$$APP_USER" "$$REDIS_DB_VAL" 2>&1) || { echo "✗ DBSIZE не удался: $$SIZE"; exit 1; }; \
	echo "✓ PING=PONG; DBSIZE=$$SIZE (db=$$REDIS_DB_VAL)"

images-verify:
	@# Проверяем именно SRC-теги (то, что реально подаётся в `docker pull`),
	@# а не локальные перетегированные значения REDIS_TAG/REDIS_SENTINEL_TAG/...:
	@# в `bitnamilegacy` mutable-теги уже выпиливают, остаются immutable sha256-* —
	@# поэтому проверяем то же, что и images-pull.
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
	@echo "Проверка обновлений для Redis..."
	@echo ""
	@CURRENT_CHART=$$(grep '^version:' $(CHART_PATH)/Chart.yaml | awk '{print $$2}'); \
	CURRENT_APP=$$(grep '^appVersion:' $(CHART_PATH)/Chart.yaml | awk '{print $$2}'); \
	echo "Текущая версия чарта: $$CURRENT_CHART (appVersion: $$CURRENT_APP)"; \
	echo "Текущие теги образов: redis:$(REDIS_TAG), redis-sentinel:$(REDIS_SENTINEL_TAG), redis-exporter:$(REDIS_EXPORTER_TAG), os-shell:$(OS_SHELL_TAG), kubectl:$(KUBECTL_TAG)"; \
	echo ""; \
	echo "Проверка доступных версий чарта..."; \
	if command -v helm >/dev/null 2>&1; then \
		if ! helm repo list 2>/dev/null | grep -q bitnami; then \
			echo "  Добавляю репозиторий bitnami..."; \
			helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true; \
			helm repo update >/dev/null 2>&1 || true; \
		fi; \
		echo "  Поиск последней версии чарта..."; \
		LATEST_CHART=$$(helm search repo bitnami/redis --versions --output json 2>/dev/null | jq -r '.[0].version' 2>/dev/null || helm search repo bitnami/redis --versions 2>/dev/null | head -2 | tail -1 | awk '{print $$2}' || echo ""); \
		if [ -n "$$LATEST_CHART" ] && [ "$$LATEST_CHART" != "$$CURRENT_CHART" ]; then \
			echo "  ⚠ Доступна новая версия чарта: $$LATEST_CHART"; \
			echo "  Для проверки образов новой версии выполните:"; \
			echo "    helm show chart bitnami/redis --version $$LATEST_CHART | grep -A 10 '^annotations:'"; \
		elif [ -n "$$LATEST_CHART" ]; then \
			echo "  ✓ Используется последняя версия чарта: $$CURRENT_CHART"; \
		else \
			echo "  ⚠ Не удалось получить версию чарта"; \
		fi; \
	else \
		echo "  ⚠ helm не установлен, проверка версий чарта пропущена"; \
		echo "  Альтернатива: проверьте https://github.com/bitnami/charts/tree/main/bitnami/redis"; \
	fi; \
	echo ""; \
	echo "Примечание: После обновления чарта проверьте теги образов в Chart.yaml новой версии"

install:
	@echo "Установка Redis в namespace $(NAMESPACE)..."
	@kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	@# values-*.yaml ссылаются на existingSecret: $(REDIS_AUTH_SECRET_NAME).
	@# При первом разворачивании Secret отсутствует — генерируем случайный пароль.
	@# В корневой цели `make up` логика та же (см. корневой Makefile, блок `up:` для redis).
	@if ! kubectl get secret -n $(NAMESPACE) $(REDIS_AUTH_SECRET_NAME) >/dev/null 2>&1; then \
		echo "Secret $(NAMESPACE)/$(REDIS_AUTH_SECRET_NAME) отсутствует — создаю с новым паролем..."; \
		command -v openssl >/dev/null 2>&1 || { echo "✗ openssl не найден (нужен для генерации пароля)"; exit 1; }; \
		REDIS_PASSWORD=$$(openssl rand -hex 16); \
		kubectl create secret generic $(REDIS_AUTH_SECRET_NAME) -n $(NAMESPACE) \
			--from-literal=$(REDIS_AUTH_SECRET_PASSWORD_KEY)="$$REDIS_PASSWORD" >/dev/null; \
		echo "✓ Secret $(NAMESPACE)/$(REDIS_AUTH_SECRET_NAME) создан"; \
	fi
	@# Bitnami chart с auth.acl.enabled рендерит users.acl и требует пароль admin'а
	@# через --set global.redis.password (так же делает helmfile.yaml.gotmpl).
	@PASSWORD=$$(kubectl get secret -n $(NAMESPACE) $(REDIS_AUTH_SECRET_NAME) -o jsonpath="{.data['$(REDIS_AUTH_SECRET_PASSWORD_KEY)']}" 2>/dev/null | base64 -d); \
	if [ -z "$$PASSWORD" ]; then echo "✗ Не удалось прочитать пароль из Secret $(NAMESPACE)/$(REDIS_AUTH_SECRET_NAME)"; exit 1; fi; \
	helm upgrade --install $(RELEASE) ./$(CHART_PATH) --namespace $(NAMESPACE) -f $(VALUES_FILE) --set global.redis.password="$$PASSWORD"

upgrade:
	@echo "Обновление Redis (release $(RELEASE) в namespace $(NAMESPACE))..."
	@# Так же, как в install: Bitnami chart с auth.acl.enabled рендерит users.acl
	@# и требует пароль admin'а через --set global.redis.password (helmfile делает то же).
	@PASSWORD=$$(kubectl get secret -n $(NAMESPACE) $(REDIS_AUTH_SECRET_NAME) -o jsonpath="{.data['$(REDIS_AUTH_SECRET_PASSWORD_KEY)']}" 2>/dev/null | base64 -d); \
	if [ -z "$$PASSWORD" ]; then echo "✗ Secret $(NAMESPACE)/$(REDIS_AUTH_SECRET_NAME) не найден или пуст. Сначала: make install"; exit 1; fi; \
	helm upgrade --install $(RELEASE) ./$(CHART_PATH) --namespace $(NAMESPACE) -f $(VALUES_FILE) --set global.redis.password="$$PASSWORD"

uninstall:
	@echo "⚠ ВНИМАНИЕ: Это удалит Helm release $(RELEASE)!"
	@read -p "Вы уверены? (y/N): " confirm && \
		if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
			helm uninstall $(RELEASE) --namespace $(NAMESPACE) || echo "Helm release не найден"; \
		else \
			echo "Отменено."; \
			exit 0; \
		fi

status:
	@echo "=== Статус Helm release ==="
	@helm status $(RELEASE) --namespace $(NAMESPACE) 2>/dev/null || echo "Helm release не найден"
	@echo ""
	@echo "=== Поды ==="
	@kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/name=redis 2>/dev/null || echo "Поды не найдены"
	@echo ""
	@echo "=== Сервисы ==="
	@kubectl get svc -n $(NAMESPACE) -l app.kubernetes.io/name=redis 2>/dev/null || echo "Сервисы не найдены"
	@echo ""
	@echo "=== PVC ==="
	@kubectl get pvc -n $(NAMESPACE) 2>/dev/null | grep -v "No resources" || echo "PVC не найдены"

logs:
	@POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/name=redis -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then \
		echo "Поды Redis не найдены"; \
	else \
		echo "Логи пода: $$POD"; \
		kubectl logs -f $$POD -n $(NAMESPACE); \
	fi

shell:
	@POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/name=redis -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then \
		echo "Поды Redis не найдены"; \
		exit 1; \
	else \
		echo "Подключение к поду: $$POD"; \
		kubectl exec -it $$POD -n $(NAMESPACE) -- bash || kubectl exec -it $$POD -n $(NAMESPACE) -- sh; \
	fi

images-pull:
	@echo "Загрузка образов из docker.io/bitnamilegacy..."
	@docker pull $(REDIS_IMAGE_SRC)
	@docker pull $(REDIS_SENTINEL_IMAGE_SRC)
	@docker pull $(REDIS_EXPORTER_IMAGE_SRC)
	@docker pull $(OS_SHELL_IMAGE_SRC)
	@docker pull $(KUBECTL_IMAGE_SRC)
	@echo "✓ Все образы загружены"

images-tag: images-pull
	@echo "Тегирование образов для $(REGISTRY)/bitnami/* ..."
	@docker tag $(REDIS_IMAGE_SRC) $(REDIS_IMAGE_LOCAL)
	@docker tag $(REDIS_SENTINEL_IMAGE_SRC) $(REDIS_SENTINEL_IMAGE_LOCAL)
	@docker tag $(REDIS_EXPORTER_IMAGE_SRC) $(REDIS_EXPORTER_IMAGE_LOCAL)
	@docker tag $(OS_SHELL_IMAGE_SRC) $(OS_SHELL_IMAGE_LOCAL)
	@docker tag $(KUBECTL_IMAGE_SRC) $(KUBECTL_IMAGE_LOCAL)
	@echo "✓ Теги готовы"

images-push: check-registry images-tag
	@echo "Публикация образов в registry $(REGISTRY)..."
	@docker push $(REDIS_IMAGE_LOCAL)
	@docker push $(REDIS_SENTINEL_IMAGE_LOCAL)
	@docker push $(REDIS_EXPORTER_IMAGE_LOCAL)
	@docker push $(OS_SHELL_IMAGE_LOCAL)
	@docker push $(KUBECTL_IMAGE_LOCAL)
	@echo "✓ Все образы опубликованы"

images-sync: images-push
	@echo "✓ Images sync completed"

images-save: images-tag
	@echo "Сохранение Docker образов в файлы (с LOCAL-тегом $(REGISTRY)/bitnami/*)..."
	@mkdir -p $(IMAGES_DIR)
	@docker save $(REDIS_IMAGE_LOCAL) -o $(IMAGES_DIR)/redis-$(REDIS_TAG).tar
	@docker save $(REDIS_SENTINEL_IMAGE_LOCAL) -o $(IMAGES_DIR)/redis-sentinel-$(REDIS_SENTINEL_TAG).tar
	@docker save $(REDIS_EXPORTER_IMAGE_LOCAL) -o $(IMAGES_DIR)/redis-exporter-$(REDIS_EXPORTER_TAG).tar
	@docker save $(OS_SHELL_IMAGE_LOCAL) -o $(IMAGES_DIR)/os-shell-$(OS_SHELL_TAG).tar
	@docker save $(KUBECTL_IMAGE_LOCAL) -o $(IMAGES_DIR)/kubectl-$(KUBECTL_TAG).tar
	@echo "✓ Образы сохранены в $(IMAGES_DIR)/"

images-load:
	@echo "Загрузка Docker образов из файлов..."
	@if [ ! -d "$(IMAGES_DIR)" ]; then echo "✗ Директория $(IMAGES_DIR) не найдена"; exit 1; fi
	@for file in $(IMAGES_DIR)/*.tar; do \
		if [ -f "$$file" ]; then \
			echo "docker load -i $$file"; \
			docker load -i $$file; \
		fi; \
	done
	@echo "✓ Образы загружены из $(IMAGES_DIR)/"

images-sync-from-files: check-registry images-load
	@$(MAKE) images-tag
	@$(MAKE) images-push

images-clean:
	@echo "Удаление локальных образов..."
	-@docker rmi $(IMAGES_LOCAL) 2>/dev/null || true
	-@docker rmi $(IMAGES_SRC) 2>/dev/null || true
	@echo "✓ Локальные образы удалены"

images-clean-files:
	@echo "Удаление сохраненных файлов образов..."
	@if [ -d "$(IMAGES_DIR)" ]; then rm -f $(IMAGES_DIR)/*.tar 2>/dev/null || true; fi
	@echo "✓ Файлы образов удалены"

## =========================
## Backup / Restore (RDB + ACL)
## =========================
BACKUP_DIR ?= backups/$(ENV)

# Полный бэкап definitions: RDB снимок (через replication protocol — независимо от persistence config),
# ACL LIST и INFO server. Упаковывается в один tar.gz.
backup:
	@mkdir -p $(BACKUP_DIR)
	@set -eo pipefail; \
	TS=$$(date +%Y%m%d-%H%M%S)-$$$$; \
	OUT="$(BACKUP_DIR)/redis-backup-$$TS.tar.gz"; \
	echo "Создание бэкапа Redis в $$OUT..."; \
	POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE),app.kubernetes.io/name=redis,app.kubernetes.io/component=master -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then echo "✗ Redis master pod не найден в namespace $(NAMESPACE)"; exit 1; fi; \
	if ! kubectl get secret $(REDIS_AUTH_SECRET_NAME) -n $(NAMESPACE) >/dev/null 2>&1; then \
		echo "✗ Secret $(REDIS_AUTH_SECRET_NAME) не найден"; exit 1; \
	fi; \
	PASSWORD=$$(kubectl get secret -n $(NAMESPACE) $(REDIS_AUTH_SECRET_NAME) -o jsonpath="{.data['$(REDIS_AUTH_SECRET_PASSWORD_KEY)']}" 2>/dev/null | base64 -d); \
	if [ -z "$$PASSWORD" ]; then echo "✗ Не удалось прочитать пароль админа Redis"; exit 1; fi; \
	TMP=$$(mktemp -d); trap 'rm -rf "$$TMP"' EXIT INT TERM; \
	echo "  Создаю RDB снимок..."; \
	kubectl exec "$$POD" -n $(NAMESPACE) -- env REDISCLI_AUTH="$$PASSWORD" \
		redis-cli --no-auth-warning --rdb /tmp/redis-backup.rdb >/dev/null; \
	# `kubectl exec ... cat > local` устойчивее к большим файлам, чем `kubectl cp` \
	# (последний под капотом гоняет tar и известен подвисаниями/обрезанием на >1GB). \
	kubectl exec "$$POD" -n $(NAMESPACE) -- cat /tmp/redis-backup.rdb > "$$TMP/dump.rdb"; \
	kubectl exec "$$POD" -n $(NAMESPACE) -- rm -f /tmp/redis-backup.rdb >/dev/null 2>&1 || true; \
	[ -s "$$TMP/dump.rdb" ] || { echo "✗ dump.rdb пуст или не скопирован"; exit 1; }; \
	echo "  Экспорт ACL..."; \
	kubectl exec "$$POD" -n $(NAMESPACE) -- env REDISCLI_AUTH="$$PASSWORD" \
		redis-cli --no-auth-warning ACL LIST > "$$TMP/users.acl"; \
	[ -s "$$TMP/users.acl" ] || { echo "✗ users.acl пуст (ACL LIST не вернул ни одной строки)"; exit 1; }; \
	echo "  Сбор INFO server (debug-only, при restore не используется)..."; \
	kubectl exec "$$POD" -n $(NAMESPACE) -- env REDISCLI_AUTH="$$PASSWORD" \
		redis-cli --no-auth-warning INFO server > "$$TMP/info.txt"; \
	tar -czf "$$OUT" -C "$$TMP" dump.rdb users.acl info.txt; \
	SIZE=$$(du -h --apparent-size "$$OUT" | cut -f1); \
	echo "✓ Бэкап создан: $$OUT ($$SIZE)"

list-backups:
	@echo "Список бэкапов Redis в $(BACKUP_DIR):"
	@if [ -d "$(BACKUP_DIR)" ]; then \
		ls -lht "$(BACKUP_DIR)"/redis-backup-*.tar.gz 2>/dev/null | awk '{print $$9, "(" $$5, $$6, $$7, $$8 ")"}' || echo "  Бэкапы не найдены"; \
	else \
		echo "  Директория $(BACKUP_DIR) не существует"; \
	fi

# Возврат ACL-пользователей из бэкапа в живой Redis (default не трогается).
# Восстановление RDB-данных — отдельная процедура, см. redis/BACKUP.md.
restore-acl:
	@if [ -z "$(BACKUP_FILE)" ]; then \
		echo "✗ Укажите файл: make restore-acl BACKUP_FILE=$(BACKUP_DIR)/redis-backup-YYYYMMDD-HHMMSS.tar.gz"; \
		exit 1; \
	fi
	@if [ ! -f "$(BACKUP_FILE)" ]; then echo "✗ Файл $(BACKUP_FILE) не найден"; exit 1; fi
	@if [ "$(SKIP_CONFIRM)" != "1" ]; then \
		echo "⚠ Будут применены ACL-пользователи из $(BACKUP_FILE) (default user не трогается)."; \
		read -p "Продолжить? (y/N): " confirm; \
		if [ "$$confirm" != "y" ] && [ "$$confirm" != "Y" ]; then echo "Отменено."; exit 0; fi; \
	fi
	@set -eo pipefail; \
	POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE),app.kubernetes.io/name=redis,app.kubernetes.io/component=master -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then echo "✗ Redis master pod не найден"; exit 1; fi; \
	PASSWORD=$$(kubectl get secret -n $(NAMESPACE) $(REDIS_AUTH_SECRET_NAME) -o jsonpath="{.data['$(REDIS_AUTH_SECRET_PASSWORD_KEY)']}" 2>/dev/null | base64 -d); \
	if [ -z "$$PASSWORD" ]; then echo "✗ Не удалось прочитать пароль админа Redis"; exit 1; fi; \
	TMP=$$(mktemp -d); trap 'rm -rf "$$TMP"' EXIT INT TERM; \
	tar -xzf "$(BACKUP_FILE)" -C "$$TMP"; \
	if [ ! -s "$$TMP/users.acl" ]; then echo "✗ В архиве нет users.acl"; exit 1; fi; \
	APPLIED=0; FAILED=0; SKIPPED=0; \
	while IFS= read -r line; do \
		[ -z "$$line" ] && continue; \
		# bash read -ra разбивает строку по whitespace (IFS) без интерпретации \
		# $VAR/backquotes/escape sequences. Argv для redis-cli передаём как массив, \
		# минуя `sh -c` внутри пода — это устраняет shell-инъекции из users.acl. \
		read -ra ARGV <<< "$$line"; \
		USER_NAME=$${ARGV[1]}; \
		if [ "$$USER_NAME" = "default" ]; then SKIPPED=$$((SKIPPED+1)); continue; fi; \
		if kubectl exec "$$POD" -n $(NAMESPACE) -- env REDISCLI_AUTH="$$PASSWORD" \
			redis-cli --no-auth-warning ACL SETUSER -- "$${ARGV[@]:1}" >/dev/null; then \
			APPLIED=$$((APPLIED+1)); \
		else \
			echo "  ⚠ Не удалось применить пользователя $$USER_NAME"; \
			FAILED=$$((FAILED+1)); \
		fi; \
	done < "$$TMP/users.acl"; \
	echo "✓ Применено: $$APPLIED, ошибок: $$FAILED, пропущено (default): $$SKIPPED"

