#!/usr/bin/env bash
# Проверяет, задекларирован и реализован ли метод METHOD для приложения APP.
# Использование: app-interface-check.sh <REPO_ROOT> <APP> <METHOD>
# Exit: 0 — реализован; 1 — не реализован (сообщение в stderr).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/apps-yq-probe.sh"

REPO_ROOT="${1:?REPO_ROOT}"
APP="${2:?APP}"
METHOD="${3:?METHOD}"

SRC_DIR="$REPO_ROOT/apps/src/$APP"
IFACE_FILE="$SRC_DIR/infra-interface.yaml"

if [[ ! -d "$SRC_DIR" ]]; then
	echo "✗ apps/src/$APP/ не найден." >&2
	echo "  Запустите: make apps-src-clone APP=$APP" >&2
	exit 1
fi

if [[ ! -f "$IFACE_FILE" ]]; then
	echo "✗ apps/src/$APP/infra-interface.yaml не найден." >&2
	echo "  Метод '$METHOD' недоступен. Документация: docs/runbooks/app-interface.md" >&2
	exit 1
fi

if [[ ! -f "$SRC_DIR/Makefile" ]]; then
	echo "✗ apps/src/$APP/Makefile не найден — метод '$METHOD' не может быть выполнен." >&2
	exit 1
fi

version=$("$YQBIN" -r '.version // 0' "$IFACE_FILE")
if [[ "$version" -gt 1 ]]; then
	echo "✗ infra-interface.yaml: version=$version не поддерживается (infra поддерживает до v1)." >&2
	exit 1
fi

declared=$(("$YQBIN" -r '.implements[]? // ""' "$IFACE_FILE" | grep -Fx "$METHOD") || true)
if [[ -z "$declared" ]]; then
	all=$("$YQBIN" -r '[.implements[]?] | join(", ")' "$IFACE_FILE")
	echo "✗ Метод '$METHOD' не задекларирован в apps/src/$APP/infra-interface.yaml." >&2
	echo "  Реализованные методы: ${all:-—}" >&2
	exit 1
fi

target="infra-${METHOD}"
if ! make -C "$SRC_DIR" -n --no-print-directory "$target" >/dev/null 2>&1; then
	echo "✗ Метод '$METHOD' задекларирован, но цель '$target' не найдена в Makefile." >&2
	echo "  Запустите 'make app-capabilities APP=$APP' для полной диагностики." >&2
	exit 1
fi
