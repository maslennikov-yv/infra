#!/usr/bin/env bash
# Собирает merged-конфиг ОДНОГО приложения для шаблонизации values.yaml.gotmpl:
#   запись из apps/registry.yaml для <APP>  ↓
#   deep-merge всех *.yaml (+ *.yml) из apps/conf/<APP>/<ENV>/
#   (зашифрованные *.enc.yaml/*.enc.yml расшифровываются через sops перед мержем,
#    plain поверх encrypted — тот же порядок, что в apps-merge-config.sh).
#
# Отличия от apps-merge-config.sh:
#   - возвращает ОДИН объект (не {apps: [...]}), готовый к подаче в gomplate -d cfg=…
#   - работает и для приложений с enabled: false (для разработки/первичной настройки)
#   - не валидирует список всех приложений на коллизии (это делает apps-merge-config.sh)
#
# Использование: apps-merge-app.sh <repo_root> <APP> <ENV>
# stdout: итоговый YAML-объект.
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$DIR/apps-yq-probe.sh"

REPO="${1:?repo_root}"
APP="${2:?APP}"
ENV="${3:?env name}"

REG="$REPO/apps/registry.yaml"
[[ -f "$REG" ]] || {
	echo "✗ Реестр не найден: $REG" >&2
	exit 1
}

# Проверяем, что запись с таким name существует — независимо от enabled.
cnt=$(NM="$APP" "$YQBIN" '[.apps[] | select(.name == strenv(NM))] | length' "$REG")
if [[ "${cnt:-0}" == "0" ]]; then
	echo "✗ В $REG нет записи name=\"$APP\"." >&2
	exit 1
fi
if [[ "${cnt:-0}" != "1" ]]; then
	echo "✗ В $REG несколько записей name=\"$APP\" ($cnt). Уберите дубликаты." >&2
	exit 1
fi

current=$(mktemp)
decrypted_tmps=()
cleanup() {
	rm -f "$current"
	for t in "${decrypted_tmps[@]:-}"; do [[ -n "${t:-}" ]] && rm -f "$t"; done
	return 0
}
trap cleanup EXIT INT TERM

# База — запись приложения из registry (как объект, без обёртки apps:).
env NM="$APP" "$YQBIN" -o yaml '.apps[] | select(.name == strenv(NM))' "$REG" >"$current"

confdir="$REPO/apps/conf/$APP/$ENV"
if [[ -d "$confdir" ]]; then
	shopt -s nullglob
	mapfile -t enc_files   < <(printf '%s\n' "$confdir"/*.enc.yaml "$confdir"/*.enc.yml | grep . | LC_ALL=C sort)
	mapfile -t plain_files < <(printf '%s\n' "$confdir"/*.yaml      "$confdir"/*.yml      | grep -v '\.enc\.' | grep . | LC_ALL=C sort)
	shopt -u nullglob
	conffiles=("${enc_files[@]:-}" "${plain_files[@]:-}")
	for f in "${conffiles[@]:-}"; do
		[[ -n "${f:-}" && -f "$f" ]] || continue
		src="$f"
		case "$f" in
			*.enc.yaml|*.enc.yml)
				if ! command -v sops >/dev/null 2>&1; then
					echo "✗ Файл $f зашифрован sops, но sops не установлен. См. docs/runbooks/secrets-management.md." >&2
					exit 1
				fi
				tmp_dec=$(mktemp --suffix=.yaml 2>/dev/null || mktemp)
				if ! sops --decrypt "$f" >"$tmp_dec" 2>/dev/null; then
					echo "✗ Не удалось расшифровать $f. Проверьте SOPS_AGE_KEY_FILE и .sops.yaml." >&2
					rm -f "$tmp_dec"
					exit 1
				fi
				decrypted_tmps+=("$tmp_dec")
				src="$tmp_dec"
				;;
		esac
		next=$(mktemp)
		"$YQBIN" eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$current" "$src" >"$next"
		mv "$next" "$current"
	done
fi

cat "$current"
