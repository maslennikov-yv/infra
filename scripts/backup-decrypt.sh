#!/usr/bin/env bash
# Опциональная дешифровка backup-файла перед restore.
#
# Args:
#   $1 — путь к файлу (`*.tar.gz` / `*.sql.gz` / `*.tar.gz.age` / etc.).
#
# ENV:
#   BACKUP_AGE_KEY_FILE — путь к age-private-key (default: ~/.config/age/backups.txt).
#
# Behavior:
#   - Если SRC оканчивается на `.age` — дешифрует в `${SRC%.age}.decrypted`.
#     stdout: путь к расшифрованному временному файлу. Caller обязан его удалить
#     после use (см. cleanup в Makefile).
#   - Если SRC не `.age` — печатает SRC как есть (no-op). Caller использует его.
#
# Notes:
#   - НЕ кладёт расшифровку в каталог /tmp, чтобы не пересекать filesystem boundaries
#     (некоторые backup-скрипты ожидают файл в <svc>/backups).

set -euo pipefail

SRC=${1:?usage: backup-decrypt.sh <file>}

if [[ "$SRC" != *.age ]]; then
	# Не зашифрован — passthrough
	echo "$SRC"
	exit 0
fi

KEY_FILE=${BACKUP_AGE_KEY_FILE:-$HOME/.config/age/backups.txt}

[[ -f "$SRC" ]] || {
	echo "✗ backup-decrypt: файл не найден: $SRC" >&2
	exit 1
}
[[ -f "$KEY_FILE" ]] || {
	echo "✗ backup-decrypt: BACKUP_AGE_KEY_FILE не найден: $KEY_FILE" >&2
	echo "  Задайте через BACKUP_AGE_KEY_FILE=… или положите ключ в ~/.config/age/backups.txt" >&2
	exit 1
}
command -v age >/dev/null 2>&1 || {
	echo "✗ backup-decrypt: age не установлен в PATH" >&2
	exit 1
}

# Расшифровка рядом с зашифрованным файлом, с суффиксом .decrypted чтобы
# отличать от «настоящих» бэкапов в каталоге.
DST="${SRC%.age}.decrypted"

if age -d -i "$KEY_FILE" -o "$DST" "$SRC"; then
	echo "$DST"
else
	rm -f -- "$DST"
	echo "✗ backup-decrypt: age -d failed для $SRC" >&2
	exit 1
fi
