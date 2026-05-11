#!/usr/bin/env bash
# Копирует шаблон из apps/conf/_example/*.yaml|*.yml в apps/conf/<APP>/<ENV>/;
# по умолчанию добавляет запись в apps/registry.yaml (enabled: false).
# Использование: apps-conf-template.sh <repo_root> <APP> <ENV>
# SKIP_REGISTRY=1 — не трогать registry (если запись уже есть или добавите вручную).
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/apps-yq-probe.sh
source "$DIR/apps-yq-probe.sh"

REPO="${1:?repo_root}"
APP_RAW="${2:?APP}"
ENV="${3:?env name}"

[[ -f "$REPO/apps/registry.yaml" ]] || {
	echo "✗ Не найден registry: $REPO/apps/registry.yaml" >&2
	exit 1
}

EXAMPLE="$REPO/apps/conf/_example"
[[ -d "$EXAMPLE" ]] || {
	echo "✗ Нет каталога-шаблона: $EXAMPLE" >&2
	exit 1
}

if [[ "$APP_RAW" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]]; then
	APP="$APP_RAW"
else
	echo '✗ APP: используйте латиницу (a–z), цифры, - и _; первый символ — буква или цифра; длина до 63 символов.' >&2
	exit 1
fi

[[ "$APP" != "_example" ]] || {
	echo '✗ Имя _example зарезервировано под шаблон.' >&2
	exit 1
}

REG="$REPO/apps/registry.yaml"
DEST="$REPO/apps/conf/$APP/$ENV"

if [[ -e "$DEST" ]]; then
	echo "✗ Уже существует: $DEST — удалите каталог или выберите другое APP/ENV." >&2
	exit 1
fi

if [[ "${SKIP_REGISTRY:-}" != "1" ]]; then
	cnt=$(APPNAME="$APP" "$YQBIN" '[.apps[] | select(.name == strenv(APPNAME))] | length' "$REG")
	if [[ "${cnt:-0}" != "0" ]]; then
		echo "✗ В registry уже есть name=\"$APP\". Используйте SKIP_REGISTRY=1 (только файлы) или другое имя." >&2
		exit 1
	fi
fi

install -d -m 700 "$DEST"
copied=0
shopt -s nullglob
for f in "$EXAMPLE"/*.yaml "$EXAMPLE"/*.yml; do
	base=$(basename "$f")
	cp "$f" "$DEST/$base"
	chmod 600 "$DEST/$base"
	copied=$((copied + 1))
done
shopt -u nullglob

if [[ "$copied" -eq 0 ]]; then
	echo "✗ В $EXAMPLE нет *.yaml / *.yml для копирования." >&2
	rmdir "$DEST" 2>/dev/null || true
	exit 1
fi

if [[ "${SKIP_REGISTRY:-}" != "1" ]]; then
	APPNAME="$APP" APPNS="$APP" "$YQBIN" -i \
		'.apps += [{"name": strenv(APPNAME), "enabled": false, "app_ns": strenv(APPNS)}]' \
		"$REG"
	echo "✓ Registry: добавлена запись name=$APP (enabled: false, app_ns=$APP)"
fi

echo "✓ Шаблон конфигурации: $DEST (ENV=$ENV, скопировано файлов: $copied)"
