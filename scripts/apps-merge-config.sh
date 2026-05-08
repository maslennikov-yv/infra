#!/usr/bin/env bash
# Собирает единый YAML: apps: [ ... ] только для приложений с enabled: true,
# каждая запись = объект из registry deep-merge всех *.yaml (+ *.yml) в apps/conf/<name>/.
# Использование: apps-merge-config.sh <registry.yaml> <repo_root>
# stdout при завершении: записывает в временный файл, только если нужен файл — используйте redirection
#
# На stdout всегда печатается итоговый YAML через cat в конце.
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$DIR/apps-yq-probe.sh"

REG="${1:?registry path}"
REPO="${2:?repo root}"

[[ -f "$REG" ]] || {
	echo "✗ Реестр не найден: $REG" >&2
	exit 1
}

missing=$("$YQBIN" '[.apps[] | select(.enabled == null)] | length' "$REG")
if [[ "${missing:-99}" != "0" ]]; then
	echo '✗ В каждой записи .apps должен быть явный enabled: true|false' >&2
	exit 1
fi

enet=$("$YQBIN" '[.apps[] | select(.enabled == true) | .name] | length' "$REG")
enuniq=$("$YQBIN" '[.apps[] | select(.enabled == true) | .name] | unique | length' "$REG")
if [[ "${enet:-0}" != "${enuniq:-0}" ]]; then
	echo "✗ У приложений с enabled: true должны быть уникальные поля name (сейчас ${enet} записей, ${enuniq} уникальных имён):" >&2
	"$YQBIN" -r '[.apps[] | select(.enabled == true) | .name]
		| group_by(.)
		| map(select(length > 1) | .[0])
		| unique
		| .[]' "$REG" | while IFS= read -r dn || [[ -n "${dn:-}" ]]; do
		[[ -n "${dn:-}" ]] && printf '  × %s\n' "$dn" >&2
	done
	exit 1
fi

result=$(mktemp)
trap 'rm -f "$result"' EXIT INT TERM

echo 'apps: []' >"$result"

while IFS= read -r name; do
	[[ -n "${name:-}" ]] || continue

	current=$(mktemp)

	env NM="$name" "$YQBIN" -o yaml '.apps[] | select(.enabled == true) | select(.name == strenv(NM))' "$REG" >"$current"

	confdir="$REPO/apps/conf/$name"
	if [[ -d "$confdir" ]]; then
		shopt -s nullglob
		mapfile -t conffiles < <(printf '%s\n' "$confdir"/*.yaml "$confdir"/*.yml | LC_ALL=C sort -u || true)
		shopt -u nullglob
		for f in "${conffiles[@]:-}"; do
			[[ -n "${f:-}" && -f "$f" ]] || continue
			next=$(mktemp)
			"$YQBIN" eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$current" "$f" >"$next"
			mv "$next" "$current"
		done
	fi

	realp=$(realpath "$current")
	ITEMPATH="$realp" "$YQBIN" -i '.apps += [load(env(ITEMPATH))]' "$result"
	rm -f "$current"

done < <(
	"$YQBIN" -r '.apps[] | select(.enabled == true) | .name' "$REG"
)

cat "$result"
