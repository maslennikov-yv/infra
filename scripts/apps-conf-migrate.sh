#!/usr/bin/env bash
# Миграция apps/conf/<APP>/ → apps/conf/<APP>/<ENV>/.
# Перемещает plain *.yaml/*.yml и *.enc.yaml/*.enc.yml из корня apps/conf/<APP>/
# в подкаталог apps/conf/<APP>/<ENV>/. Идемпотентен: пропускает уже перемещённые файлы.
#
# Использование:
#   apps-conf-migrate.sh <repo_root> <APP> <ENV>
#   или через make: make apps-conf-migrate APP=bot ENV=prod
set -euo pipefail

REPO="${1:?repo_root}"
APP="${2:?APP}"
ENV="${3:?env name}"

SRC="$REPO/apps/conf/$APP"
DST="$REPO/apps/conf/$APP/$ENV"

if [[ ! -d "$SRC" ]]; then
	echo "✗ Каталог не найден: $SRC" >&2
	exit 1
fi

if [[ -d "$DST" ]] && [[ -z "$(ls -A "$DST" 2>/dev/null)" ]]; then
	: # пустой — ок, продолжаем
elif [[ -d "$DST" ]]; then
	echo "⚠ $DST уже существует и не пустой — проверьте вручную." >&2
	exit 1
fi

shopt -s nullglob
files=("$SRC"/*.yaml "$SRC"/*.yml "$SRC"/*.enc.yaml "$SRC"/*.enc.yml)
shopt -u nullglob

# Исключить дубли (nullglob может вернуть *.enc.yaml дважды через *.yaml)
declare -A seen
uniq_files=()
for f in "${files[@]:-}"; do
	[[ -n "${f:-}" && -f "$f" ]] || continue
	[[ -z "${seen[$f]:-}" ]] || continue
	seen[$f]=1
	uniq_files+=("$f")
done

if [[ ${#uniq_files[@]} -eq 0 ]]; then
	echo "  ↷ $APP: нет legacy-файлов в apps/conf/$APP/ — пропуск."
	exit 0
fi

install -d -m 700 "$DST"
moved=0
for f in "${uniq_files[@]}"; do
	base=$(basename "$f")
	target="$DST/$base"
	if [[ -e "$target" ]]; then
		echo "  ↷ $APP/$ENV/$base уже существует — пропуск."
		continue
	fi
	mv "$f" "$target"
	chmod 600 "$target"
	echo "  ✓ $APP/$(basename "$f") → $APP/$ENV/$(basename "$f")"
	moved=$((moved + 1))
done

echo "✓ Мигрировано $moved файлов: apps/conf/$APP/ → apps/conf/$APP/$ENV/"
