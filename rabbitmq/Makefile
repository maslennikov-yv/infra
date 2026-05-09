# Используется bash (не dash) — recipe полагаются на read -p и set -o pipefail.
SHELL := /bin/bash

.PHONY: help \
	images-verify images-pull images-tag images-push images-sync images-save images-load images-sync-from-files images-clean images-clean-files \
	install upgrade uninstall status logs shell app-create app-show-creds app-drop app-verify \
	backup-defs restore-defs list-backups \
	check-registry check-updates

# Локальный registry MicroK8s
REGISTRY ?= localhost:32000

# Helm release defaults
NAMESPACE ?= rabbitmq
RELEASE ?= rabbitmq
CHART_PATH ?= rabbitmq
ENV ?= local
VALUES_FILE ?= values-$(ENV).yaml

INFRA_ROOT ?= $(abspath $(CURDIR)/..)
APPS_REGISTRY ?= $(INFRA_ROOT)/apps/registry.yaml

# Secret used by the chart (auth.existingPasswordSecret / auth.existingErlangSecret)
RABBITMQ_SECRET_NAME ?= rabbitmq

# Image tags pinned from chart values.yaml
RABBITMQ_TAG ?= 4.1.3-debian-12-r1
OS_SHELL_TAG ?= 12-debian-12-r50

# Source tags (can override)
RABBITMQ_SRC_TAG ?= $(RABBITMQ_TAG)
OS_SHELL_SRC_TAG ?= $(OS_SHELL_TAG)

# Source images (только docker.io/bitnamilegacy)
RABBITMQ_IMAGE_SRC := docker.io/bitnamilegacy/rabbitmq:$(RABBITMQ_SRC_TAG)
OS_SHELL_IMAGE_SRC := docker.io/bitnamilegacy/os-shell:$(OS_SHELL_SRC_TAG)

# Local registry tags (repository as in chart)
RABBITMQ_IMAGE_LOCAL := $(REGISTRY)/bitnami/rabbitmq:$(RABBITMQ_TAG)
OS_SHELL_IMAGE_LOCAL := $(REGISTRY)/bitnami/os-shell:$(OS_SHELL_TAG)

IMAGES_SRC := $(RABBITMQ_IMAGE_SRC) $(OS_SHELL_IMAGE_SRC)
IMAGES_LOCAL := $(RABBITMQ_IMAGE_LOCAL) $(OS_SHELL_IMAGE_LOCAL)

IMAGES_DIR ?= images

help:
	@echo "RabbitMQ"
	@echo ""
	@echo "Helm:"
	@echo "  make install            - Установить RabbitMQ в namespace $(NAMESPACE)"
	@echo "  make upgrade            - Обновить RabbitMQ"
	@echo "  make uninstall          - Удалить RabbitMQ (⚠ удалит release)"
	@echo "  make status             - Показать статус RabbitMQ"
	@echo ""
	@echo "Images:"
	@echo "  make images-verify       - проверить доступность тегов в docker.io/bitnamilegacy"
	@echo "  make images-save         - Скачать и сохранить tar"
	@echo "  make images-sync-from-files - docker load + tag + push в $(REGISTRY)"
	@echo ""
	@echo "App accounts:"
	@echo "  make app-create APP=myapp [APP_NS=myapp] [APP_VHOST=myapp] [APP_USER=app_myapp]"
	@echo "  make app-show-creds APP=myapp [APP_NS=myapp] — креды из Secret приложения (APP-rabbitmq)"
	@echo "  make app-drop APP=myapp — удалить vhost, пользователя RabbitMQ и Secret (⚠ y/N; SKIP_CONFIRM=1)"
	@echo "  make app-verify APP=myapp [APP_NS=...] — smoke: authenticate_user + проверка permissions на vhost"
	@echo ""
	@echo "Backup / Restore (definitions: vhosts + users + permissions + exchanges + queues + bindings + policies):"
	@echo "  make backup-defs              - export_definitions в JSON.gz (сообщения НЕ бэкапятся)"
	@echo "  make restore-defs BACKUP_FILE=... - import_definitions (idempotent merge; ⚠ y/N; SKIP_CONFIRM=1)"
	@echo "  make list-backups             - список бэкапов definitions"

check-registry:
	@echo "Проверка MicroK8s registry..."
	@curl -fsS http://$(REGISTRY)/v2/ >/dev/null 2>&1 && \
		echo "✓ Registry доступен: http://$(REGISTRY)/v2/" || \
		(echo "✗ Registry недоступен. Убедитесь, что выполнен: microk8s enable registry" && exit 1)

## =========================
## App accounts (per-app isolation)
## =========================

# Usage: make app-create APP=myapp — пароль только из merged (rabbitmq.password).
app-create:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-create APP=myapp)"; exit 1; fi
	@{ set -euo pipefail; \
	INF="$(INFRA_ROOT)"; REG="$(APPS_REGISTRY)"; \
	MG="$${APPS_MERGED_FILE:-}"; CLEAN_MG=0; \
	if [ -z "$$MG" ]; then MG=$$(mktemp); CLEAN_MG=1; "$$INF/scripts/apps-merge-config.sh" "$$REG" "$$INF" >"$$MG"; fi; \
	trap 'if [ "$$CLEAN_MG" = 1 ]; then rm -f "$$MG"; fi' EXIT; \
	APP_NS=$${APP_NS:-$(APP)}; \
	APP_VHOST=$${APP_VHOST:-$(APP)}; \
	APP_USER=$${APP_USER:-app_$(APP)}; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-rabbitmq}; \
	PW_RAW=$$("$$INF/scripts/app-config-get.sh" "$$MG" "$(APP)" rabbitmq.password || true); \
	if [ -z "$$PW_RAW" ] || [ "$$PW_RAW" = "null" ]; then echo "✗ Для приложения \"$(APP)\" нет rabbitmq.password в merged"; exit 1; fi; \
	APP_PASSWORD="$$PW_RAW"; \
	POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE),app.kubernetes.io/name=rabbitmq -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then echo "✗ RabbitMQ pod не найден"; exit 1; fi; \
	ADMIN_PASSWORD=$$(kubectl get secret -n $(NAMESPACE) $(RABBITMQ_SECRET_NAME) -o jsonpath='{.data.rabbitmq-password}' 2>/dev/null | base64 -d); \
	if [ -z "$$ADMIN_PASSWORD" ]; then echo "✗ Не удалось получить rabbitmq-password"; exit 1; fi; \
	RMQ_HOST="$(RELEASE).$(NAMESPACE).svc.cluster.local"; \
	RMQ_PORT=5672; \
	RMQ_MGMT_PORT=15672; \
	echo "Creating vhost $$APP_VHOST and user $$APP_USER"; \
	: "Передаём vhost/user/password в pod через positional argv (\$$1/\$$2/\$$3),"; \
	: "не через shell-string interp в bash -ec — пароль с '/'/\$$/backquote не ломает парсер."; \
	kubectl exec -i "$$POD" -n $(NAMESPACE) -- bash -c ' \
		set -e; \
		vhost="$$1"; user="$$2"; password="$$3"; \
		rabbitmqctl list_vhosts -q | grep -Fx "$$vhost" >/dev/null || rabbitmqctl add_vhost "$$vhost"; \
		if rabbitmqctl list_users -q | awk "{print \$$1}" | grep -Fx "$$user" >/dev/null; then \
			rabbitmqctl change_password "$$user" "$$password"; \
		else \
			rabbitmqctl add_user "$$user" "$$password"; \
		fi; \
		rabbitmqctl set_permissions -p "$$vhost" "$$user" ".*" ".*" ".*"; \
	' bash "$$APP_VHOST" "$$APP_USER" "$$APP_PASSWORD"; \
	echo "Creating Secret $$APP_SECRET_NAME in namespace $$APP_NS"; \
	AMQP_URL="amqp://$${APP_USER}:$${APP_PASSWORD}@$$RMQ_HOST:$$RMQ_PORT/$$APP_VHOST"; \
	kubectl create namespace "$$APP_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; \
	kubectl delete secret "$$APP_SECRET_NAME" -n "$$APP_NS" --ignore-not-found >/dev/null; \
	kubectl create secret generic "$$APP_SECRET_NAME" -n "$$APP_NS" \
		--from-literal=RABBITMQ_HOST="$$RMQ_HOST" \
		--from-literal=RABBITMQ_PORT="$$RMQ_PORT" \
		--from-literal=RABBITMQ_MANAGEMENT_PORT="$$RMQ_MGMT_PORT" \
		--from-literal=RABBITMQ_VHOST="$$APP_VHOST" \
		--from-literal=RABBITMQ_USERNAME="$$APP_USER" \
		--from-literal=RABBITMQ_PASSWORD="$$APP_PASSWORD" \
		--from-literal=RABBITMQ_AMQP_URL="$$AMQP_URL" \
		>/dev/null; \
	printf '%s\n' \
		'rabbitmq:' \
		"  password: \"$$APP_PASSWORD\"" \
		"  username: \"$$APP_USER\"" \
		"  vhost: \"$$APP_VHOST\"" \
		"  host: \"$$RMQ_HOST\"" \
		"  amqp_port: $$RMQ_PORT" \
		"  management_port: $$RMQ_MGMT_PORT" \
	| "$$INF/scripts/app-conf-set.sh" "$$INF" "$(APP)"; \
	echo "✓ Done (Secret: $$APP_NS/$$APP_SECRET_NAME)"; \
	}

# Usage: make app-show-creds APP=myapp [APP_NS=myapp]
app-show-creds:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-show-creds APP=myapp)"; exit 1; fi
	@APP_NS=$${APP_NS:-$(APP)}; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-rabbitmq}; \
	if ! kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" >/dev/null 2>&1; then \
		echo "✗ Secret $$APP_SECRET_NAME не найден в namespace $$APP_NS"; exit 1; \
	fi; \
	echo "Secret: $$APP_NS/$$APP_SECRET_NAME"; \
	echo "---"; \
	for k in RABBITMQ_HOST RABBITMQ_PORT RABBITMQ_MANAGEMENT_PORT RABBITMQ_VHOST RABBITMQ_USERNAME RABBITMQ_PASSWORD RABBITMQ_AMQP_URL; do \
		v=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath="{.data.$$k}" 2>/dev/null | base64 -d); \
		echo "$$k=$$v"; \
	done

# Usage: make app-verify APP=myapp — smoke: rabbitmqctl authenticate_user + проверка vhost+permissions.
app-verify:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-verify APP=myapp)"; exit 1; fi
	@APP_NS=$${APP_NS:-$(APP)}; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-rabbitmq}; \
	if ! kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" >/dev/null 2>&1; then \
		echo "✗ Secret $$APP_SECRET_NAME не найден в namespace $$APP_NS"; exit 1; \
	fi; \
	APP_USER=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.RABBITMQ_USERNAME}' | base64 -d); \
	APP_PASSWORD=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.RABBITMQ_PASSWORD}' | base64 -d); \
	APP_VHOST=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.RABBITMQ_VHOST}' | base64 -d); \
	if [ -z "$$APP_USER" ] || [ -z "$$APP_PASSWORD" ]; then echo "✗ В Secret отсутствуют RABBITMQ_USERNAME/RABBITMQ_PASSWORD"; exit 1; fi; \
	POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE),app.kubernetes.io/name=rabbitmq -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then echo "✗ RabbitMQ pod не найден в namespace $(NAMESPACE)"; exit 1; fi; \
	echo "Проверка $$APP_USER (vhost=$$APP_VHOST)..."; \
	if ! kubectl exec "$$POD" -n $(NAMESPACE) -- rabbitmqctl authenticate_user "$$APP_USER" "$$APP_PASSWORD" >/dev/null 2>&1; then \
		echo "✗ rabbitmqctl authenticate_user не прошёл (пароль?)"; exit 1; \
	fi; \
	if [ -n "$$APP_VHOST" ]; then \
		PERM_OUT=$$(kubectl exec "$$POD" -n $(NAMESPACE) -- rabbitmqctl list_user_permissions "$$APP_USER" 2>/dev/null | awk -v vh="$$APP_VHOST" 'NR>1 && $$1==vh {print $$0}'); \
		if [ -z "$$PERM_OUT" ]; then \
			echo "✗ У пользователя $$APP_USER нет permissions на vhost $$APP_VHOST"; exit 1; \
		fi; \
	fi; \
	echo "✓ Auth ok; permissions на vhost $$APP_VHOST подтверждены"

# Usage: make app-drop APP=myapp [APP_NS=myapp] [APP_VHOST=myapp] [APP_USER=app_myapp] [SKIP_CONFIRM=1]
app-drop:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-drop APP=myapp)"; exit 1; fi
	@APP_NS=$${APP_NS:-$(APP)}; \
	APP_VHOST=$${APP_VHOST:-$(APP)}; \
	APP_USER=$${APP_USER:-app_$(APP)}; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-rabbitmq}; \
	if [ "$(SKIP_CONFIRM)" != "1" ]; then \
		echo "⚠ ВНИМАНИЕ: Будут удалены vhost \"$$APP_VHOST\", пользователь \"$$APP_USER\" и Secret \"$$APP_NS/$$APP_SECRET_NAME\" (очереди и сообщения в vhost будут потеряны)."; \
		read -p "Вы уверены? (y/N): " confirm; \
		if [ "$$confirm" != "y" ] && [ "$$confirm" != "Y" ]; then echo "Отменено."; exit 0; fi; \
	fi; \
	POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE),app.kubernetes.io/name=rabbitmq -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then echo "✗ RabbitMQ pod не найден в namespace $(NAMESPACE)"; exit 1; fi; \
	echo "Deleting vhost $$APP_VHOST and user $$APP_USER..."; \
	kubectl exec -i "$$POD" -n $(NAMESPACE) -- bash -c ' \
		rabbitmqctl delete_vhost "$$1" 2>/dev/null || true; \
		rabbitmqctl delete_user  "$$2" 2>/dev/null || true; \
	' bash "$$APP_VHOST" "$$APP_USER"; \
	echo "Deleting Secret $$APP_SECRET_NAME in namespace $$APP_NS..."; \
	kubectl delete secret "$$APP_SECRET_NAME" -n "$$APP_NS" --ignore-not-found; \
	"$(INFRA_ROOT)/scripts/app-conf-clear.sh" "$(INFRA_ROOT)" "$(APP)" rabbitmq || true; \
	echo "✓ vhost $$APP_VHOST, пользователь $$APP_USER и Secret $$APP_NS/$$APP_SECRET_NAME удалены"

images-verify:
	@# Проверяем именно SRC-теги через $$(IMAGES_SRC) — то, что реально pull-ится.
	@# Сейчас *_SRC_TAG ?= $$(*_TAG), но переключение устойчиво к будущему выпилу
	@# mutable-тегов в bitnamilegacy (как уже произошло для postgres/redis/kafka).
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
	@echo "Проверка обновлений для RabbitMQ..."
	@echo ""
	@CURRENT_CHART=$$(grep '^version:' $(CHART_PATH)/Chart.yaml | awk '{print $$2}'); \
	CURRENT_APP=$$(grep '^appVersion:' $(CHART_PATH)/Chart.yaml | awk '{print $$2}'); \
	echo "Текущая версия чарта: $$CURRENT_CHART (appVersion: $$CURRENT_APP)"; \
	echo "Текущие теги образов: rabbitmq:$(RABBITMQ_TAG), os-shell:$(OS_SHELL_TAG)"; \
	echo ""; \
	echo "Проверка доступных версий чарта..."; \
	if command -v helm >/dev/null 2>&1; then \
		if ! helm repo list 2>/dev/null | grep -q bitnami; then \
			echo "  Добавляю репозиторий bitnami..."; \
			helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true; \
			helm repo update >/dev/null 2>&1 || true; \
		fi; \
		echo "  Поиск последней версии чарта..."; \
		LATEST_CHART=$$(helm search repo bitnami/rabbitmq --versions --output json 2>/dev/null | jq -r '.[0].version' 2>/dev/null || helm search repo bitnami/rabbitmq --versions 2>/dev/null | head -2 | tail -1 | awk '{print $$2}' || echo ""); \
		if [ -n "$$LATEST_CHART" ] && [ "$$LATEST_CHART" != "$$CURRENT_CHART" ]; then \
			echo "  ⚠ Доступна новая версия чарта: $$LATEST_CHART"; \
			echo "  Для проверки образов новой версии выполните:"; \
			echo "    helm show chart bitnami/rabbitmq --version $$LATEST_CHART | grep -A 10 '^annotations:'"; \
		elif [ -n "$$LATEST_CHART" ]; then \
			echo "  ✓ Используется последняя версия чарта: $$CURRENT_CHART"; \
		else \
			echo "  ⚠ Не удалось получить версию чарта"; \
		fi; \
	else \
		echo "  ⚠ helm не установлен, проверка версий чарта пропущена"; \
		echo "  Альтернатива: проверьте https://github.com/bitnami/charts/tree/main/bitnami/rabbitmq"; \
	fi; \
	echo ""; \
	echo "Примечание: После обновления чарта проверьте теги образов в Chart.yaml новой версии"

install:
	@kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	@# values-*.yaml ссылаются на auth.existingPasswordSecret/existingErlangSecret: $(RABBITMQ_SECRET_NAME).
	@# При первом разворачивании Secret отсутствует — генерируем admin password + erlang-cookie.
	@# В корневой цели `make up` логика та же.
	@if ! kubectl get secret -n $(NAMESPACE) $(RABBITMQ_SECRET_NAME) >/dev/null 2>&1; then \
		echo "Secret $(NAMESPACE)/$(RABBITMQ_SECRET_NAME) отсутствует — создаю..."; \
		command -v openssl >/dev/null 2>&1 || { echo "✗ openssl не найден"; exit 1; }; \
		RABBITMQ_PASSWORD=$$(openssl rand -hex 16); \
		RABBITMQ_COOKIE=$$(openssl rand -hex 32); \
		kubectl create secret generic $(RABBITMQ_SECRET_NAME) -n $(NAMESPACE) \
			--from-literal=rabbitmq-password="$$RABBITMQ_PASSWORD" \
			--from-literal=rabbitmq-erlang-cookie="$$RABBITMQ_COOKIE" >/dev/null; \
		echo "✓ Secret $(NAMESPACE)/$(RABBITMQ_SECRET_NAME) создан"; \
	fi
	@# Bitnami chart требует auth.password и auth.erlangCookie через --set (так же делает helmfile.yaml.gotmpl).
	@if [ ! -f $(VALUES_FILE) ]; then echo "Файл $(VALUES_FILE) не найден"; exit 1; fi
	@RMQ_PASSWORD=$$(kubectl get secret -n $(NAMESPACE) $(RABBITMQ_SECRET_NAME) -o jsonpath='{.data.rabbitmq-password}' 2>/dev/null | base64 -d); \
	RMQ_COOKIE=$$(kubectl get secret -n $(NAMESPACE) $(RABBITMQ_SECRET_NAME) -o jsonpath='{.data.rabbitmq-erlang-cookie}' 2>/dev/null | base64 -d); \
	if [ -z "$$RMQ_PASSWORD" ] || [ -z "$$RMQ_COOKIE" ]; then \
		echo "✗ Не удалось прочитать rabbitmq-password / rabbitmq-erlang-cookie из Secret"; exit 1; \
	fi; \
	echo "Использование файла $(VALUES_FILE)"; \
	helm install $(RELEASE) $(CHART_PATH) --namespace $(NAMESPACE) -f $(VALUES_FILE) \
		--set auth.password="$$RMQ_PASSWORD" --set auth.erlangCookie="$$RMQ_COOKIE"

upgrade:
	@if [ ! -f $(VALUES_FILE) ]; then echo "Файл $(VALUES_FILE) не найден"; exit 1; fi
	@# Так же, как в install: Bitnami chart требует пароль/erlang-cookie через --set
	@# (PASSWORDS ERROR при upgrade без них). Помимо install — здесь без auto-create Secret:
	@# upgrade подразумевает существующий release с уже установленным Secret.
	@RMQ_PASSWORD=$$(kubectl get secret -n $(NAMESPACE) $(RABBITMQ_SECRET_NAME) -o jsonpath='{.data.rabbitmq-password}' 2>/dev/null | base64 -d); \
	RMQ_COOKIE=$$(kubectl get secret -n $(NAMESPACE) $(RABBITMQ_SECRET_NAME) -o jsonpath='{.data.rabbitmq-erlang-cookie}' 2>/dev/null | base64 -d); \
	if [ -z "$$RMQ_PASSWORD" ] || [ -z "$$RMQ_COOKIE" ]; then \
		echo "✗ Secret $(NAMESPACE)/$(RABBITMQ_SECRET_NAME) не найден или пуст. Сначала: make install"; exit 1; \
	fi; \
	echo "Использование файла $(VALUES_FILE)"; \
	helm upgrade $(RELEASE) $(CHART_PATH) --namespace $(NAMESPACE) -f $(VALUES_FILE) \
		--set auth.password="$$RMQ_PASSWORD" --set auth.erlangCookie="$$RMQ_COOKIE"

uninstall:
	@echo "⚠ ВНИМАНИЕ: Это удалит Helm release $(RELEASE)."
	@echo "  Останутся в namespace $(NAMESPACE):"
	@echo "    - PVC с данными RabbitMQ (mnesia, durable queues, vhosts/users definitions);"
	@echo "    - Secret $(RABBITMQ_SECRET_NAME) (admin password + erlang-cookie — критично:"
	@echo "      без правильного erlang-cookie новый кластер не подхватит существующий PV mnesia,"
	@echo "      см. rabbitmq/BACKUP.md, раздел «Известные ограничения»);"
	@echo "    - Secrets <APP>-rabbitmq в namespace приложений (с APP-кредами)."
	@echo "  Полная зачистка (включая данные) — отдельными командами:"
	@echo "    kubectl delete pvc -n $(NAMESPACE) -l app.kubernetes.io/name=rabbitmq"
	@echo "    kubectl delete secret $(RABBITMQ_SECRET_NAME) -n $(NAMESPACE)"
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
	@POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE),app.kubernetes.io/name=rabbitmq -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then \
		echo "Поды RabbitMQ не найдены"; \
	else \
		echo "Логи пода: $$POD"; \
		kubectl logs -f $$POD -n $(NAMESPACE); \
	fi

shell:
	@POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE),app.kubernetes.io/name=rabbitmq -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then \
		echo "Поды RabbitMQ не найдены"; \
		exit 1; \
	else \
		echo "Подключение к поду: $$POD"; \
		kubectl exec -it $$POD -n $(NAMESPACE) -- bash || kubectl exec -it $$POD -n $(NAMESPACE) -- sh; \
	fi

images-pull:
	@echo "Загрузка образов из docker.io/bitnamilegacy..."
	@docker pull $(RABBITMQ_IMAGE_SRC)
	@docker pull $(OS_SHELL_IMAGE_SRC)
	@echo "✓ Все образы загружены"

images-tag: images-pull
	@docker tag $(RABBITMQ_IMAGE_SRC) $(RABBITMQ_IMAGE_LOCAL)
	@docker tag $(OS_SHELL_IMAGE_SRC) $(OS_SHELL_IMAGE_LOCAL)

images-push: check-registry images-tag
	@docker push $(RABBITMQ_IMAGE_LOCAL)
	@docker push $(OS_SHELL_IMAGE_LOCAL)

images-sync: images-push

images-save: images-pull
	@mkdir -p $(IMAGES_DIR)
	@docker save $(RABBITMQ_IMAGE_SRC) -o $(IMAGES_DIR)/rabbitmq-$(RABBITMQ_TAG).tar
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

## =========================
## Backup / Restore (definitions: rabbitmqctl export/import_definitions)
## =========================
BACKUP_DIR ?= backups

# Экспорт всех definitions (vhosts, users, permissions, exchanges, queues, bindings, parameters, policies)
# в JSON. Сообщения и состояние очередей НЕ бэкапятся — для durability используется persistence + replication.
backup-defs:
	@mkdir -p $(BACKUP_DIR)
	@set -eo pipefail; \
	TS=$$(date +%Y%m%d-%H%M%S); \
	OUT="$(BACKUP_DIR)/rabbitmq-defs-$$TS.json.gz"; \
	echo "Экспорт definitions RabbitMQ в $$OUT..."; \
	POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE),app.kubernetes.io/name=rabbitmq -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then echo "✗ RabbitMQ pod не найден в namespace $(NAMESPACE)"; exit 1; fi; \
	kubectl exec "$$POD" -n $(NAMESPACE) -- rabbitmqctl export_definitions /tmp/rabbitmq-defs.json >/dev/null; \
	kubectl exec "$$POD" -n $(NAMESPACE) -- cat /tmp/rabbitmq-defs.json | gzip > "$$OUT"; \
	kubectl exec "$$POD" -n $(NAMESPACE) -- rm -f /tmp/rabbitmq-defs.json >/dev/null 2>&1 || true; \
	[ -s "$$OUT" ] || { echo "✗ Архив $$OUT пуст или не создан"; exit 1; }; \
	: "Проверяем что внутри валидный JSON (gunzip + базовая проверка структуры)"; \
	gunzip -c "$$OUT" | head -c 1 | grep -q '{' || { echo "✗ Архив $$OUT не содержит валидный JSON"; exit 1; }; \
	SIZE=$$(du -h --apparent-size "$$OUT" | cut -f1); \
	echo "✓ Definitions экспортированы: $$OUT ($$SIZE)"

list-backups:
	@echo "Список бэкапов definitions RabbitMQ в $(BACKUP_DIR):"
	@if [ -d "$(BACKUP_DIR)" ]; then \
		ls -lht "$(BACKUP_DIR)"/rabbitmq-defs-*.json.gz 2>/dev/null | awk '{print $$9, "(" $$5, $$6, $$7, $$8 ")"}' || echo "  Бэкапы не найдены"; \
	else \
		echo "  Директория $(BACKUP_DIR) не существует"; \
	fi

# Импорт definitions: rabbitmqctl import_definitions делает merge — существующие vhosts/users/queues
# не пересоздаются деструктивно, добавляются недостающие. Хэши паролей пользователей восстанавливаются
# как есть; для приложений после restore-defs запустите apps-apply.
restore-defs:
	@if [ -z "$(BACKUP_FILE)" ]; then \
		echo "✗ Укажите файл: make restore-defs BACKUP_FILE=$(BACKUP_DIR)/rabbitmq-defs-YYYYMMDD-HHMMSS.json.gz"; \
		exit 1; \
	fi
	@if [ ! -f "$(BACKUP_FILE)" ]; then echo "✗ Файл $(BACKUP_FILE) не найден"; exit 1; fi
	@if [ "$(SKIP_CONFIRM)" != "1" ]; then \
		echo "⚠ Будут импортированы definitions из $(BACKUP_FILE) (idempotent merge: новое — добавится, существующее — не пересоздаётся)."; \
		read -p "Продолжить? (y/N): " confirm; \
		if [ "$$confirm" != "y" ] && [ "$$confirm" != "Y" ]; then echo "Отменено."; exit 0; fi; \
	fi
	@set -eo pipefail; \
	POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE),app.kubernetes.io/name=rabbitmq -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then echo "✗ RabbitMQ pod не найден"; exit 1; fi; \
	: "Базовая проверка валидности gzip — ловит битый архив до запуска import"; \
	gunzip -t "$(BACKUP_FILE)" || { echo "✗ $(BACKUP_FILE) — невалидный gzip"; exit 1; }; \
	echo "  Копирую $(BACKUP_FILE) в pod..."; \
	gunzip -c "$(BACKUP_FILE)" | kubectl exec -i "$$POD" -n $(NAMESPACE) -- sh -c 'cat > /tmp/rabbitmq-defs.json'; \
	echo "  rabbitmqctl import_definitions..."; \
	kubectl exec "$$POD" -n $(NAMESPACE) -- rabbitmqctl import_definitions /tmp/rabbitmq-defs.json; \
	kubectl exec "$$POD" -n $(NAMESPACE) -- rm -f /tmp/rabbitmq-defs.json >/dev/null 2>&1 || true; \
	echo "✓ Definitions импортированы"

