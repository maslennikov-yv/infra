#!/usr/bin/env bash
# Генерирует рыбу infra-interface v2 для приложения в apps/src/<APP>/:
#   infra-interface.yaml             — декларация методов (v2: render-values + 7 lifecycle-методов)
#   Makefile.infra                   — стабы infra-* целей (include в Makefile приложения),
#                                      включая infra-render-values (gomplate из APP_SECRETS → VALUES_OUT)
#   Makefile                         — минимальный (только если ещё не существует)
#   deploy/helm/values.yaml.gotmpl   — пример шаблона values (gomplate datasource sec=APP_SECRETS)
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
# Декларация infra-interface для приложения (контракт v2).
# Оставьте только те методы, которые реализованы в Makefile.infra.
# Документация: docs/runbooks/app-interface.md
version: 2
implements:
  - render-values
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
# infra-interface v2 — стабы lifecycle-методов.
# Включите в Makefile приложения: include Makefile.infra
#
# Переменные, которые infra передаёт при каждом вызове:
#   ENV         — окружение (local / prod / stage / …)
#   KUBECONFIG  — абсолютный путь к kubeconfig
#   APP         — имя приложения
#   APP_NS      — kubernetes namespace (= app_ns из registry или APP)
#   APP_SECRETS — путь к secrets.yaml приложения (apps/conf/<APP>/<ENV>/secrets.yaml;
#                 если файл зашифрован — infra расшифровывает в apps/.tmp/ перед вызовом).
#                 Содержит креды и endpoints infra-сервисов (postgres/redis/kafka/minio/clickhouse/rabbitmq).
#   VALUES_OUT  — куда писать отрендеренный values-<ENV>.yaml
#                 (по умолчанию apps/src/<APP>/deploy/helm/values-<ENV>.yaml).
#   GOMPLATE    — абсолютный путь к бинарю gomplate (или пустое — из PATH).
#
# Дополнительные переменные по методу:
#   rollback: REVISION (номер ревизии; пустой = откат к предыдущей)
#   logs:     FOLLOW=1, CONTAINER
#   shell:    CONTAINER

APP      ?= app
APP_NS   ?= $(APP)
RELEASE  := $(APP)
CHART    := deploy/helm
GOMPLATE ?= gomplate

HELM := helm --kubeconfig $(KUBECONFIG) -n $(APP_NS)

.PHONY: infra-render-values infra-deploy infra-rollback infra-status infra-logs infra-migrate infra-seed infra-shell \
	infra-values-print

# Рендер $(VALUES_OUT) из $(CHART)/values.yaml.gotmpl с подстановкой из APP_SECRETS.
# gomplate datasource:
#   sec — apps/conf/<APP>/<ENV>/secrets.yaml: креды и endpoints infra-сервисов.
# Не-секретные env-параметры (replicas, ingress, resources, log level) — внутреннее дело
# приложения: храните их рядом с шаблоном (например $(CHART)/values-$(ENV).base.yaml)
# и подмержите в values.yaml.gotmpl самостоятельно.
# Без файловых prerequisites: имена зависят от ENV, и make -n при пустом ENV не должен падать
# (используется в app-capabilities для проверки наличия цели). Проверки — внутри рецепта.
infra-render-values:
	@test -n "$(ENV)" || (echo '✗ ENV не задан' >&2; exit 1)
	@test -n "$(APP_SECRETS)" || (echo '✗ APP_SECRETS не задан (запускайте через make app-render-values ... из infra)' >&2; exit 1)
	@test -f "$(APP_SECRETS)" || (echo "✗ APP_SECRETS не найден: $(APP_SECRETS)" >&2; exit 1)
	@test -n "$(VALUES_OUT)" || (echo '✗ VALUES_OUT не задан' >&2; exit 1)
	@command -v $(GOMPLATE) >/dev/null 2>&1 || [ -x "$(GOMPLATE)" ] || (echo '✗ gomplate не найден ($(GOMPLATE)) — make tools-check' >&2; exit 1)
	@mkdir -p "$(dir $(VALUES_OUT))"
	@$(GOMPLATE) -f "$(CHART)/values.yaml.gotmpl" -d sec="$(APP_SECRETS)" -o "$(VALUES_OUT)"
	@echo "✓ values-$(ENV).yaml → $(VALUES_OUT)"

# Дамп отрендеренных values на stdout (для отладки).
infra-values-print: infra-render-values
	@cat "$(VALUES_OUT)"

infra-deploy:
	@test -f "$(VALUES_OUT)" || (echo "✗ $(VALUES_OUT) не найден — вызывайте через 'make app-deploy' из infra или сначала 'make app-render-values'" >&2; exit 1)
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
	@grep -E '^infra-[a-z-]+:' Makefile.infra | sed 's/:.*//' | sort | xargs -I{} echo '  make {}'
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
{{/*
  values.yaml.gotmpl — env-overrides поверх deploy/helm/values.yaml.
  Рендерится infra перед helm upgrade (см. Makefile.infra → infra-render-values).
  Контракт: docs/runbooks/app-interface.md (v2).

  Datasource:
    sec — apps/conf/<APP>/<ENV>/secrets.yaml (передаётся infra как APP_SECRETS).
          Содержит креды и endpoints infra-сервисов (postgres/redis/kafka/minio/clickhouse/rabbitmq)
          + application-specific секреты (например app.key, app.systemUserPassword).

  Не-секретные env-параметры (replicas, ingress host, resources, log level) храните
  внутри репозитория приложения (например deploy/helm/values-<ENV>.base.yaml) —
  infra их не знает и не передаёт.
*/ -}}
{{- $sec := ds "sec" -}}
postgres:
  host: {{ $sec.postgres.host | quote }}
  port: {{ $sec.postgres.port | default 5432 }}
  username: {{ $sec.postgres.username | quote }}
  password: {{ $sec.postgres.password | quote }}
  database: {{ $sec.postgres.database | quote }}

redis:
  host: {{ $sec.redis.host | quote }}
  port: {{ $sec.redis.port | default 6379 }}
  username: {{ $sec.redis.username | quote }}
  password: {{ $sec.redis.password | quote }}
  db: {{ $sec.redis.redis_db | default 0 }}
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
echo "  1. Адаптируйте apps/src/$APP/deploy/helm/values.yaml.gotmpl под ваш чарт"
echo "     (datasource sec — apps/conf/$APP/<ENV>/secrets.yaml)."
echo "  2. Не-секретные env-параметры (replicas/ingress/log level) держите внутри репо приложения,"
echo "     например в deploy/helm/values-<ENV>.base.yaml + merge в values.yaml.gotmpl."
echo "  3. Проверьте: make app-capabilities APP=$APP"
echo "  4. Проверьте рендер:  make app-render-values APP=$APP ENV=<env>"
echo "  Документация: docs/runbooks/app-interface.md"
