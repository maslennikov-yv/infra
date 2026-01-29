.PHONY: help install upgrade uninstall status logs port-forward top-nodes events pod-events describe-pod

NAMESPACE ?= monitoring
RELEASE ?= netdata
CHART_PATH ?= netdata
ENV ?= dev
VALUES_FILE ?= values-$(ENV).yaml

help:
	@echo "Netdata monitoring:"
	@echo "  make install         - Установить Netdata"
	@echo "  make upgrade         - Обновить Netdata"
	@echo "  make uninstall       - Удалить Netdata"
	@echo "  make status          - Статус Netdata"
	@echo "  make logs            - Логи Netdata"
	@echo "  make port-forward    - Локальный доступ: http://localhost:19999"
	@echo ""
	@echo "Диагностика (Pending/ресурсы):"
	@echo "  make top-nodes       - Использование CPU/памяти на нодах"
	@echo "  make events         - Последние события в namespace monitoring"
	@echo "  make pod-events      - События по поду Netdata [POD=имя-пода]"
	@echo "  make describe-pod    - describe пода Netdata [POD=имя-пода]"

install:
	@helm upgrade --install $(RELEASE) $(CHART_PATH) \
		-n $(NAMESPACE) --create-namespace \
		-f $(VALUES_FILE)

upgrade:
	@helm upgrade $(RELEASE) $(CHART_PATH) \
		-n $(NAMESPACE) \
		-f $(VALUES_FILE)

uninstall:
	@helm uninstall $(RELEASE) -n $(NAMESPACE)

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
