#!/usr/bin/env bash
# Генерирует рыбу infra-interface для приложения в apps/src/<APP>/:
#   infra-interface.yaml             — декларация методов (v1, все 7)
#   Makefile.infra                   — стабы infra-* целей (include в Makefile приложения),
#                                      включая render values.yaml.gotmpl через gomplate (APP_CONFIG)
#   Makefile                         — минимальный (только если ещё не существует)
#   deploy/helm/values.yaml.gotmpl   — пример шаблона values c подстановкой из APP_CONFIG
#                                      (создаётся, только если такого файла ещё нет)
#
# Использование: app-interface-init.sh <REPO_ROOT> <APP>
# OVERWRITE=1  — перезаписать уже существующие infra-interface.yaml / Makefile.infra
set -euo pipefail

REPO_ROOT="${1:?REPO_ROOT}"
APP_RAW="${2:?APP}"

if [[ ! "$APP_RAW" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]]; then
	echo '✗ APP: латиница (a–z), цифры, - и _; первый символ — буква или цифра; длина до 63.' >&2
	exit 1
fi
APP="$APP_RAW"

SRC_DIR="$REPO_ROOT/apps/src/$APP"
IFACE_FILE="$SRC_DIR/infra-interface.yaml"
MK_INFRA="$SRC_DIR/Makefile.infra"
MK_FILE="$SRC_DIR/Makefile"
GOTMPL_FILE="$SRC_DIR/deploy/helm/values.yaml.gotmpl"
OVERWRITE="${OVERWRITE:-0}"

if [[ ! -d "$SRC_DIR" ]]; then
	echo "✗ apps/src/$APP/ не найден." >&2
	echo "  Запустите: make apps-src-clone APP=$APP" >&2
	exit 1
fi

SKIP_IFACE=0
SKIP_MK_INFRA=0

if [[ -f "$IFACE_FILE" ]]; then
	if [[ "$OVERWRITE" == "1" ]]; then
		echo "⚠  infra-interface.yaml уже существует — перезаписываем (OVERWRITE=1)."
	else
		echo "⚠  infra-interface.yaml уже существует — пропущен. OVERWRITE=1 для перезаписи."
		SKIP_IFACE=1
	fi
fi

if [[ -f "$MK_INFRA" ]]; then
	if [[ "$OVERWRITE" == "1" ]]; then
		echo "⚠  Makefile.infra уже существует — перезаписываем (OVERWRITE=1)."
	else
		echo "⚠  Makefile.infra уже существует — пропущен. OVERWRITE=1 для перезаписи."
		SKIP_MK_INFRA=1
	fi
fi

# === infra-interface.yaml ===
if [[ "$SKIP_IFACE" == "0" ]]; then
	cat >"$IFACE_FILE" <<'YAML'
# Декларация infra-interface для приложения.
# Оставьте только те методы, которые реализованы в Makefile.infra.
# Документация: docs/runbooks/app-interface.md
version: 1
implements:
  - deploy
  - rollback
  - status
  - logs
  - migrate
  - seed
  - shell
YAML
	echo "✓ infra-interface.yaml → apps/src/$APP/infra-interface.yaml"
fi

# === Makefile.infra ===
if [[ "$SKIP_MK_INFRA" == "0" ]]; then
	cat >"$MK_INFRA" <<'MAKEFILE'
# infra-interface v1 — стабы lifecycle-методов.
# Включите в Makefile приложения: include Makefile.infra
#
# Переменные, которые infra передаёт при каждом вызове:
#   ENV            — окружение (local / prod / stage / …)
#   KUBECONFIG     — абсолютный путь к kubeconfig
#   APP            — имя приложения
#   APP_NS         — kubernetes namespace (= app_ns из registry или APP)
#   APPS_REGISTRY  — путь к apps/registry.yaml
#   APP_CONFIG     — merged YAML (registry + apps/conf/<APP>/<ENV>/) для подстановки в values.yaml.gotmpl
#
# Дополнительные переменные по методу:
#   rollback: REVISION (номер ревизии; пустой = откат к предыдущей)
#   logs:     FOLLOW=1, CONTAINER
#   shell:    CONTAINER

APP      ?= app
APP_NS   ?= $(APP)
RELEASE  := $(APP)
CHART    := deploy/helm
# Куда сохранять отрендеренный values.yaml (gitignored).
VALUES_OUT := $(CHART)/.tmp/values.yaml
# gomplate: infra пробрасывает абсолютный путь к бинарю в переменной GOMPLATE
# (см. корневой Makefile + ./.tools/gomplate); пустое значение — берём из PATH.
GOMPLATE ?= gomplate

HELM := helm --kubeconfig $(KUBECONFIG) -n $(APP_NS)

.PHONY: infra-deploy infra-rollback infra-status infra-logs infra-migrate infra-seed infra-shell \
	infra-values-render infra-values-print

# Рендер $(VALUES_OUT) из $(CHART)/values.yaml.gotmpl с подстановкой из APP_CONFIG.
# gomplate datasources:
#   cfg — merged YAML конкретного приложения (поля из apps/registry.yaml + apps/conf/<APP>/<ENV>/).
infra-values-render: $(VALUES_OUT)

$(VALUES_OUT): $(CHART)/values.yaml.gotmpl $(APP_CONFIG)
	@test -n "$(APP_CONFIG)" || (echo '✗ APP_CONFIG не задан (запускайте через make app-deploy ... из infra)' >&2; exit 1)
	@test -f "$(APP_CONFIG)" || (echo "✗ APP_CONFIG не найден: $(APP_CONFIG)" >&2; exit 1)
	@command -v $(GOMPLATE) >/dev/null 2>&1 || [ -x "$(GOMPLATE)" ] || (echo '✗ gomplate не найден ($(GOMPLATE)) — make tools-check' >&2; exit 1)
	@mkdir -p "$(CHART)/.tmp"
	@$(GOMPLATE) -f "$(CHART)/values.yaml.gotmpl" -d cfg="$(APP_CONFIG)" -o "$(VALUES_OUT)"

# Дамп отрендеренных values на stdout (для отладки).
infra-values-print: infra-values-render
	@cat "$(VALUES_OUT)"

infra-deploy: infra-values-render
	$(HELM) upgrade --install $(RELEASE) $(CHART) --create-namespace \
	  -f $(VALUES_OUT) \
	  --wait --timeout=5m

infra-rollback:
	$(HELM) rollback $(RELEASE) $(REVISION)

infra-status:
	$(HELM) status $(RELEASE)
	kubectl --kubeconfig $(KUBECONFIG) -n $(APP_NS) get pods,svc,ingress -l app.kubernetes.io/instance=$(RELEASE)

infra-logs:
	kubectl --kubeconfig $(KUBECONFIG) -n $(APP_NS) logs \
	  -l app.kubernetes.io/instance=$(RELEASE) \
	  $(if $(CONTAINER),--container $(CONTAINER)) \
	  $(if $(filter 1,$(FOLLOW)),-f --tail=100,--tail=200)

infra-migrate:
	@echo '✗ Реализуйте infra-migrate (ENV=$(ENV) APP=$(APP) APP_NS=$(APP_NS))' >&2; exit 1

infra-seed:
	@echo '✗ Реализуйте infra-seed (ENV=$(ENV) APP=$(APP) APP_NS=$(APP_NS))' >&2; exit 1

infra-shell:
	@echo '✗ Реализуйте infra-shell [CONTAINER=$(CONTAINER)]' >&2; exit 1
MAKEFILE
	echo "✓ Makefile.infra      → apps/src/$APP/Makefile.infra"
fi

# === Makefile (только если отсутствует) ===
if [[ ! -f "$MK_FILE" ]]; then
	cat >"$MK_FILE" <<'MAKEFILE'
.DEFAULT_GOAL := help

include Makefile.infra

help:
	@echo "infra-interface targets:"
	@grep -E '^infra-[a-z]+:' Makefile.infra | sed 's/:.*//' | sort | xargs -I{} echo '  make {}'
MAKEFILE
	echo "✓ Makefile            → apps/src/$APP/Makefile (минимальный, include Makefile.infra)"
else
	echo ""
	echo "Добавьте в apps/src/$APP/Makefile строку:"
	echo ""
	echo "    include Makefile.infra"
	echo ""
fi

# === values.yaml.gotmpl (только если отсутствует) ===
# Не перезаписываем (даже при OVERWRITE=1): шаблон чарта приложения трогать опасно.
if [[ ! -f "$GOTMPL_FILE" ]]; then
	if [[ -d "$SRC_DIR/deploy/helm" ]]; then
		cat >"$GOTMPL_FILE" <<'GOTMPL'
# values.yaml.gotmpl — шаблон Helm values, рендерится infra перед helm upgrade.
# Источник данных: gomplate -d cfg=<merged-yaml>, где cfg — merged YAML одного приложения
# (поля из apps/registry.yaml + deep-merge всех apps/conf/<APP>/<ENV>/*.yaml).
#
# Примеры обращения:
#   {{ (ds "cfg").postgres.password }}              — секреты приложения
#   {{ (ds "cfg").app_ns }}                         — namespace из registry
#   {{ (ds "cfg").app.replicas.web | default 1 }}   — env-specific параметр из app.yaml
#
# Документация контракта: docs/runbooks/app-interface.md
replicaCount: {{ (ds "cfg").app.replicas.web | default 1 }}

# Образ — подставьте свою конвенцию (например REGISTRY/RELEASE:TAG, набираемые в Makefile.infra).
image:
  repository: {{ (ds "cfg").app.image.repository | default "localhost:32000/myapp" }}
  tag: {{ (ds "cfg").app.image.tag | default "latest" }}

ingress:
  enabled: {{ (ds "cfg").app.ingress.enabled | default false }}
  host: {{ (ds "cfg").app.ingress.host | default "" }}
GOTMPL
		echo "✓ values.yaml.gotmpl  → apps/src/$APP/deploy/helm/values.yaml.gotmpl (отредактируйте под свой чарт)"
	else
		echo "  (deploy/helm/ не найден — пропускаем рыбу values.yaml.gotmpl)"
	fi
else
	echo "⚠  deploy/helm/values.yaml.gotmpl уже существует — пропущен."
fi

echo ""
echo "Следующие шаги:"
echo "  1. Перенесите env-specific параметры из values-<ENV>.yaml в apps/conf/$APP/<ENV>/app.yaml"
echo "  2. Адаптируйте apps/src/$APP/deploy/helm/values.yaml.gotmpl под ваш чарт"
echo "  3. Проверьте: make apps-merge-app-print APP=$APP ENV=<env>"
echo "  4. Проверьте: make app-capabilities APP=$APP"
echo "  Документация: docs/runbooks/app-interface.md"
