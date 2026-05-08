#!/usr/bin/env bash
# Читает поле через точечный путь из merged-представления одного приложения.
# merged.yaml — результат apps-merge-config.sh; PATH — например postgres.password
# stdout: сырое значение (может быть пустым при null); exit 1 если приложение не найдено или name дублируется
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$DIR/apps-yq-probe.sh"

MERGED="${1:?merged file}"
APP="${2:?APP}"
SUBPATH="${3:?path like postgres.password}"

if [[ ! "$SUBPATH" =~ ^[a-zA-Z0-9_.]+$ ]]; then
	echo "✗ Недопустимый path (ожидаются только буквы, цифры, _ и .): $SUBPATH" >&2
	exit 1
fi

[[ -f "$MERGED" ]] || exit 1

cnt=$(env APP="$APP" "$YQBIN" -r '[.apps[] | select(.name == strenv(APP))] | length' "$MERGED")
if [[ -z "${cnt:-}" ]] || ! [[ "${cnt:-0}" =~ ^[0-9]+$ ]] || [[ "$cnt" -eq 0 ]]; then
	exit 1
fi
if [[ "$cnt" -ne 1 ]]; then
	echo "✗ В merged YAML несколько записей с name=\"$APP\" (ожидается одна)." >&2
	exit 1
fi

doc=$(env APP="$APP" "$YQBIN" -r '[.apps[] | select(.name == strenv(APP))][0]' "$MERGED")
if [[ -z "${doc:-}" ]] || [[ "$doc" == "null" ]]; then
	exit 1
fi

printf '%s' "$doc" | "$YQBIN" -r ".$SUBPATH"
