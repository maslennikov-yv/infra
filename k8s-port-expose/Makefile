# microk8s nginx ingress TCP: DaemonSet hostPort + ConfigMap nginx-ingress-tcp-microk8s-conf
.PHONY: help show patch patch-tcp patch-hostport apply-config

ENV ?= local
REPO_ROOT ?= $(abspath $(CURDIR)/..)
# полный путь к YAML; пусто → scripts/k8s-port-expose-apply-config.sh подставит k8s-port-expose/ports-$(ENV).yaml
PORT_EXPOSE_CONFIG ?=
INGRESS_NS ?= ingress
INGRESS_DS ?= nginx-ingress-microk8s-controller
INGRESS_TCP_CM ?= nginx-ingress-tcp-microk8s-conf
INGRESS_CONTAINER ?= nginx-ingress-microk8s

LAYER ?=
HOST_PORT ?=
BACKEND ?=
RM ?=
OP ?=
CONTAINER_PORT ?=
PORT_NAME ?=
PROTO ?= TCP

# пусто | client | server (kubectl patch --dry-run=…)
DRY_RUN ?=

ifneq ($(strip $(DRY_RUN)),)
ifeq ($(filter $(DRY_RUN),client server),)
$(error DRY_RUN должен быть пусто, client или server (сейчас: $(DRY_RUN)))
endif
endif

KUBECTL_DRY :=
ifneq ($(strip $(DRY_RUN)),)
KUBECTL_DRY := --dry-run=$(DRY_RUN)
endif

YELLOW := \033[0;33m
RESET := \033[0m

help:
	@echo "k8s port expose (microk8s ingress TCP)"
	@echo "  с корня репо: make k8s-port-expose-show / k8s-port-expose-patch / k8s-port-expose-apply"
	@echo "  make show $(YELLOW)ENV=$(ENV)$(RESET)  - DaemonSet и TCP ConfigMap в $(INGRESS_NS)"
	@echo "  make patch $(YELLOW)ENV=$(ENV) LAYER=tcp HOST_PORT=1883 BACKEND=myns/mysvc:1883$(RESET)"
	@echo "  make patch $(YELLOW)ENV=$(ENV) LAYER=tcp HOST_PORT=1883 RM=1$(RESET)  - удалить ключ из ConfigMap"
	@echo "  make patch $(YELLOW)ENV=$(ENV) LAYER=hostport OP=add ...$(RESET)"
	@echo "  make patch $(YELLOW)ENV=$(ENV) LAYER=hostport OP=rm HOST_PORT=1883$(RESET) - убрать hostPort из DS"
	@echo "  make apply-config $(YELLOW)ENV=$(ENV)$(RESET) [$(YELLOW)PORT_EXPOSE_CONFIG=...$(RESET)] — YAML → кластер ($(YELLOW)scripts/k8s-port-expose-apply-config.sh$(RESET))"
	@echo "  опции: $(YELLOW)DRY_RUN=client|server$(RESET) — без записи в API (server строже admission)"
	@echo ""

apply-config:
	@command -v kubectl >/dev/null 2>&1 || { echo "✗ kubectl не найден"; exit 1; }
	@command -v jq >/dev/null 2>&1 || { echo "✗ нужен jq"; exit 1; }
	@"$(REPO_ROOT)/scripts/apps-yq-probe.sh"
	@ENV="$(ENV)" REPO_ROOT="$(REPO_ROOT)" PORT_EXPOSE_CONFIG="$(PORT_EXPOSE_CONFIG)" \
		INGRESS_NS="$(INGRESS_NS)" INGRESS_DS="$(INGRESS_DS)" INGRESS_TCP_CM="$(INGRESS_TCP_CM)" INGRESS_CONTAINER="$(INGRESS_CONTAINER)" \
		DRY_RUN="$(DRY_RUN)" \
		"$(REPO_ROOT)/scripts/k8s-port-expose-apply-config.sh"

show:
	@command -v kubectl >/dev/null 2>&1 || { echo "✗ kubectl не найден"; exit 1; }
	@echo "=== DaemonSet/$(INGRESS_DS) ($(INGRESS_NS)) ==="
	@kubectl get daemonset "$(INGRESS_DS)" -n "$(INGRESS_NS)" -o yaml
	@echo ""
	@echo "=== ConfigMap/$(INGRESS_TCP_CM) ($(INGRESS_NS)) ==="
	@kubectl get configmap "$(INGRESS_TCP_CM)" -n "$(INGRESS_NS)" -o yaml

patch:
	@command -v kubectl >/dev/null 2>&1 || { echo "✗ kubectl не найден"; exit 1; }
	@command -v jq >/dev/null 2>&1 || { echo "✗ нужен jq (patch JSON)"; exit 1; }
	@if [ -z "$(strip $(LAYER))" ]; then \
		echo "✗ укажите LAYER=tcp или LAYER=hostport"; \
		echo "  см. make -C k8s-port-expose help"; \
		exit 1; \
	fi
	@[ -z "$(DRY_RUN)" ] || printf '%b\n' "$(YELLOW)↳ dry-run=$(DRY_RUN) (изменения не сохраняются)$(RESET)"
	@if [ "$(LAYER)" = "tcp" ]; then \
		$(MAKE) --no-print-directory -C "$(CURDIR)" patch-tcp; \
	elif [ "$(LAYER)" = "hostport" ]; then \
		$(MAKE) --no-print-directory -C "$(CURDIR)" patch-hostport; \
	else \
		echo "✗ LAYER=$(LAYER) не поддерживается (ожидается tcp или hostport)"; \
		exit 1; \
	fi

# HOST_PORT: 1–65535
patch-tcp:
	@if [ -z "$(strip $(HOST_PORT))" ]; then echo "✗ для LAYER=tcp нужен HOST_PORT"; exit 1; fi
	@HP_OK=$$(jq -n --arg hp "$(HOST_PORT)" 'try (($$hp | tonumber) as $$n | ($$n >= 1 and $$n <= 65535)) catch false'); \
	if [ "$$HP_OK" != "true" ]; then echo "✗ HOST_PORT: ожидается целое число 1–65535"; exit 1; fi
	@if [ "$(RM)" = "1" ]; then \
		PATCH=$$(jq -n --arg hp "$(HOST_PORT)" '[{"op":"remove","path":("/data/" + $$hp)}]'); \
		kubectl patch configmap "$(INGRESS_TCP_CM)" -n "$(INGRESS_NS)" --type=json -p "$$PATCH" $(KUBECTL_DRY); \
	else \
		if [ -z "$(strip $(BACKEND))" ]; then echo "✗ для LAYER=tcp без RM=1 нужен BACKEND=<ns>/<svc>:<port>"; exit 1; fi; \
		BE_OK=$$(jq -n --arg b "$(BACKEND)" 'try ($$b | capture("^(?<ns>[^/]+)/(?<svc>[^:]+):(?<port>[0-9]+)$$") | (.port | tonumber) as $$p | ($$p >= 1 and $$p <= 65535)) catch false'); \
		if [ "$$BE_OK" != "true" ]; then echo "✗ BACKEND: ожидается ns/svc:port (порт 1–65535), без лишних «/» и «:»"; exit 1; fi; \
		MERGE=$$(jq -n --arg hp "$(HOST_PORT)" --arg be "$(BACKEND)" '{"data":{($$hp):$$be}}'); \
		kubectl patch configmap "$(INGRESS_TCP_CM)" -n "$(INGRESS_NS)" --type=merge -p "$$MERGE" $(KUBECTL_DRY); \
	fi

patch-hostport:
	@if [ -z "$(strip $(HOST_PORT))" ]; then echo "✗ для LAYER=hostport нужен HOST_PORT"; exit 1; fi
	@if [ "$(OP)" != "add" ] && [ "$(OP)" != "rm" ]; then echo "✗ для LAYER=hostport нужен OP=add или OP=rm"; exit 1; fi
	@case "$(PROTO)" in TCP|UDP|SCTP) ;; *) echo "✗ PROTO должен быть TCP, UDP или SCTP (сейчас: $(PROTO))"; exit 1;; esac
	@HP_OK=$$(jq -n --arg hp "$(HOST_PORT)" 'try (($$hp | tonumber) as $$n | ($$n >= 1 and $$n <= 65535)) catch false'); \
	if [ "$$HP_OK" != "true" ]; then echo "✗ HOST_PORT: ожидается целое число 1–65535"; exit 1; fi
	@set -e; \
	DS_JSON=$$(kubectl get daemonset "$(INGRESS_DS)" -n "$(INGRESS_NS)" -o json); \
	CI=$$(echo "$$DS_JSON" | jq -r --arg cn "$(INGRESS_CONTAINER)" '(.spec.template.spec.containers | map(.name) | index($$cn)) // empty'); \
	if [ -z "$$CI" ]; then \
		echo "✗ контейнер \"$(INGRESS_CONTAINER)\" не найден в DaemonSet"; \
		exit 1; \
	fi; \
	if [ "$(OP)" = "add" ]; then \
		if [ -z "$(strip $(CONTAINER_PORT))" ]; then echo "✗ для OP=add нужен CONTAINER_PORT"; exit 1; fi; \
		if [ -z "$(strip $(PORT_NAME))" ]; then echo "✗ для OP=add нужен PORT_NAME"; exit 1; fi; \
		CP_OK=$$(jq -n --arg cp "$(CONTAINER_PORT)" 'try (($$cp | tonumber) as $$n | ($$n >= 1 and $$n <= 65535)) catch false'); \
		if [ "$$CP_OK" != "true" ]; then echo "✗ CONTAINER_PORT: ожидается целое число 1–65535"; exit 1; fi; \
		NHP=$$(echo "$$DS_JSON" | jq --argjson ci "$$CI" --argjson hp "$(HOST_PORT)" '[.spec.template.spec.containers[$$ci].ports[]? | select(.hostPort == $$hp)] | length'); \
		if [ "$$NHP" != "0" ]; then echo "✗ hostPort $(HOST_PORT) уже объявлен у контейнера $(INGRESS_CONTAINER)"; exit 1; fi; \
		NPN=$$(echo "$$DS_JSON" | jq --argjson ci "$$CI" --arg pn "$(PORT_NAME)" '[.spec.template.spec.containers[$$ci].ports[]? | select(.name == $$pn)] | length'); \
		if [ "$$NPN" != "0" ]; then echo "✗ PORT_NAME $(PORT_NAME) уже занят в контейнере $(INGRESS_CONTAINER)"; exit 1; fi; \
		PATCH=$$(jq -n \
			--argjson ci "$$CI" \
			--argjson cport "$(CONTAINER_PORT)" \
			--argjson hport "$(HOST_PORT)" \
			--arg pn "$(PORT_NAME)" \
			--arg proto "$(PROTO)" \
			'[{"op":"add","path": ("/spec/template/spec/containers/" + ($$ci | tostring) + "/ports/-"), "value":{"containerPort": $$cport, "hostPort": $$hport, "name": $$pn, "protocol": $$proto}}]'); \
		kubectl patch daemonset "$(INGRESS_DS)" -n "$(INGRESS_NS)" --type=json -p "$$PATCH" $(KUBECTL_DRY); \
	else \
		PI=$$(echo "$$DS_JSON" | jq -r --argjson ci "$$CI" --argjson hp "$(HOST_PORT)" \
			'.spec.template.spec.containers[$$ci].ports | to_entries[] | select(.value.hostPort == $$hp) | .key' | head -n1); \
		if [ -z "$$PI" ]; then echo "✗ порт hostPort=$(HOST_PORT) не найден у контейнера"; exit 1; fi; \
		PATCH=$$(jq -n \
			--argjson ci "$$CI" \
			--argjson pi "$$PI" \
			'[{"op":"remove","path": ("/spec/template/spec/containers/" + ($$ci | tostring) + "/ports/" + ($$pi | tostring))}]'); \
		kubectl patch daemonset "$(INGRESS_DS)" -n "$(INGRESS_NS)" --type=json -p "$$PATCH" $(KUBECTL_DRY); \
	fi
