#!/usr/bin/env bash
# Следующий свободный логический номер БД Redis (1..127) по merged YAML (apps-merge-config.sh).
# Если у записи name=APP уже есть redis_db — печатает его.
# Иначе — минимальный n в 1..127 среди других приложений (0 не считается занятым слотом).
# Использование: redis-next-db.sh <merged.yaml> <APP>
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$DIR/apps-yq-probe.sh"

MERGED="${1:?merged yaml}"
APP="${2:?APP name}"

[[ -f "$MERGED" ]] || {
	echo "✗ merged файл не найден: $MERGED" >&2
	exit 1
}

RDB=$(env APP="$APP" "$YQBIN" -r '.apps[] | select(.name == strenv(APP)) | .redis_db // empty' "$MERGED")
if [ -n "$RDB" ] && [ "$RDB" != "null" ]; then
	echo "$RDB"
	exit 0
fi

USED=$(env APP="$APP" "$YQBIN" -r '.apps[] | select(.name != strenv(APP)) | .redis_db // empty' "$MERGED" | grep -E '^[0-9]+$' | grep -v '^0$' | sort -n -u || true)
for n in $(seq 1 127); do
	if ! echo "$USED" | grep -qx "$n"; then
		echo "$n"
		exit 0
	fi
done

echo "✗ Все логические БД 1–127 заняты в merged; освободите redis_db или задайте REDIS_DB=..." >&2
exit 1
