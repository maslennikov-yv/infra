.PHONY: help \
	images-verify images-pull images-tag images-push images-sync images-save images-load images-sync-from-files images-clean images-clean-files \
	pull-images tag-images push-images load-images save-images load-images-from-file clean clean-images-files \
	check-registry setup-local-registry setup \
	secrets-init bootstrap reset \
	install upgrade uninstall status logs shell app-create app-print-env \
	topic-create topic-alter topic-describe topic-list \
	test-producer test-consumer test-clean test-client-properties test-create-topic \
	check-updates

# Локальный registry MicroK8s
REGISTRY ?= localhost:32000

# KUBECONFIG (передаётся из root Makefile)
KUBECONFIG ?=
ifneq ($(KUBECONFIG),)
export KUBECONFIG
endif

# Образы, используемые chart'ом (см. kafka/kafka/values.yaml и Chart.yaml annotations)
KAFKA_TAG ?= 4.0.0-debian-12-r10
OS_SHELL_TAG ?= 12-debian-12-r51
KUBECTL_TAG ?= 1.33.4-debian-12-r0
JMX_EXPORTER_TAG ?= 1.4.0-debian-12-r0

# Source images (пытаемся скачать из bitnamilegacy; fallback на bitnami)
KAFKA_IMAGE_SRC := docker.io/bitnamilegacy/kafka:$(KAFKA_TAG)
OS_SHELL_IMAGE_SRC := docker.io/bitnamilegacy/os-shell:$(OS_SHELL_TAG)
KUBECTL_IMAGE_SRC := docker.io/bitnamilegacy/kubectl:$(KUBECTL_TAG)
JMX_EXPORTER_IMAGE_SRC := docker.io/bitnamilegacy/jmx-exporter:$(JMX_EXPORTER_TAG)

# Local registry tags (оставляем repository как в chart: bitnami/*)
KAFKA_IMAGE_LOCAL := $(REGISTRY)/bitnami/kafka:$(KAFKA_TAG)
OS_SHELL_IMAGE_LOCAL := $(REGISTRY)/bitnami/os-shell:$(OS_SHELL_TAG)
KUBECTL_IMAGE_LOCAL := $(REGISTRY)/bitnami/kubectl:$(KUBECTL_TAG)
JMX_EXPORTER_IMAGE_LOCAL := $(REGISTRY)/bitnami/jmx-exporter:$(JMX_EXPORTER_TAG)

# Полный список образов
IMAGES_SRC := $(KAFKA_IMAGE_SRC) $(OS_SHELL_IMAGE_SRC) $(KUBECTL_IMAGE_SRC) $(JMX_EXPORTER_IMAGE_SRC)
IMAGES_LOCAL := $(KAFKA_IMAGE_LOCAL) $(OS_SHELL_IMAGE_LOCAL) $(KUBECTL_IMAGE_LOCAL) $(JMX_EXPORTER_IMAGE_LOCAL)

# Директория для сохранения образов
IMAGES_DIR ?= images

# Настройки для тестирования Kafka
KAFKA_NAMESPACE := kafka
KAFKA_BOOTSTRAP_SERVER := kafka.$(KAFKA_NAMESPACE).svc.cluster.local:9092
KAFKA_TOPIC := test-topic
KAFKA_CLIENT_NAME := kafka-client

# Настройки Helm release
HELM_RELEASE_NAME ?= kafka
CHART_PATH := kafka
ENV ?= dev
VALUES_FILE ?= values-$(ENV).yaml
BOOTSTRAP_VALUES_FILE ?= values-bootstrap.yaml

help:
	@echo "Доступные команды:"
	@echo ""
	@echo "Установка и настройка:"
	@echo "  make setup              - Полная установка всего необходимого в MicroK8s"
	@echo ""
	@echo "Управление Helm release:"
	@echo "  make install            - Установить Kafka в namespace $(KAFKA_NAMESPACE)"
	@echo "  make bootstrap          - Первичная установка (bootstrap-safe) + включение authorizer"
	@echo "  make upgrade            - Обновить Helm release Kafka"
	@echo "  make uninstall          - Удалить Kafka из кластера"
	@echo "  make status             - Показать статус Kafka (поды, сервисы, PVC)"
	@echo "  make secrets-init       - Создать kafka-kraft / kafka-user-passwords (если отсутствуют)"
	@echo "  make reset              - ⚠ Reset KRaft данных + secrets (для аварийного восстановления)"
	@echo ""
	@echo "Управление образами (offline / microk8s registry):"
	@echo "  make check-registry         - Проверить доступность registry $(REGISTRY)"
	@echo "  make images-verify          - Проверить доступность всех тегов в docker.io/bitnamilegacy"
	@echo "  make images-pull            - Скачать все образы (bitnamilegacy -> bitnami fallback)"
	@echo "  make images-tag             - Тегировать образы для $(REGISTRY)/bitnami/*"
	@echo "  make images-push            - Загрузить образы в microk8s registry"
	@echo "  make images-sync            - pull + tag + push"
	@echo "  make images-save            - Сохранить образы в tar (директория $(IMAGES_DIR)/)"
	@echo "  make images-load            - Загрузить образы из tar"
	@echo "  make images-sync-from-files - load + tag + push"
	@echo "  make images-clean           - Удалить локальные docker-образы"
	@echo "  make images-clean-files     - Удалить сохраненные tar"
	@echo ""
	@echo "Values:"
	@echo "  values-dev.yaml / values-prod.yaml - использовать registry $(REGISTRY) в чарте"
	@echo "  values-bootstrap.yaml   - bootstrap-safe values (без authorizer)"
	@echo ""
	@echo "Тестирование Kafka:"
	@echo "  make test-client-properties - Создать client.properties файл для аутентификации"
	@echo "  make test-producer      - Запустить тестовый producer (отправка сообщений)"
	@echo "  make test-consumer      - Запустить тестовый consumer (чтение с последнего offset)"
	@echo "  make test-consumer FROM_BEGINNING=true - Запустить consumer с чтением с начала топика"
	@echo "  make test-clean         - Удалить тестовые поды и файлы"
	@echo ""
	@echo "App accounts (per-app isolation):"
	@echo "  make app-create APP=myapp [APP_NS=myapp] [APP_PASSWORD=...]"
	@echo "  make app-print-env APP=myapp   - Показать рекомендуемые env/топики/группы для приложения"
	@echo ""
	@echo "Topics:"
	@echo "  make topic-create  APP=myapp TOPIC_SUFFIX=events [PARTITIONS=3] [REPLICATION_FACTOR=1] [CONFIGS=k=v,k2=v2]"
	@echo "  make topic-alter   TOPIC=myapp.events [PARTITIONS=12] [CONFIGS=k=v,k2=v2]"
	@echo "  make topic-describe TOPIC=myapp.events"
	@echo "  make topic-list    [PREFIX=myapp.]"

## =========================
## App accounts (per-app isolation)
## =========================

## =========================
## Bootstrap / secrets (KRaft + SASL)
## =========================

# Create required secrets if missing (does not print credentials).
# - kafka-kraft: cluster-id + controller directory ids
# - kafka-user-passwords: client-passwords + inter-broker-password + controller-password
secrets-init:
	@command -v kubectl >/dev/null 2>&1 || { echo "✗ kubectl не найден"; exit 1; }
	@command -v openssl >/dev/null 2>&1 || { echo "✗ openssl не найден"; exit 1; }
	@command -v python3 >/dev/null 2>&1 || { echo "✗ python3 не найден (нужен для генерации KRaft IDs)"; exit 1; }
	@if [ -n "$(KUBECONFIG)" ]; then export KUBECONFIG="$(KUBECONFIG)"; fi; \
	kubectl create namespace $(KAFKA_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f - >/dev/null; \
	need=0; \
	for s in kafka-kraft kafka-user-passwords; do \
		if ! kubectl -n $(KAFKA_NAMESPACE) get secret $$s >/dev/null 2>&1; then need=1; fi; \
	done; \
	if [ $$need -eq 0 ]; then \
		echo "✓ Secrets already exist: kafka-kraft, kafka-user-passwords"; \
		exit 0; \
	fi; \
	CLUSTER_ID=$$(python3 -c "import os,base64; print(base64.urlsafe_b64encode(os.urandom(16)).decode().rstrip('='))"); \
	C0=$$(python3 -c "import os,base64; print(base64.urlsafe_b64encode(os.urandom(16)).decode().rstrip('='))"); \
	C1=$$(python3 -c "import os,base64; print(base64.urlsafe_b64encode(os.urandom(16)).decode().rstrip('='))"); \
	C2=$$(python3 -c "import os,base64; print(base64.urlsafe_b64encode(os.urandom(16)).decode().rstrip('='))"); \
	PASS_CLIENT=$$(openssl rand -hex 16); PASS_INTER=$$(openssl rand -hex 16); PASS_CTRL=$$(openssl rand -hex 16); \
	kubectl -n $(KAFKA_NAMESPACE) delete secret kafka-kraft kafka-user-passwords --ignore-not-found >/dev/null; \
	kubectl -n $(KAFKA_NAMESPACE) create secret generic kafka-kraft \
		--from-literal=cluster-id="$$CLUSTER_ID" \
		--from-literal=controller-0-id="$$C0" \
		--from-literal=controller-1-id="$$C1" \
		--from-literal=controller-2-id="$$C2" \
		>/dev/null; \
	kubectl -n $(KAFKA_NAMESPACE) create secret generic kafka-user-passwords \
		--from-literal=client-passwords="$$PASS_CLIENT" \
		--from-literal=inter-broker-password="$$PASS_INTER" \
		--from-literal=controller-password="$$PASS_CTRL" \
		>/dev/null; \
	echo "✓ Secrets created: $(KAFKA_NAMESPACE)/kafka-kraft, $(KAFKA_NAMESPACE)/kafka-user-passwords"

# Bootstrap-safe install:
# - create secrets (if missing)
# - helm install using values-bootstrap.yaml
# - wait for quorum
# - helm upgrade to values-$(ENV).yaml (enables authorizer/ACLs)
bootstrap: secrets-init
	@if [ -n "$(KUBECONFIG)" ]; then export KUBECONFIG="$(KUBECONFIG)"; fi; \
	kubectl -n $(KAFKA_NAMESPACE) delete pod -l app.kubernetes.io/name=kafka --ignore-not-found >/dev/null 2>&1 || true; \
	if helm status $(HELM_RELEASE_NAME) -n $(KAFKA_NAMESPACE) >/dev/null 2>&1; then \
		echo "✓ Release already exists. Use: make upgrade ENV=$(ENV)"; \
		exit 0; \
	fi; \
	echo "Bootstrap install: $(HELM_RELEASE_NAME) (values: $(BOOTSTRAP_VALUES_FILE))"; \
	helm install $(HELM_RELEASE_NAME) $(CHART_PATH) --namespace $(KAFKA_NAMESPACE) -f $(BOOTSTRAP_VALUES_FILE); \
	kubectl -n $(KAFKA_NAMESPACE) rollout status sts/$(HELM_RELEASE_NAME)-controller --timeout=300s || true; \
	echo "Enabling final values: $(VALUES_FILE)"; \
	$(MAKE) upgrade ENV=$(ENV) KUBECONFIG="$(KUBECONFIG)"

# Emergency reset for KRaft (data loss):
# - scale down controllers
# - delete PVCs
# - recreate secrets
# - scale up (expects release already installed)
reset:
	@if [ -n "$(KUBECONFIG)" ]; then export KUBECONFIG="$(KUBECONFIG)"; fi; \
	echo "⚠ RESET will delete Kafka KRaft PVCs and secrets in namespace $(KAFKA_NAMESPACE) (DATA LOSS)"; \
	kubectl -n $(KAFKA_NAMESPACE) scale sts/$(HELM_RELEASE_NAME)-controller --replicas=0 >/dev/null 2>&1 || true; \
	kubectl -n $(KAFKA_NAMESPACE) delete pod -l app.kubernetes.io/name=kafka --ignore-not-found >/dev/null 2>&1 || true; \
	kubectl -n $(KAFKA_NAMESPACE) delete pvc data-$(HELM_RELEASE_NAME)-controller-0 data-$(HELM_RELEASE_NAME)-controller-1 data-$(HELM_RELEASE_NAME)-controller-2 --ignore-not-found >/dev/null 2>&1 || true; \
	kubectl -n $(KAFKA_NAMESPACE) delete secret kafka-kraft kafka-user-passwords --ignore-not-found >/dev/null 2>&1 || true; \
	$(MAKE) secrets-init ENV=$(ENV) KUBECONFIG="$(KUBECONFIG)"; \
	kubectl -n $(KAFKA_NAMESPACE) scale sts/$(HELM_RELEASE_NAME)-controller --replicas=3 >/dev/null 2>&1 || true; \
	kubectl -n $(KAFKA_NAMESPACE) rollout status sts/$(HELM_RELEASE_NAME)-controller --timeout=300s || true

# Usage: make app-create APP=myapp [APP_NS=myapp] [APP_PASSWORD=...]
app-create:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-create APP=myapp)"; exit 1; fi
	@APP_NS=$${APP_NS:-$(APP)}; \
	APP_USER=$${APP_USER:-app_$(APP)}; \
	APP_PASSWORD=$${APP_PASSWORD:-}; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-kafka}; \
	if [ -z "$$APP_PASSWORD" ]; then \
		command -v openssl >/dev/null 2>&1 || { echo "✗ openssl не найден (передайте APP_PASSWORD=... или установите openssl)"; exit 1; }; \
		APP_PASSWORD=$$(openssl rand -hex 16); \
	fi; \
	ADMIN_PASSWORD=$$(kubectl get secret $(HELM_RELEASE_NAME)-user-passwords --namespace $(KAFKA_NAMESPACE) -o jsonpath='{.data.client-passwords}' 2>/dev/null | base64 -d | cut -d, -f1); \
	if [ -z "$$ADMIN_PASSWORD" ]; then \
		echo "✗ Не удалось получить admin password из секрета $(HELM_RELEASE_NAME)-user-passwords (нужно включить SASL в values)"; \
		exit 1; \
	fi; \
	echo "Creating Kafka user/ACL for $$APP_USER (topic prefix: $(APP)., group prefix: $(APP).)"; \
	kubectl run kafka-admin-$$(date +%s) \
		--restart='Never' \
		--image=$(KAFKA_IMAGE_LOCAL) \
		--namespace=$(KAFKA_NAMESPACE) \
		--rm -i --env="KAFKA_ADMIN_PASSWORD=$$ADMIN_PASSWORD" --env="APP_USER=$$APP_USER" --env="APP_PASSWORD=$$APP_PASSWORD" --command -- bash -ec "\
			cat > /tmp/admin.properties <<'EOF'\n\
security.protocol=SASL_PLAINTEXT\n\
sasl.mechanism=SCRAM-SHA-256\n\
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\\\"user1\\\" password=\\\"$${KAFKA_ADMIN_PASSWORD}\\\";\n\
EOF\n\
			kafka-configs.sh --bootstrap-server $(KAFKA_BOOTSTRAP_SERVER) --command-config /tmp/admin.properties \\\n\
				--alter --add-config \"SCRAM-SHA-256=[iterations=4096,password=$${APP_PASSWORD}]\" --entity-type users --entity-name \"$${APP_USER}\";\n\
			kafka-acls.sh --bootstrap-server $(KAFKA_BOOTSTRAP_SERVER) --command-config /tmp/admin.properties \\\n\
				--add --allow-principal \"User:$${APP_USER}\" --operation Read --operation Write --operation Describe --operation Create \\\n\
				--topic \"$(APP).\" --resource-pattern-type prefixed;\n\
			kafka-acls.sh --bootstrap-server $(KAFKA_BOOTSTRAP_SERVER) --command-config /tmp/admin.properties \\\n\
				--add --allow-principal \"User:$${APP_USER}\" --operation Read --operation Describe \\\n\
				--group \"$(APP).\" --resource-pattern-type prefixed;\n\
		"; \
	echo "Creating Secret $$APP_SECRET_NAME in namespace $$APP_NS"; \
	kubectl create namespace "$$APP_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; \
	kubectl delete secret "$$APP_SECRET_NAME" -n "$$APP_NS" --ignore-not-found >/dev/null; \
	kubectl create secret generic "$$APP_SECRET_NAME" -n "$$APP_NS" \
		--from-literal=KAFKA_BOOTSTRAP_SERVER="$(KAFKA_BOOTSTRAP_SERVER)" \
		--from-literal=KAFKA_SECURITY_PROTOCOL="SASL_PLAINTEXT" \
		--from-literal=KAFKA_SASL_MECHANISM="SCRAM-SHA-256" \
		--from-literal=KAFKA_USERNAME="$$APP_USER" \
		--from-literal=KAFKA_PASSWORD="$$APP_PASSWORD" \
		--from-literal=KAFKA_TOPIC_PREFIX="$(APP)." \
		--from-literal=KAFKA_GROUP_PREFIX="$(APP)." \
		>/dev/null; \
	echo ""; \
	echo "App connection info:"; \
	echo "  - bootstrap: $(KAFKA_BOOTSTRAP_SERVER)"; \
	echo "  - security.protocol: SASL_PLAINTEXT"; \
	echo "  - sasl.mechanism: SCRAM-SHA-256"; \
	echo "  - username: $$APP_USER"; \
	echo "  - topic prefix: $(APP)."; \
	echo "  - group prefix: $(APP)."; \
	echo "  - examples: /home/user/projects/infra/examples/kafka/"; \
	echo "✓ Done (Secret: $$APP_NS/$$APP_SECRET_NAME)"

# Print recommended env vars/topics/groups for an app (does not reveal passwords)
# Usage: make app-print-env APP=myapp
app-print-env:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-print-env APP=myapp)"; exit 1; fi
	@echo "Kafka app env (populate from Secret created by app-create):"
	@echo "  KAFKA_BOOTSTRAP_SERVER=$(KAFKA_BOOTSTRAP_SERVER)"
	@echo "  KAFKA_SECURITY_PROTOCOL=SASL_PLAINTEXT"
	@echo "  KAFKA_SASL_MECHANISM=SCRAM-SHA-256"
	@echo "  KAFKA_USERNAME=app_$(APP)"
	@echo "  KAFKA_PASSWORD=<from k8s secret>"
	@echo "  KAFKA_TOPIC_PREFIX=$(APP)."
	@echo "  KAFKA_GROUP_PREFIX=$(APP)."
	@echo ""
	@echo "Examples:"
	@echo "  topic:  $(APP).events"
	@echo "  group:  $(APP).worker"

## =========================
## Topic management (admin)
## =========================

# Create a topic (optionally for an app prefix)
# Usage:
#   make topic-create APP=myapp TOPIC_SUFFIX=events [PARTITIONS=3] [REPLICATION_FACTOR=1] [CONFIGS='retention.ms=604800000,cleanup.policy=delete,compression.type=producer']
#   make topic-create TOPIC=myapp.events PARTITIONS=6 REPLICATION_FACTOR=1 CONFIGS='max.message.bytes=1048576'
topic-create:
	@APP=$${APP:-}; \
	TOPIC_SUFFIX=$${TOPIC_SUFFIX:-events}; \
	TOPIC=$${TOPIC:-}; \
	PARTITIONS=$${PARTITIONS:-3}; \
	REPLICATION_FACTOR=$${REPLICATION_FACTOR:-1}; \
	CONFIGS=$${CONFIGS:-}; \
	if [ -z "$$TOPIC" ]; then \
		if [ -n "$$APP" ]; then TOPIC="$$APP.$$TOPIC_SUFFIX"; else echo "✗ TOPIC не задан (или задайте APP=... TOPIC_SUFFIX=...)"; exit 1; fi; \
	fi; \
	ADMIN_PASSWORD=$$(kubectl get secret $(HELM_RELEASE_NAME)-user-passwords --namespace $(KAFKA_NAMESPACE) -o jsonpath='{.data.client-passwords}' 2>/dev/null | base64 -d | cut -d, -f1); \
	if [ -z "$$ADMIN_PASSWORD" ]; then echo "✗ Не удалось получить admin password из секрета $(HELM_RELEASE_NAME)-user-passwords"; exit 1; fi; \
	echo "Create topic: $$TOPIC (partitions=$$PARTITIONS rf=$$REPLICATION_FACTOR configs=$$CONFIGS)"; \
	kubectl run kafka-admin-$$(date +%s) \
		--restart='Never' \
		--image=$(KAFKA_IMAGE_LOCAL) \
		--namespace=$(KAFKA_NAMESPACE) \
		--rm -i \
		--env="KAFKA_ADMIN_PASSWORD=$$ADMIN_PASSWORD" \
		--env="TOPIC=$$TOPIC" \
		--env="PARTITIONS=$$PARTITIONS" \
		--env="REPLICATION_FACTOR=$$REPLICATION_FACTOR" \
		--env="CONFIGS=$$CONFIGS" \
		--command -- bash -ec "\
			cat > /tmp/admin.properties <<'EOF'\n\
security.protocol=SASL_PLAINTEXT\n\
sasl.mechanism=SCRAM-SHA-256\n\
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\\\"user1\\\" password=\\\"$${KAFKA_ADMIN_PASSWORD}\\\";\n\
EOF\n\
			ARGS=(); \
			if [ -n \"$$CONFIGS\" ]; then \
			  IFS=',' read -ra KV <<< \"$$CONFIGS\"; \
			  for x in \"$${KV[@]}\"; do \
			    x=$$(echo \"$$x\" | xargs); \
			    [ -n \"$$x\" ] && ARGS+=(--config \"$$x\"); \
			  done; \
			fi; \
			kafka-topics.sh --bootstrap-server $(KAFKA_BOOTSTRAP_SERVER) --command-config /tmp/admin.properties \
			  --create --if-not-exists --topic \"$$TOPIC\" --partitions \"$$PARTITIONS\" --replication-factor \"$$REPLICATION_FACTOR\" \"$${ARGS[@]}\"; \
		"

# Alter a topic: increase partitions and/or change configs.
# Usage:
#   make topic-alter TOPIC=myapp.events PARTITIONS=12
#   make topic-alter TOPIC=myapp.events CONFIGS='retention.ms=86400000,max.message.bytes=1048576'
topic-alter:
	@if [ -z "$(TOPIC)" ]; then echo "✗ TOPIC не задан (пример: make topic-alter TOPIC=myapp.events PARTITIONS=12)"; exit 1; fi
	@PARTITIONS=$${PARTITIONS:-}; \
	CONFIGS=$${CONFIGS:-}; \
	ADMIN_PASSWORD=$$(kubectl get secret $(HELM_RELEASE_NAME)-user-passwords --namespace $(KAFKA_NAMESPACE) -o jsonpath='{.data.client-passwords}' 2>/dev/null | base64 -d | cut -d, -f1); \
	if [ -z "$$ADMIN_PASSWORD" ]; then echo "✗ Не удалось получить admin password из секрета $(HELM_RELEASE_NAME)-user-passwords"; exit 1; fi; \
	echo "Alter topic: $(TOPIC) (partitions=$$PARTITIONS configs=$$CONFIGS)"; \
	kubectl run kafka-admin-$$(date +%s) \
		--restart='Never' \
		--image=$(KAFKA_IMAGE_LOCAL) \
		--namespace=$(KAFKA_NAMESPACE) \
		--rm -i \
		--env="KAFKA_ADMIN_PASSWORD=$$ADMIN_PASSWORD" \
		--env="TOPIC=$(TOPIC)" \
		--env="PARTITIONS=$$PARTITIONS" \
		--env="CONFIGS=$$CONFIGS" \
		--command -- bash -ec "\
			cat > /tmp/admin.properties <<'EOF'\n\
security.protocol=SASL_PLAINTEXT\n\
sasl.mechanism=SCRAM-SHA-256\n\
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\\\"user1\\\" password=\\\"$${KAFKA_ADMIN_PASSWORD}\\\";\n\
EOF\n\
			if [ -n \"$$PARTITIONS\" ]; then \
			  kafka-topics.sh --bootstrap-server $(KAFKA_BOOTSTRAP_SERVER) --command-config /tmp/admin.properties \
			    --alter --topic \"$$TOPIC\" --partitions \"$$PARTITIONS\"; \
			fi; \
			if [ -n \"$$CONFIGS\" ]; then \
			  kafka-configs.sh --bootstrap-server $(KAFKA_BOOTSTRAP_SERVER) --command-config /tmp/admin.properties \
			    --alter --entity-type topics --entity-name \"$$TOPIC\" --add-config \"$$CONFIGS\"; \
			fi; \
		"

# Describe a topic (partitions + configs)
# Usage: make topic-describe TOPIC=myapp.events
topic-describe:
	@if [ -z "$(TOPIC)" ]; then echo "✗ TOPIC не задан (пример: make topic-describe TOPIC=myapp.events)"; exit 1; fi
	@ADMIN_PASSWORD=$$(kubectl get secret $(HELM_RELEASE_NAME)-user-passwords --namespace $(KAFKA_NAMESPACE) -o jsonpath='{.data.client-passwords}' 2>/dev/null | base64 -d | cut -d, -f1); \
	if [ -z "$$ADMIN_PASSWORD" ]; then echo "✗ Не удалось получить admin password из секрета $(HELM_RELEASE_NAME)-user-passwords"; exit 1; fi; \
	kubectl run kafka-admin-$$(date +%s) \
		--restart='Never' \
		--image=$(KAFKA_IMAGE_LOCAL) \
		--namespace=$(KAFKA_NAMESPACE) \
		--rm -i \
		--env="KAFKA_ADMIN_PASSWORD=$$ADMIN_PASSWORD" \
		--env="TOPIC=$(TOPIC)" \
		--command -- bash -ec "\
			cat > /tmp/admin.properties <<'EOF'\n\
security.protocol=SASL_PLAINTEXT\n\
sasl.mechanism=SCRAM-SHA-256\n\
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\\\"user1\\\" password=\\\"$${KAFKA_ADMIN_PASSWORD}\\\";\n\
EOF\n\
			echo '--- kafka-topics.sh --describe ---'; \
			kafka-topics.sh --bootstrap-server $(KAFKA_BOOTSTRAP_SERVER) --command-config /tmp/admin.properties --describe --topic \"$$TOPIC\"; \
			echo ''; \
			echo '--- kafka-configs.sh --describe ---'; \
			kafka-configs.sh --bootstrap-server $(KAFKA_BOOTSTRAP_SERVER) --command-config /tmp/admin.properties --describe --entity-type topics --entity-name \"$$TOPIC\" || true; \
		"

# List topics (optionally by prefix)
# Usage: make topic-list [PREFIX=myapp.]
topic-list:
	@PREFIX=$${PREFIX:-}; \
	ADMIN_PASSWORD=$$(kubectl get secret $(HELM_RELEASE_NAME)-user-passwords --namespace $(KAFKA_NAMESPACE) -o jsonpath='{.data.client-passwords}' 2>/dev/null | base64 -d | cut -d, -f1); \
	if [ -z "$$ADMIN_PASSWORD" ]; then echo "✗ Не удалось получить admin password из секрета $(HELM_RELEASE_NAME)-user-passwords"; exit 1; fi; \
	kubectl run kafka-admin-$$(date +%s) \
		--restart='Never' \
		--image=$(KAFKA_IMAGE_LOCAL) \
		--namespace=$(KAFKA_NAMESPACE) \
		--rm -i \
		--env="KAFKA_ADMIN_PASSWORD=$$ADMIN_PASSWORD" \
		--env="PREFIX=$$PREFIX" \
		--command -- bash -ec "\
			cat > /tmp/admin.properties <<'EOF'\n\
security.protocol=SASL_PLAINTEXT\n\
sasl.mechanism=SCRAM-SHA-256\n\
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\\\"user1\\\" password=\\\"$${KAFKA_ADMIN_PASSWORD}\\\";\n\
EOF\n\
			if [ -n \"$$PREFIX\" ]; then \
			  kafka-topics.sh --bootstrap-server $(KAFKA_BOOTSTRAP_SERVER) --command-config /tmp/admin.properties --list | grep \"^$$PREFIX\" || true; \
			else \
			  kafka-topics.sh --bootstrap-server $(KAFKA_BOOTSTRAP_SERVER) --command-config /tmp/admin.properties --list; \
			fi; \
		"

# Полная установка всего необходимого в MicroK8s
setup:
	@echo "=== Установка всех необходимых компонентов в MicroK8s ==="
	@echo ""
	@echo "1. Проверка необходимых инструментов..."
	@command -v kubectl >/dev/null 2>&1 || { echo "✗ kubectl не установлен. Установите kubectl."; exit 1; }
	@command -v helm >/dev/null 2>&1 || { echo "✗ helm не установлен. Установите Helm 3.8.0+."; exit 1; }
	@command -v docker >/dev/null 2>&1 || { echo "✗ docker не установлен. Установите Docker."; exit 1; }
	@command -v microk8s >/dev/null 2>&1 || { echo "✗ microk8s не установлен. Установите MicroK8s."; exit 1; }
	@echo "✓ Все необходимые инструменты установлены"
	@echo ""
	@echo "2. Проверка подключения к MicroK8s..."
	@microk8s status --wait-ready >/dev/null 2>&1 || { echo "✗ MicroK8s не запущен или не готов. Запустите: microk8s start"; exit 1; }
	@echo "✓ MicroK8s запущен и готов"
	@echo ""
	@echo "3. Включение необходимых аддонов MicroK8s..."
	@if ! microk8s status 2>/dev/null | grep -q "registry"; then \
		echo "   Включение registry..."; \
		microk8s enable registry || { echo "⚠ Не удалось включить registry"; exit 1; }; \
		echo "   Ожидание готовности registry..."; \
		sleep 5; \
	else \
		echo "   ✓ Registry уже включен"; \
	fi
	@if ! microk8s status 2>/dev/null | grep -q "storage"; then \
		echo "   Включение storage..."; \
		microk8s enable storage || { echo "⚠ Не удалось включить storage"; exit 1; }; \
		echo "   Ожидание готовности storage..."; \
		sleep 3; \
	else \
		echo "   ✓ Storage уже включен"; \
	fi
	@if ! microk8s status 2>/dev/null | grep -q "dns"; then \
		echo "   Включение dns..."; \
		microk8s enable dns || { echo "⚠ Не удалось включить dns"; exit 1; }; \
		sleep 2; \
	else \
		echo "   ✓ DNS уже включен"; \
	fi
	@echo "✓ Все необходимые аддоны включены"
	@echo ""
	@echo "4. Применение StorageClass..."
	@if [ -f storageclass.yaml ]; then \
		kubectl apply -f storageclass.yaml && echo "✓ StorageClass применен" || echo "⚠ Не удалось применить StorageClass (возможно, уже существует)"; \
	else \
		echo "⚠ Файл storageclass.yaml не найден, пропускаем"; \
	fi
	@echo ""
	@echo "5. Настройка образов..."
	@if [ -d "$(IMAGES_DIR)" ] && [ -n "$$(ls -A $(IMAGES_DIR)/*.tar 2>/dev/null)" ]; then \
		echo "   Найдены локальные образы, загружаем из файлов..."; \
		$(MAKE) images-sync-from-files || { echo "⚠ Ошибка при загрузке/публикации образов из файлов"; exit 1; }; \
		echo "✓ Образы загружены из tar и опубликованы в локальный registry"; \
	else \
		echo "   Локальные образы не найдены"; \
		echo "   Загружаем образы из внешнего источника и публикуем в registry..."; \
		$(MAKE) images-sync || { echo "⚠ Ошибка при загрузке/публикации образов"; exit 1; }; \
		echo "✓ Образы загружены и опубликованы в локальный registry"; \
	fi
	@echo ""
	@echo "6. Установка Kafka..."
	@$(MAKE) install
	@echo ""
	@echo "=== Установка завершена! ==="
	@echo "Проверьте статус: make status"

# Установить Kafka в namespace
install:
	@if [ -n "$(KUBECONFIG)" ]; then export KUBECONFIG="$(KUBECONFIG)"; fi; \
	echo "Установка Kafka в namespace $(KAFKA_NAMESPACE)..."; \
	kubectl create namespace $(KAFKA_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	@if [ -f $(VALUES_FILE) ]; then \
		echo "Использование файла $(VALUES_FILE)"; \
		helm install $(HELM_RELEASE_NAME) $(CHART_PATH) --namespace $(KAFKA_NAMESPACE) -f $(VALUES_FILE); \
	else \
		echo "Файл $(VALUES_FILE) не найден, установка с дефолтными значениями"; \
		helm install $(HELM_RELEASE_NAME) $(CHART_PATH) --namespace $(KAFKA_NAMESPACE); \
	fi
	@echo ""
	@echo "Установка завершена. Проверьте статус: make status"

# Обновить Helm release Kafka
upgrade:
	@echo "Обновление Helm release $(HELM_RELEASE_NAME)..."
	@if [ -f $(VALUES_FILE) ]; then \
		echo "Использование файла $(VALUES_FILE)"; \
		helm upgrade $(HELM_RELEASE_NAME) $(CHART_PATH) --namespace $(KAFKA_NAMESPACE) -f $(VALUES_FILE); \
	else \
		echo "Файл $(VALUES_FILE) не найден, обновление с дефолтными значениями"; \
		helm upgrade $(HELM_RELEASE_NAME) $(CHART_PATH) --namespace $(KAFKA_NAMESPACE); \
	fi
	@echo ""
	@echo "Обновление завершено. Проверьте статус: make status"

# Удалить Kafka из кластера
uninstall:
	@echo "⚠ ВНИМАНИЕ: Это удалит все данные Kafka!"
	@echo "Удаление Helm release $(HELM_RELEASE_NAME) из namespace $(KAFKA_NAMESPACE)..."
	@read -p "Вы уверены? Это действие необратимо! (y/N): " confirm && \
		if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
			helm uninstall $(HELM_RELEASE_NAME) --namespace $(KAFKA_NAMESPACE) || echo "Helm release не найден"; \
			echo "Kafka удалена из кластера"; \
		else \
			echo "Отменено. Kafka не была удалена."; \
			exit 0; \
		fi

# Показать статус Kafka
status:
	@if [ -n "$(KUBECONFIG)" ]; then export KUBECONFIG="$(KUBECONFIG)"; fi; \
	echo "=== Статус Helm release ==="; \
	helm status $(HELM_RELEASE_NAME) --namespace $(KAFKA_NAMESPACE) 2>/dev/null || echo "Helm release не найден"; \
	echo ""; \
	echo "=== Поды ==="; \
	kubectl get pods -n $(KAFKA_NAMESPACE) -l app.kubernetes.io/name=kafka 2>/dev/null || echo "Поды не найдены"; \
	echo ""; \
	echo "=== Сервисы ==="; \
	kubectl get svc -n $(KAFKA_NAMESPACE) -l app.kubernetes.io/name=kafka 2>/dev/null || echo "Сервисы не найдены"; \
	echo ""; \
	echo "=== PersistentVolumeClaims ==="; \
	kubectl get pvc -n $(KAFKA_NAMESPACE) 2>/dev/null | grep -v "No resources" || echo "PVC не найдены"; \
	echo ""; \
	echo "=== StatefulSets ==="; \
	kubectl get statefulset -n $(KAFKA_NAMESPACE) -l app.kubernetes.io/name=kafka 2>/dev/null || echo "StatefulSets не найдены"

logs:
	@if [ -n "$(KUBECONFIG)" ]; then export KUBECONFIG="$(KUBECONFIG)"; fi; \
	POD=$$(kubectl get pods -n $(KAFKA_NAMESPACE) -l app.kubernetes.io/name=kafka -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then \
		echo "Поды Kafka не найдены"; \
	else \
		echo "Логи пода: $$POD"; \
		kubectl logs -f $$POD -n $(KAFKA_NAMESPACE); \
	fi

shell:
	@if [ -n "$(KUBECONFIG)" ]; then export KUBECONFIG="$(KUBECONFIG)"; fi; \
	POD=$$(kubectl get pods -n $(KAFKA_NAMESPACE) -l app.kubernetes.io/name=kafka -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then \
		echo "Поды Kafka не найдены"; \
		exit 1; \
	else \
		echo "Подключение к поду: $$POD"; \
		kubectl exec -it $$POD -n $(KAFKA_NAMESPACE) -- bash || kubectl exec -it $$POD -n $(KAFKA_NAMESPACE) -- sh; \
	fi

# Проверить, включен ли registry в MicroK8s
check-registry:
	@echo "Проверка MicroK8s registry..."
	@curl -fsS http://$(REGISTRY)/v2/ >/dev/null 2>&1 && \
		echo "✓ Registry доступен: http://$(REGISTRY)/v2/" || \
		(echo "✗ Registry недоступен. Убедитесь, что выполнен: microk8s enable registry" && exit 1)

## =========================
## Images (унифицированные targets)
## =========================

# Проверить доступность всех нужных тегов в docker.io/bitnamilegacy (без fallback)
images-verify:
	@echo "Проверка доступности тегов в docker.io/bitnamilegacy..."
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
		echo "✗ Некоторые теги в bitnamilegacy недоступны. Обновление/пересборка с внешним pull будет невозможна."; \
		exit 1; \
	fi; \
	echo "✓ Все теги доступны в bitnamilegacy"

check-updates: ## Проверить наличие новых версий чарта и образов
	@echo "Проверка обновлений для Kafka..."
	@echo ""
	@CURRENT_CHART=$$(grep '^version:' kafka/Chart.yaml | awk '{print $$2}'); \
	CURRENT_APP=$$(grep '^appVersion:' kafka/Chart.yaml | awk '{print $$2}'); \
	echo "Текущая версия чарта: $$CURRENT_CHART (appVersion: $$CURRENT_APP)"; \
	echo "Текущие теги образов: kafka:$(KAFKA_TAG), os-shell:$(OS_SHELL_TAG), kubectl:$(KUBECTL_TAG), jmx-exporter:$(JMX_EXPORTER_TAG)"; \
	echo ""; \
	echo "Проверка доступных версий чарта..."; \
	if command -v helm >/dev/null 2>&1; then \
		if ! helm repo list 2>/dev/null | grep -q bitnami; then \
			echo "  Добавляю репозиторий bitnami..."; \
			helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true; \
			helm repo update >/dev/null 2>&1 || true; \
		fi; \
		echo "  Поиск последней версии чарта..."; \
		LATEST_CHART=$$(helm search repo bitnami/kafka --versions --output json 2>/dev/null | jq -r '.[0].version' 2>/dev/null || helm search repo bitnami/kafka --versions 2>/dev/null | head -2 | tail -1 | awk '{print $$2}' || echo ""); \
		if [ -n "$$LATEST_CHART" ] && [ "$$LATEST_CHART" != "$$CURRENT_CHART" ]; then \
			echo "  ⚠ Доступна новая версия чарта: $$LATEST_CHART"; \
			echo "  Для проверки образов новой версии выполните:"; \
			echo "    helm show chart bitnami/kafka --version $$LATEST_CHART | grep -A 10 '^annotations:'"; \
		elif [ -n "$$LATEST_CHART" ]; then \
			echo "  ✓ Используется последняя версия чарта: $$CURRENT_CHART"; \
		else \
			echo "  ⚠ Не удалось получить версию чарта"; \
		fi; \
	else \
		echo "  ⚠ helm не установлен, проверка версий чарта пропущена"; \
		echo "  Альтернатива: проверьте https://github.com/bitnami/charts/tree/main/bitnami/kafka"; \
	fi; \
	echo ""; \
	echo "Примечание: После обновления чарта проверьте теги образов в Chart.yaml новой версии"

# Скачать все образы
images-pull:
	@echo "Загрузка образов (bitnamilegacy -> bitnami fallback)..."
	@if docker pull $(KAFKA_IMAGE_SRC) 2>/dev/null; then echo "✓ $(KAFKA_IMAGE_SRC)"; else docker pull docker.io/bitnami/kafka:$(KAFKA_TAG); docker tag docker.io/bitnami/kafka:$(KAFKA_TAG) $(KAFKA_IMAGE_SRC); fi
	@if docker pull $(OS_SHELL_IMAGE_SRC) 2>/dev/null; then echo "✓ $(OS_SHELL_IMAGE_SRC)"; else docker pull docker.io/bitnami/os-shell:$(OS_SHELL_TAG); docker tag docker.io/bitnami/os-shell:$(OS_SHELL_TAG) $(OS_SHELL_IMAGE_SRC); fi
	@if docker pull $(KUBECTL_IMAGE_SRC) 2>/dev/null; then echo "✓ $(KUBECTL_IMAGE_SRC)"; else docker pull docker.io/bitnami/kubectl:$(KUBECTL_TAG); docker tag docker.io/bitnami/kubectl:$(KUBECTL_TAG) $(KUBECTL_IMAGE_SRC); fi
	@if docker pull $(JMX_EXPORTER_IMAGE_SRC) 2>/dev/null; then echo "✓ $(JMX_EXPORTER_IMAGE_SRC)"; else docker pull docker.io/bitnami/jmx-exporter:$(JMX_EXPORTER_TAG); docker tag docker.io/bitnami/jmx-exporter:$(JMX_EXPORTER_TAG) $(JMX_EXPORTER_IMAGE_SRC); fi
	@echo "✓ Все образы загружены"

# Тегировать для локального registry
images-tag: images-pull
	@echo "Тегирование образов для $(REGISTRY)/bitnami/* ..."
	@docker tag $(KAFKA_IMAGE_SRC) $(KAFKA_IMAGE_LOCAL)
	@docker tag $(OS_SHELL_IMAGE_SRC) $(OS_SHELL_IMAGE_LOCAL)
	@docker tag $(KUBECTL_IMAGE_SRC) $(KUBECTL_IMAGE_LOCAL)
	@docker tag $(JMX_EXPORTER_IMAGE_SRC) $(JMX_EXPORTER_IMAGE_LOCAL)
	@echo "✓ Теги готовы"

# Push в registry
images-push: check-registry images-tag
	@echo "Публикация образов в registry $(REGISTRY)..."
	@docker push $(KAFKA_IMAGE_LOCAL)
	@docker push $(OS_SHELL_IMAGE_LOCAL)
	@docker push $(KUBECTL_IMAGE_LOCAL)
	@docker push $(JMX_EXPORTER_IMAGE_LOCAL)
	@echo "✓ Все образы опубликованы"

# pull + tag + push
images-sync: images-push
	@echo "✓ Images sync completed"

# Сохранить все образы в tar
images-save: images-pull
	@echo "Сохранение Docker образов в файлы..."
	@mkdir -p $(IMAGES_DIR)
	@docker save $(KAFKA_IMAGE_SRC) -o $(IMAGES_DIR)/kafka-$(KAFKA_TAG).tar
	@docker save $(OS_SHELL_IMAGE_SRC) -o $(IMAGES_DIR)/os-shell-$(OS_SHELL_TAG).tar
	@docker save $(KUBECTL_IMAGE_SRC) -o $(IMAGES_DIR)/kubectl-$(KUBECTL_TAG).tar
	@docker save $(JMX_EXPORTER_IMAGE_SRC) -o $(IMAGES_DIR)/jmx-exporter-$(JMX_EXPORTER_TAG).tar
	@echo "✓ Образы сохранены в $(IMAGES_DIR)/"

# Загрузить образы из tar
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

# Совместимость со старыми именами target'ов
pull-images: images-pull
tag-images: images-tag
push-images: images-push
load-images: images-sync
save-images: images-save
load-images-from-file: images-load
clean: images-clean
clean-images-files: images-clean-files

setup-local-registry: images-sync
	@echo "Готово. Установите/обновите релиз с values-файлом (по умолчанию $(VALUES_FILE))."

# Очистить локальные образы
# (clean/clean-images-files переопределены через алиасы выше)

# Создать client.properties файл для аутентификации
test-client-properties:
	@echo "Создание client.properties файла..."
	@PASSWORD=$$(kubectl get secret kafka-user-passwords --namespace $(KAFKA_NAMESPACE) -o jsonpath='{.data.client-passwords}' 2>/dev/null | base64 -d | cut -d, -f1); \
	if [ -z "$$PASSWORD" ]; then \
		echo "✗ Не удалось получить пароль из секрета"; \
		exit 1; \
	fi; \
	echo "security.protocol=SASL_PLAINTEXT" > /tmp/client.properties; \
	echo "sasl.mechanism=SCRAM-SHA-256" >> /tmp/client.properties; \
	echo "sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required \\" >> /tmp/client.properties; \
	echo "    username=\"user1\" \\" >> /tmp/client.properties; \
	echo "    password=\"$$PASSWORD\";" >> /tmp/client.properties; \
	echo "✓ Файл client.properties создан в /tmp/client.properties"

# Создать тестовый топик (если не существует)
test-create-topic:
	@echo "Создание тестового топика $(KAFKA_TOPIC)..."
	@PASSWORD=$$(kubectl get secret kafka-user-passwords --namespace $(KAFKA_NAMESPACE) -o jsonpath='{.data.client-passwords}' 2>/dev/null | base64 -d | cut -d, -f1); \
	if [ -z "$$PASSWORD" ]; then \
		echo "✗ Не удалось получить пароль из секрета"; \
		exit 1; \
	fi; \
	kubectl run kafka-admin-$$(date +%s) \
		--restart='Never' \
		--image=$(KAFKA_IMAGE_LOCAL) \
		--namespace=$(KAFKA_NAMESPACE) \
		--rm -i --env="KAFKA_PASSWORD=$$PASSWORD" --command -- bash -c "\
			echo 'security.protocol=SASL_PLAINTEXT' > /tmp/client.properties && \
			echo 'sasl.mechanism=SCRAM-SHA-256' >> /tmp/client.properties && \
			echo \"sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\\\"user1\\\" password=\\\"\$$KAFKA_PASSWORD\\\";\" >> /tmp/client.properties && \
			echo 'Проверка существования топика...' && \
			if kafka-topics.sh --list --bootstrap-server $(KAFKA_BOOTSTRAP_SERVER) --command-config /tmp/client.properties 2>/dev/null | grep -q '^$(KAFKA_TOPIC)$$'; then \
				echo '✓ Топик $(KAFKA_TOPIC) уже существует'; \
			else \
				echo 'Создание топика $(KAFKA_TOPIC)...' && \
				kafka-topics.sh --create \
					--bootstrap-server $(KAFKA_BOOTSTRAP_SERVER) \
					--command-config /tmp/client.properties \
					--topic $(KAFKA_TOPIC) \
					--partitions 3 \
					--replication-factor 1 && \
				echo '✓ Топик $(KAFKA_TOPIC) успешно создан'; \
			fi \
		" 2>/dev/null || echo "⚠ Не удалось создать или проверить топик"

# Запустить тестовый producer
test-producer: test-client-properties test-create-topic
	@echo "Запуск тестового producer для топика $(KAFKA_TOPIC)..."
	@echo "Остановка старых producer подов..."
	@-kubectl get pods -n $(KAFKA_NAMESPACE) --no-headers 2>/dev/null | grep "^kafka-producer-" | awk '{print $$1}' | xargs -r kubectl delete pod -n $(KAFKA_NAMESPACE) 2>/dev/null || true
	@echo "Автоматическая отправка пинг-сообщений каждые 2 секунды (Ctrl+C для остановки)"
	@PASSWORD=$$(kubectl get secret kafka-user-passwords --namespace $(KAFKA_NAMESPACE) -o jsonpath='{.data.client-passwords}' 2>/dev/null | base64 -d | cut -d, -f1); \
	if [ -z "$$PASSWORD" ]; then \
		echo "✗ Не удалось получить пароль из секрета"; \
		exit 1; \
	fi; \
	kubectl run kafka-producer-$$(date +%s) \
		--restart='Never' \
		--image=$(KAFKA_IMAGE_LOCAL) \
		--namespace=$(KAFKA_NAMESPACE) \
		--rm -i --env="KAFKA_PASSWORD=$$PASSWORD" --command -- bash -c "\
			echo 'security.protocol=SASL_PLAINTEXT' > /tmp/client.properties && \
			echo 'sasl.mechanism=SCRAM-SHA-256' >> /tmp/client.properties && \
			echo \"sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\\\"user1\\\" password=\\\"\$$KAFKA_PASSWORD\\\";\" >> /tmp/client.properties && \
			echo 'Запуск автоматической отправки сообщений...' && \
			while true; do \
				MSG=\"PING \$$(date +'%Y-%m-%d %H:%M:%S')\"; \
				echo \"\$$MSG\" | kafka-console-producer.sh \
					--producer.config /tmp/client.properties \
					--bootstrap-server $(KAFKA_BOOTSTRAP_SERVER) \
					--topic $(KAFKA_TOPIC) \
					2>/dev/null && echo \"[$$(date +'%H:%M:%S')] Отправлено: \$$MSG\" || echo \"[$$(date +'%H:%M:%S')] Ошибка отправки\"; \
				sleep 2; \
			done \
		"

# Запустить тестовый consumer
# Использование: make test-consumer [FROM_BEGINNING=true] для чтения с начала
test-consumer: test-client-properties test-create-topic
	@echo "Запуск тестового consumer для топика $(KAFKA_TOPIC)..."
	@echo "Остановка старых consumer подов..."
	@-kubectl delete pod -l run=kafka-consumer --namespace $(KAFKA_NAMESPACE) 2>/dev/null || true
	@if [ "$(FROM_BEGINNING)" = "true" ]; then \
		echo "Чтение сообщений с начала топика (--from-beginning)..."; \
		FROM_BEGINNING_FLAG="--from-beginning"; \
	else \
		echo "Чтение сообщений с последнего offset (offset будет сохраняться)..."; \
		FROM_BEGINNING_FLAG=""; \
	fi; \
	echo "Используется группа: test-consumer-group"; \
	PASSWORD=$$(kubectl get secret kafka-user-passwords --namespace $(KAFKA_NAMESPACE) -o jsonpath='{.data.client-passwords}' 2>/dev/null | base64 -d | cut -d, -f1); \
	if [ -z "$$PASSWORD" ]; then \
		echo "✗ Не удалось получить пароль из секрета"; \
		exit 1; \
	fi; \
	kubectl run kafka-consumer-$$(date +%s) \
		--restart='Never' \
		--image=$(KAFKA_IMAGE_LOCAL) \
		--namespace=$(KAFKA_NAMESPACE) \
		--rm -i --env="KAFKA_PASSWORD=$$PASSWORD" --env="FROM_BEGINNING_FLAG=$$FROM_BEGINNING_FLAG" --command -- bash -c "\
			echo 'security.protocol=SASL_PLAINTEXT' > /tmp/client.properties && \
			echo 'sasl.mechanism=SCRAM-SHA-256' >> /tmp/client.properties && \
			echo \"sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\\\"user1\\\" password=\\\"\$$KAFKA_PASSWORD\\\";\" >> /tmp/client.properties && \
			kafka-console-consumer.sh \
				--consumer.config /tmp/client.properties \
				--bootstrap-server $(KAFKA_BOOTSTRAP_SERVER) \
				--topic $(KAFKA_TOPIC) \
				--group test-consumer-group \
				\$$FROM_BEGINNING_FLAG \
		"

# Очистить тестовые ресурсы
test-clean:
	@echo "Удаление тестовых подов и файлов..."
	@echo "Удаление всех kafka-producer подов..."
	@-kubectl get pods -n $(KAFKA_NAMESPACE) --no-headers 2>/dev/null | grep "^kafka-producer-" | awk '{print $$1}' | xargs -r kubectl delete pod -n $(KAFKA_NAMESPACE) 2>/dev/null || true
	@echo "Удаление всех kafka-consumer подов..."
	@-kubectl get pods -n $(KAFKA_NAMESPACE) --no-headers 2>/dev/null | grep "^kafka-consumer-" | awk '{print $$1}' | xargs -r kubectl delete pod -n $(KAFKA_NAMESPACE) 2>/dev/null || true
	@echo "Удаление всех kafka-admin подов..."
	@-kubectl get pods -n $(KAFKA_NAMESPACE) --no-headers 2>/dev/null | grep "^kafka-admin-" | awk '{print $$1}' | xargs -r kubectl delete pod -n $(KAFKA_NAMESPACE) 2>/dev/null || true
	@-rm -f /tmp/client.properties 2>/dev/null || true
	@echo "✓ Тестовые ресурсы удалены"

