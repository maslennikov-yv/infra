#!/usr/bin/env bash
# Генерирует рыбу infra-interface для приложения в apps/src/<APP>/:
#   infra-interface.yaml — декларация методов (v1, все 7)
#   Makefile.infra       — стабы infra-* целей (include в Makefile приложения)
#   Makefile             — минимальный (только если ещё не существует)
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
OVERWRITE="${OVERWRITE:-0}"

if [[ ! -d "$SRC_DIR" ]]; then
	echo "✗ apps/src/$APP/ не найден." >&2
	echo "  Запустите: make apps-src-clone APP=$APP" >&2
	exit 1
fi

# Проверка существующих файлов
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
#   ENV          — окружение (local / prod / stage / …)
#   KUBECONFIG   — абсолютный путь к kubeconfig
#   APP          — имя приложения
#   APP_NS       — kubernetes namespace (= app_ns из registry или APP)
#   APPS_REGISTRY — путь к apps/registry.yaml
#
# Дополнительные переменные по методу:
#   rollback: REVISION (номер ревизии; пустой = откат к предыдущей)
#   logs:     FOLLOW=1, CONTAINER
#   shell:    CONTAINER

.PHONY: infra-deploy infra-rollback infra-status infra-logs infra-migrate infra-seed infra-shell

infra-deploy:
	@echo '✗ Реализуйте infra-deploy (ENV=$(ENV) APP=$(APP) APP_NS=$(APP_NS))' >&2; exit 1

infra-rollback:
	@echo '✗ Реализуйте infra-rollback [REVISION=$(REVISION)]' >&2; exit 1

infra-status:
	@echo '✗ Реализуйте infra-status (ENV=$(ENV) APP=$(APP) APP_NS=$(APP_NS))' >&2; exit 1

infra-logs:
	@echo '✗ Реализуйте infra-logs [FOLLOW=$(FOLLOW)] [CONTAINER=$(CONTAINER)]' >&2; exit 1

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

echo ""
echo "Следующие шаги:"
echo "  1. Реализуйте нужные цели в apps/src/$APP/Makefile.infra"
echo "  2. Удалите из infra-interface.yaml методы, которые не реализуете"
echo "  3. Проверьте: make app-capabilities APP=$APP"
echo "  Документация: docs/runbooks/app-interface.md"
