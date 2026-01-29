.PHONY: help \
	images-verify images-pull images-tag images-push images-sync images-save images-load images-sync-from-files images-clean images-clean-files \
	install upgrade uninstall status logs shell app-create \
	check-registry check-updates

# Локальный registry MicroK8s
REGISTRY ?= localhost:32000

# Helm release defaults
NAMESPACE ?= clickhouse
RELEASE ?= clickhouse
CHART_PATH ?= clickhouse
ENV ?= dev
VALUES_FILE ?= values-$(ENV).yaml

# Image tags pinned from chart values.yaml
CLICKHOUSE_TAG ?= 25.7.5-debian-12-r0
CLICKHOUSE_KEEPER_TAG ?= 25.7.5-debian-12-r0
OS_SHELL_TAG ?= 12-debian-12-r51

# Source tags (can override)
CLICKHOUSE_SRC_TAG ?= $(CLICKHOUSE_TAG)
CLICKHOUSE_KEEPER_SRC_TAG ?= $(CLICKHOUSE_KEEPER_TAG)
OS_SHELL_SRC_TAG ?= $(OS_SHELL_TAG)

# Source images (bitnamilegacy -> bitnami fallback)
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

check-registry:
	@echo "Проверка MicroK8s registry..."
	@curl -fsS http://$(REGISTRY)/v2/ >/dev/null 2>&1 && \
		echo "✓ Registry доступен: http://$(REGISTRY)/v2/" || \
		(echo "✗ Registry недоступен. Убедитесь, что выполнен: microk8s enable registry" && exit 1)

## =========================
## App accounts (per-app isolation)
## =========================

# Usage: make app-create APP=myapp [APP_NS=myapp] [DB=myapp] [APP_USER=app_myapp] [APP_PASSWORD=...]
app-create:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-create APP=myapp)"; exit 1; fi
	@APP_NS=$${APP_NS:-$(APP)}; \
	DB=$${DB:-$(APP)}; \
	APP_USER=$${APP_USER:-app_$(APP)}; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-clickhouse}; \
	APP_PASSWORD=$${APP_PASSWORD:-}; \
	ADMIN_USER=$${ADMIN_USER:-admin}; \
	if [ -z "$$APP_PASSWORD" ]; then \
		command -v openssl >/dev/null 2>&1 || { echo "✗ openssl не найден (передайте APP_PASSWORD=... или установите openssl)"; exit 1; }; \
		APP_PASSWORD=$$(openssl rand -hex 16); \
	fi; \
	ADMIN_PASSWORD=$$(kubectl get secret -n $(NAMESPACE) $(RELEASE) -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d); \
	if [ -z "$$ADMIN_PASSWORD" ]; then echo "✗ Не удалось получить admin-password из секрета $(RELEASE) в namespace $(NAMESPACE)"; exit 1; fi; \
	CH_HOST="$(RELEASE).$(NAMESPACE).svc.cluster.local"; \
	CH_PORT=9000; \
	CH_HTTP_PORT=8123; \
	echo "Creating ClickHouse user $$APP_USER and DB $$DB"; \
	kubectl run clickhouse-admin-$$(date +%s) \
		--restart='Never' \
		--image=$(CLICKHOUSE_IMAGE_LOCAL) \
		--namespace=$(NAMESPACE) \
		--rm -i \
		--command -- sh -ec "\
			clickhouse-client --host $$CH_HOST --port $$CH_PORT \
			  --user \"$$ADMIN_USER\" --password \"$$ADMIN_PASSWORD\" \
			  --multiquery --query \"CREATE DATABASE IF NOT EXISTS \\\"$$DB\\\"; \
CREATE USER IF NOT EXISTS \\\"$$APP_USER\\\" IDENTIFIED WITH sha256_password BY '$$APP_PASSWORD'; \
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
	echo "✓ Done (Secret: $$APP_NS/$$APP_SECRET_NAME)"

images-verify:
	@echo "Проверка доступности тегов в docker.io/bitnamilegacy..."
	@command -v docker >/dev/null 2>&1 || { echo "✗ docker не установлен"; exit 1; }
	@FAIL=0; \
	for img in docker.io/bitnamilegacy/clickhouse:$(CLICKHOUSE_TAG) docker.io/bitnamilegacy/clickhouse-keeper:$(CLICKHOUSE_KEEPER_TAG) docker.io/bitnamilegacy/os-shell:$(OS_SHELL_TAG); do \
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
	@helm uninstall $(RELEASE) --namespace $(NAMESPACE) || true

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
	@echo "Загрузка образов (bitnamilegacy -> bitnami fallback)..."
	@if docker pull $(CLICKHOUSE_IMAGE_SRC) 2>/dev/null; then echo "✓ $(CLICKHOUSE_IMAGE_SRC)"; else docker pull docker.io/bitnami/clickhouse:$(CLICKHOUSE_SRC_TAG); docker tag docker.io/bitnami/clickhouse:$(CLICKHOUSE_SRC_TAG) $(CLICKHOUSE_IMAGE_SRC); fi
	@if docker pull $(CLICKHOUSE_KEEPER_IMAGE_SRC) 2>/dev/null; then echo "✓ $(CLICKHOUSE_KEEPER_IMAGE_SRC)"; else docker pull docker.io/bitnami/clickhouse-keeper:$(CLICKHOUSE_KEEPER_SRC_TAG); docker tag docker.io/bitnami/clickhouse-keeper:$(CLICKHOUSE_KEEPER_SRC_TAG) $(CLICKHOUSE_KEEPER_IMAGE_SRC); fi
	@if docker pull $(OS_SHELL_IMAGE_SRC) 2>/dev/null; then echo "✓ $(OS_SHELL_IMAGE_SRC)"; else docker pull docker.io/bitnami/os-shell:$(OS_SHELL_SRC_TAG); docker tag docker.io/bitnami/os-shell:$(OS_SHELL_SRC_TAG) $(OS_SHELL_IMAGE_SRC); fi
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

images-save: images-pull
	@mkdir -p $(IMAGES_DIR)
	@docker save $(CLICKHOUSE_IMAGE_SRC) -o $(IMAGES_DIR)/clickhouse-$(CLICKHOUSE_TAG).tar
	@docker save $(CLICKHOUSE_KEEPER_IMAGE_SRC) -o $(IMAGES_DIR)/clickhouse-keeper-$(CLICKHOUSE_KEEPER_TAG).tar
	@docker save $(OS_SHELL_IMAGE_SRC) -o $(IMAGES_DIR)/os-shell-$(OS_SHELL_TAG).tar

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
