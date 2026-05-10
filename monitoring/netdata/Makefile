# Используется bash (не dash) — для read -p и совместимости с другими сервисами.
SHELL := /bin/bash

.PHONY: help install upgrade uninstall status logs port-forward top-nodes events pod-events describe-pod \
	images-verify images-pull images-tag images-push images-sync images-save images-load images-sync-from-files images-clean images-clean-files \
	check-registry

NAMESPACE ?= monitoring
RELEASE ?= netdata
CHART_PATH ?= netdata
ENV ?= local
VALUES_FILE ?= values-$(ENV).yaml

# Локальный registry MicroK8s
REGISTRY ?= localhost:32000

# Image tags pinned (см. netdata/values.yaml — moving `stable` → конкретная версия)
NETDATA_TAG ?= v2.10.3
NETDATA_SRC_TAG ?= $(NETDATA_TAG)

# Source images (docker.io/netdata/netdata) и локальные перетегированные ($(REGISTRY)/netdata/netdata)
NETDATA_IMAGE_SRC := docker.io/netdata/netdata:$(NETDATA_SRC_TAG)
NETDATA_IMAGE_LOCAL := $(REGISTRY)/netdata/netdata:$(NETDATA_TAG)

IMAGES_SRC := $(NETDATA_IMAGE_SRC)
IMAGES_LOCAL := $(NETDATA_IMAGE_LOCAL)

IMAGES_DIR ?= images

help:
	@echo "Netdata monitoring:"
	@echo "  make install         - Установить Netdata"
	@echo "  make upgrade         - Обновить Netdata"
	@echo "  make uninstall       - Удалить Netdata (с подтверждением)"
	@echo "  make status          - Статус Netdata"
	@echo "  make logs            - Логи Netdata"
	@echo "  make port-forward    - Локальный доступ: http://localhost:19999"
	@echo ""
	@echo "Диагностика (Pending/ресурсы):"
	@echo "  make top-nodes       - Использование CPU/памяти на нодах"
	@echo "  make events          - Последние события в namespace monitoring"
	@echo "  make pod-events      - События по поду Netdata [POD=имя-пода]"
	@echo "  make describe-pod    - describe пода Netdata [POD=имя-пода]"
	@echo ""
	@echo "Images (offline / microk8s registry):"
	@echo "  make check-registry         - Проверить доступность $(REGISTRY)"
	@echo "  make images-verify          - Проверить SRC-теги в docker.io"
	@echo "  make images-pull            - Скачать образы из docker.io"
	@echo "  make images-tag             - Тегировать для $(REGISTRY)/netdata/*"
	@echo "  make images-push            - Загрузить в microk8s registry"
	@echo "  make images-sync            - pull + tag + push"
	@echo "  make images-save            - Сохранить в tar (директория $(IMAGES_DIR)/)"
	@echo "  make images-load            - Загрузить из tar"
	@echo "  make images-sync-from-files - load + tag + push"
	@echo "  make images-clean           - Удалить локальные docker-образы"
	@echo "  make images-clean-files     - Удалить сохраненные tar"

install:
	@helm upgrade --install $(RELEASE) $(CHART_PATH) \
		-n $(NAMESPACE) --create-namespace \
		-f $(VALUES_FILE)

upgrade:
	@helm upgrade $(RELEASE) $(CHART_PATH) \
		-n $(NAMESPACE) \
		-f $(VALUES_FILE)

uninstall:
	@echo "⚠ ВНИМАНИЕ: Это удалит Helm release $(RELEASE) из namespace $(NAMESPACE)."
	@echo "  Netdata stateless (cache/lib emptyDir), данных потерь нет."
	@echo "  Останутся cluster-scoped ресурсы (helm не подчищает их при uninstall):"
	@echo "    - ClusterRole / ClusterRoleBinding $(RELEASE)"
	@echo "  Полная зачистка:"
	@echo "    kubectl delete clusterrolebinding $(RELEASE) --ignore-not-found"
	@echo "    kubectl delete clusterrole        $(RELEASE) --ignore-not-found"
	@read -p "Вы уверены? (y/N): " confirm && \
		if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
			helm uninstall $(RELEASE) -n $(NAMESPACE) || echo "Helm release не найден"; \
		else \
			echo "Отменено."; \
			exit 0; \
		fi

status:
	@helm status $(RELEASE) -n $(NAMESPACE)
	@kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE)

logs:
	@kubectl logs -n $(NAMESPACE) deploy/$(RELEASE) -f

port-forward:
	@kubectl port-forward -n $(NAMESPACE) svc/$(RELEASE) 19999:19999

# Использование CPU/памяти на нодах (помогает понять, почему под в Pending)
top-nodes:
	@OUT=$$(kubectl top nodes 2>&1); EXIT=$$?; \
	if [ $$EXIT -ne 0 ]; then \
		echo "$$OUT"; \
		if echo "$$OUT" | grep -qi "Metrics API not available"; then \
			echo ""; \
			echo "Metrics API недоступен. Включите metrics-server:"; \
			echo "  Локальный microk8s: microk8s enable metrics-server"; \
			echo "  Удалённый сервер:   make microk8s-setup ENV=prod"; \
			echo "  После включения подождите 1–2 минуты и повторите команду."; \
		fi; \
		exit $$EXIT; \
	fi; \
	echo "$$OUT"

# Последние события в namespace monitoring
events:
	@kubectl get events -n $(NAMESPACE) --sort-by='.lastTimestamp' | tail -30

# События по конкретному поду Netdata (причина Pending и т.д.)
# Использование: make pod-events или make pod-events POD=netdata-57c4cc8d96-29n5f
pod-events:
	@POD=$$(if [ -n "$(POD)" ]; then echo "$(POD)"; else kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE) -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; fi); \
	if [ -z "$$POD" ]; then \
		echo "Поды Netdata не найдены. Укажите POD=имя-пода"; \
		exit 1; \
	fi; \
	echo "События по поду: $$POD"; \
	kubectl get events -n $(NAMESPACE) --field-selector involvedObject.name=$$POD --sort-by='.lastTimestamp'

# describe пода Netdata (детали, условия, события)
describe-pod:
	@POD=$$(if [ -n "$(POD)" ]; then echo "$(POD)"; else kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE) -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; fi); \
	if [ -z "$$POD" ]; then \
		echo "Поды Netdata не найдены. Укажите POD=имя-пода"; \
		exit 1; \
	fi; \
	kubectl describe pod $$POD -n $(NAMESPACE)

## =========================
## Images (offline / microk8s registry)
## =========================

check-registry:
	@echo "Проверка MicroK8s registry..."
	@curl -fsS http://$(REGISTRY)/v2/ >/dev/null 2>&1 && \
		echo "✓ Registry доступен: http://$(REGISTRY)/v2/" || \
		(echo "✗ Registry недоступен. Убедитесь, что выполнен: microk8s enable registry" && exit 1)

images-verify:
	@# Проверяем SRC-теги (то, что реально pull-ится). Pin'нутый v2.10.3 — immutable;
	@# `stable` обновляется поверх него и в этой проверке не используется.
	@echo "Проверка доступности SRC-тегов в docker.io..."
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
		echo "✗ Некоторые SRC-теги недоступны."; \
		echo "  Подсказка: проверьте/обновите NETDATA_SRC_TAG в Makefile (см. https://hub.docker.com/r/netdata/netdata/tags)."; \
		exit 1; \
	fi; \
	echo "✓ Все SRC-теги доступны"

images-pull:
	@echo "Загрузка образов из docker.io..."
	@docker pull $(NETDATA_IMAGE_SRC)
	@echo "✓ Все образы загружены"

images-tag: images-pull
	@docker tag $(NETDATA_IMAGE_SRC) $(NETDATA_IMAGE_LOCAL)

images-push: check-registry images-tag
	@docker push $(NETDATA_IMAGE_LOCAL)

images-sync: images-push

images-save: images-pull
	@mkdir -p $(IMAGES_DIR)
	@docker save $(NETDATA_IMAGE_SRC) -o $(IMAGES_DIR)/netdata-$(NETDATA_TAG).tar

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
