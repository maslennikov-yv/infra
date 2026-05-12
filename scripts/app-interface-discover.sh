#!/usr/bin/env bash
# Читает apps/src/<APP>/infra-interface.yaml, проверяет версию и наличие make-целей infra-*.
# Использование: app-interface-discover.sh <REPO_ROOT> <APP>
# Exit: 0 — интерфейс валиден; 1 — ошибка (нет src, нет файла, версия > max, цели отсутствуют).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/apps-yq-probe.sh"

REPO_ROOT="${1:?REPO_ROOT}"
APP="${2:?APP}"

INFRA_MAX_VERSION=1

SRC_DIR="$REPO_ROOT/apps/src/$APP"
IFACE_FILE="$SRC_DIR/infra-interface.yaml"

if [[ ! -d "$SRC_DIR" ]]; then
	echo "✗ apps/src/$APP/ не найден." >&2
	echo "  Запустите: make apps-src-clone APP=$APP" >&2
	exit 1
fi

if [[ ! -f "$IFACE_FILE" ]]; then
	echo "✗ apps/src/$APP/infra-interface.yaml не найден." >&2
	echo "  Приложение не объявляет интерфейс infra." >&2
	echo "  Документация: docs/runbooks/app-interface.md" >&2
	exit 1
fi

if [[ ! -f "$SRC_DIR/Makefile" ]]; then
	echo "✗ apps/src/$APP/Makefile не найден." >&2
	echo "  infra-interface.yaml требует Makefile с целями infra-*." >&2
	exit 1
fi

version=$("$YQBIN" -r '.version // 0' "$IFACE_FILE")
if ! [[ "$version" =~ ^[0-9]+$ ]]; then
	echo "✗ infra-interface.yaml: version должно быть целым числом, получено: $version" >&2
	exit 1
fi
if [[ "$version" -lt 1 ]]; then
	echo "✗ infra-interface.yaml: version >= 1 обязательно, получено: $version" >&2
	exit 1
fi
if [[ "$version" -gt "$INFRA_MAX_VERSION" ]]; then
	echo "✗ infra-interface.yaml: version=$version не поддерживается (infra поддерживает до v$INFRA_MAX_VERSION)." >&2
	echo "  Обновите infra или понизьте версию интерфейса в приложении." >&2
	exit 1
fi

mapfile -t methods < <("$YQBIN" -r '.implements[]? // ""' "$IFACE_FILE" | sed '/^[[:space:]]*$/d')

if [[ ${#methods[@]} -eq 0 ]]; then
	echo "⚠ infra-interface.yaml: список implements пуст." >&2
	exit 1
fi

echo "App:     $APP"
echo "Version: $version"
echo "Методы:"

FAIL=0
for method in "${methods[@]}"; do
	target="infra-${method}"
	if make -C "$SRC_DIR" -n --no-print-directory "$target" >/dev/null 2>&1; then
		printf '  ✓ %s\n' "$method"
	else
		printf '  ✗ %s  (цель %s не найдена в Makefile)\n' "$method" "$target"
		FAIL=1
	fi
done

if [[ $FAIL -ne 0 ]]; then
	echo "" >&2
	echo "✗ Некоторые задекларированные методы не реализованы в Makefile." >&2
	exit 1
fi
