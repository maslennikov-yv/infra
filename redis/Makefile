.PHONY: help \
	images-verify images-pull images-tag images-push images-sync images-save images-load images-sync-from-files images-clean images-clean-files \
	install upgrade uninstall status logs shell app-create \
	check-registry check-updates

# Локальный registry MicroK8s
REGISTRY ?= localhost:32000

# Helm release defaults
NAMESPACE ?= redis
RELEASE ?= redis
CHART_PATH ?= redis
ENV ?= dev
VALUES_FILE ?= values-$(ENV).yaml

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

# Source images (пытаемся скачать из bitnamilegacy; fallback на bitnami)
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
	@echo "  make images-pull            - Скачать все образы (bitnamilegacy -> bitnami fallback)"
	@echo "  make images-tag             - Тегировать образы для $(REGISTRY)/bitnami/*"
	@echo "  make images-push            - Загрузить образы в microk8s registry"
	@echo "  make images-sync            - pull + tag + push"
	@echo "  make images-save            - Сохранить образы в tar (директория $(IMAGES_DIR)/)"
	@echo "  make images-load            - Загрузить образы из tar"
	@echo "  make images-sync-from-files - load + tag + push"
	@echo "  make images-clean           - Удалить локальные docker-образы"
	@echo "  make images-clean-files     - Удалить сохраненные tar"

check-registry:
	@echo "Проверка MicroK8s registry..."
	@curl -fsS http://$(REGISTRY)/v2/ >/dev/null 2>&1 && \
		echo "✓ Registry доступен: http://$(REGISTRY)/v2/" || \
		(echo "✗ Registry недоступен. Убедитесь, что выполнен: microk8s enable registry" && exit 1)

## =========================
## App accounts (per-app isolation)
## =========================

# Usage: make app-create APP=myapp [APP_NS=myapp] [APP_PASSWORD=...]
app-create:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-create APP=myapp)"; exit 1; fi
	@APP_NS=$${APP_NS:-$(APP)}; \
	APP_USER=$${APP_USER:-app_$(APP)}; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-redis}; \
	APP_PASSWORD=$${APP_PASSWORD:-}; \
	if [ -z "$$APP_PASSWORD" ]; then \
		command -v openssl >/dev/null 2>&1 || { echo "✗ openssl не найден (передайте APP_PASSWORD=... или установите openssl)"; exit 1; }; \
		APP_PASSWORD=$$(openssl rand -hex 16); \
	fi; \
	POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE),app.kubernetes.io/name=redis,app.kubernetes.io/component=master -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then echo "✗ Redis master pod не найден в namespace $(NAMESPACE)"; exit 1; fi; \
	SECRET=$$(kubectl get secret -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE),app.kubernetes.io/name=redis -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$SECRET" ]; then echo "✗ Redis secret не найден в namespace $(NAMESPACE)"; exit 1; fi; \
	ADMIN_PASSWORD=$$(kubectl get secret -n $(NAMESPACE) "$$SECRET" -o jsonpath='{.data.redis-password}' 2>/dev/null | base64 -d); \
	if [ -z "$$ADMIN_PASSWORD" ]; then echo "✗ Не удалось получить redis-password из секрета $$SECRET"; exit 1; fi; \
	REDIS_SVC=$$(kubectl get svc -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE),app.kubernetes.io/name=redis,app.kubernetes.io/component=master -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$REDIS_SVC" ]; then echo "✗ Redis master service не найден"; exit 1; fi; \
	REDIS_HOST="$$REDIS_SVC.$(NAMESPACE).svc.cluster.local"; \
	REDIS_PORT=6379; \
	echo "Creating Redis ACL user $$APP_USER (keys: $(APP):*)"; \
	kubectl exec "$$POD" -n $(NAMESPACE) -- bash -ec "\
		redis-cli -a '$$ADMIN_PASSWORD' ACL SETUSER '$$APP_USER' on '>'\"$$APP_PASSWORD\"' ~'$(APP):*' +@all \
			-ACL -CONFIG -SHUTDOWN -MODULE -DEBUG -COMMAND -KEYS -FLUSHALL -FLUSHDB -LATENCY -MEMORY -MONITOR -SAVE -BGSAVE -BGREWRITEAOF \
			-REPLCONF -REPLICAOF -SLAVEOF -SYNC -PSYNC \
	"; \
	echo "Creating Secret $$APP_SECRET_NAME in namespace $$APP_NS"; \
	kubectl create namespace "$$APP_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; \
	kubectl delete secret "$$APP_SECRET_NAME" -n "$$APP_NS" --ignore-not-found >/dev/null; \
	kubectl create secret generic "$$APP_SECRET_NAME" -n "$$APP_NS" \
		--from-literal=REDIS_HOST="$$REDIS_HOST" \
		--from-literal=REDIS_PORT="$$REDIS_PORT" \
		--from-literal=REDIS_USERNAME="$$APP_USER" \
		--from-literal=REDIS_PASSWORD="$$APP_PASSWORD" \
		--from-literal=REDIS_KEY_PREFIX="$(APP):" \
		>/dev/null; \
	echo "✓ Done (Secret: $$APP_NS/$$APP_SECRET_NAME)"

images-verify:
	@echo "Проверка доступности тегов в docker.io/bitnamilegacy..."
	@command -v docker >/dev/null 2>&1 || { echo "✗ docker не установлен"; exit 1; }
	@FAIL=0; \
	for img in docker.io/bitnamilegacy/redis:$(REDIS_TAG) docker.io/bitnamilegacy/redis-sentinel:$(REDIS_SENTINEL_TAG) docker.io/bitnamilegacy/redis-exporter:$(REDIS_EXPORTER_TAG) docker.io/bitnamilegacy/os-shell:$(OS_SHELL_TAG) docker.io/bitnamilegacy/kubectl:$(KUBECTL_TAG); do \
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
	@helm upgrade --install $(RELEASE) ./$(CHART_PATH) --namespace $(NAMESPACE) -f $(VALUES_FILE)

upgrade:
	@echo "Обновление Redis (release $(RELEASE) в namespace $(NAMESPACE))..."
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
	@echo "Загрузка образов (bitnamilegacy -> bitnami fallback)..."
	@if docker pull $(REDIS_IMAGE_SRC) 2>/dev/null; then echo "✓ $(REDIS_IMAGE_SRC)"; else docker pull docker.io/bitnami/redis:$(REDIS_SRC_TAG); docker tag docker.io/bitnami/redis:$(REDIS_SRC_TAG) $(REDIS_IMAGE_SRC); fi
	@if docker pull $(REDIS_SENTINEL_IMAGE_SRC) 2>/dev/null; then echo "✓ $(REDIS_SENTINEL_IMAGE_SRC)"; else docker pull docker.io/bitnami/redis-sentinel:$(REDIS_SENTINEL_SRC_TAG); docker tag docker.io/bitnami/redis-sentinel:$(REDIS_SENTINEL_SRC_TAG) $(REDIS_SENTINEL_IMAGE_SRC); fi
	@if docker pull $(REDIS_EXPORTER_IMAGE_SRC) 2>/dev/null; then echo "✓ $(REDIS_EXPORTER_IMAGE_SRC)"; else docker pull docker.io/bitnami/redis-exporter:$(REDIS_EXPORTER_SRC_TAG); docker tag docker.io/bitnami/redis-exporter:$(REDIS_EXPORTER_SRC_TAG) $(REDIS_EXPORTER_IMAGE_SRC); fi
	@if docker pull $(OS_SHELL_IMAGE_SRC) 2>/dev/null; then echo "✓ $(OS_SHELL_IMAGE_SRC)"; else docker pull docker.io/bitnami/os-shell:$(OS_SHELL_SRC_TAG); docker tag docker.io/bitnami/os-shell:$(OS_SHELL_SRC_TAG) $(OS_SHELL_IMAGE_SRC); fi
	@if docker pull $(KUBECTL_IMAGE_SRC) 2>/dev/null; then echo "✓ $(KUBECTL_IMAGE_SRC)"; else docker pull docker.io/bitnami/kubectl:$(KUBECTL_SRC_TAG); docker tag docker.io/bitnami/kubectl:$(KUBECTL_SRC_TAG) $(KUBECTL_IMAGE_SRC); fi
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

images-save: images-pull
	@echo "Сохранение Docker образов в файлы..."
	@mkdir -p $(IMAGES_DIR)
	@docker save $(REDIS_IMAGE_SRC) -o $(IMAGES_DIR)/redis-$(REDIS_TAG).tar
	@docker save $(REDIS_SENTINEL_IMAGE_SRC) -o $(IMAGES_DIR)/redis-sentinel-$(REDIS_SENTINEL_TAG).tar
	@docker save $(REDIS_EXPORTER_IMAGE_SRC) -o $(IMAGES_DIR)/redis-exporter-$(REDIS_EXPORTER_TAG).tar
	@docker save $(OS_SHELL_IMAGE_SRC) -o $(IMAGES_DIR)/os-shell-$(OS_SHELL_TAG).tar
	@docker save $(KUBECTL_IMAGE_SRC) -o $(IMAGES_DIR)/kubectl-$(KUBECTL_TAG).tar
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

