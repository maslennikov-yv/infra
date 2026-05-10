#!/usr/bin/env bash
# Опциональное шифрование свежего backup-файла через age.
#
# Args:
#   $1 — каталог поиска (e.g. "postgres/backups").
#   $2 (опц.) — glob-паттерн файла (e.g. "postgres-backup-*.sql.gz").
#               По умолчанию: все файлы в каталоге, кроме *.age.
#
# ENV:
#   BACKUP_AGE_RECIPIENT — age-public-recipient (например, age1...).
#                          Если пуст/не задан — no-op (шифрование выключено).
#
# Behavior:
#   - При успехе: создаёт <orig>.age, удаляет <orig>.
#   - При ошибке: оставляет <orig> на месте, exit 1.
#
# Idempotency:
#   - Уже зашифрованные файлы (*.age) пропускаются автоматически.

set -euo pipefail

DIR=${1:?usage: backup-encrypt.sh <dir> [pattern]}
PATTERN=${2:-*}

RECIPIENT=${BACKUP_AGE_RECIPIENT:-}
if [[ -z "$RECIPIENT" ]]; then
	exit 0
fi

command -v age >/dev/null 2>&1 || {
	echo "✗ backup-encrypt: BACKUP_AGE_RECIPIENT задан, но age не установлен в PATH" >&2
	exit 1
}

[[ -d "$DIR" ]] || {
	echo "✗ backup-encrypt: каталог $DIR не существует (бэкап не создан?)" >&2
	exit 1
}

# Берём свежий файл, исключая *.age
LATEST=$(find "$DIR" -maxdepth 1 -type f -name "$PATTERN" ! -name '*.age' -printf '%T@ %p\n' 2>/dev/null \
	| sort -rn | head -1 | awk '{print $2}')

if [[ -z "$LATEST" ]]; then
	echo "✗ backup-encrypt: в $DIR не найден свежий файл по паттерну '$PATTERN'" >&2
	exit 1
fi

OUT="${LATEST}.age"
if age -r "$RECIPIENT" -o "$OUT" "$LATEST"; then
	rm -- "$LATEST"
	echo "🔒 backup-encrypt: $(basename "$OUT") (age, recipient=${RECIPIENT:0:20}…)"
else
	rm -f -- "$OUT"
	echo "✗ backup-encrypt: age failed; оригинал $LATEST оставлен" >&2
	exit 1
fi
