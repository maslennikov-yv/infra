#!/usr/bin/env bash
# Применить учётки приложений из merge для сервисов с учётом ENABLED_SERVICES / EXCLUDE_SERVICES.
# Окружение: APPS_REGISTRY, REPO_ROOT, ENV; опционально ENABLED_SERVICES, EXCLUDE_SERVICES, KUBECONFIG, YQ.
# APPS_APPLY_CONTINUE_ON_ERROR=1 — не останавливаться на первой ошибке make; в конце exit 1 если были ошибки.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/apps-yq-probe.sh"

REG="${APPS_REGISTRY:?}"
REPO="${REPO_ROOT:?}"
ENV="${ENV:-local}"

merged=$(mktemp)
trap 'rm -f "$merged"' EXIT
"$SCRIPT_DIR/apps-merge-config.sh" "$REG" "$REPO" >"$merged"

declare -a ACTIVE=()
DATA_LIST="$SCRIPT_DIR/lib/data-services.txt"
[[ -f "$DATA_LIST" ]] || {
	echo "✗ Нет файла списка сервисов: $DATA_LIST" >&2
	exit 1
}
mapfile -t ALL < <(
	grep -v '^[[:space:]]*#' "$DATA_LIST" | sed '/^[[:space:]]*$/d' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
)
if [[ ${#ALL[@]} -eq 0 ]]; then
	echo "✗ Нет сервисов в $DATA_LIST" >&2
	exit 1
fi

if [[ -z "${ENABLED_SERVICES:-}" ]]; then
	ACTIVE=("${ALL[@]}")
else
	IFS=',' read -ra raw_en <<<"${ENABLED_SERVICES}"
	for x in "${raw_en[@]}"; do
		z="${x//[[:space:]]/}"
		[[ -n "$z" ]] && ACTIVE+=("$z")
	done
fi

if [[ -n "${EXCLUDE_SERVICES:-}" ]]; then
	IFS=',' read -ra raw_ex <<<"${EXCLUDE_SERVICES}"
	declare -a next=()
	for s in "${ACTIVE[@]}"; do
		skip=0
		for ex in "${raw_ex[@]}"; do
			e="${ex//[[:space:]]/}"
			[[ "$s" == "$e" ]] && {
				skip=1
				break
			}
		done
		[[ $skip -eq 1 ]] || next+=("$s")
	done
	ACTIVE=("${next[@]}")
fi

svc_active() {
	local n="$1"
	for s in "${ACTIVE[@]}"; do
		[[ "$s" == "$n" ]] && return 0
	done
	return 1
}

field_nonempty() {
	local app="$1" path="$2"
	local v
	v=$("$SCRIPT_DIR/app-config-get.sh" "$merged" "$app" "$path" || true)
	[[ -n "${v:-}" && "$v" != "null" ]]
}

HAD_FAILURE=0

invoke() {
	local label=$1 maketarget=$2
	shift 2
	echo "=== apps-apply: $label APP=$app ==="
	if (
		cd "$REPO"
		export APPS_MERGED_FILE="$merged"
		export APPS_REGISTRY="$REG"
		export REPO_ROOT="$REPO"
		make "$maketarget" ENV="$ENV" "$@"
	); then
		return 0
	fi
	echo "✗ apps-apply: $label APP=$app — ошибка make ($maketarget)" >&2
	if [[ "${APPS_APPLY_CONTINUE_ON_ERROR:-}" == "1" ]]; then
		HAD_FAILURE=1
	else
		exit 1
	fi
}

while IFS= read -r app; do
	[[ -n "${app:-}" ]] || continue

	if svc_active postgres && field_nonempty "$app" "postgres.password"; then
		invoke postgres pg-app-create "APP=$app"
	fi
	if svc_active redis && field_nonempty "$app" "redis.password"; then
		invoke redis redis-app-create "APP=$app"
	fi
	if svc_active kafka && field_nonempty "$app" "kafka.password"; then
		invoke kafka kafka-app-create "APP=$app"
	fi
	if svc_active minio && field_nonempty "$app" "minio.secret_key"; then
		invoke minio minio-app-create "APP=$app"
	fi
	if svc_active clickhouse && field_nonempty "$app" "clickhouse.password"; then
		invoke clickhouse clickhouse-app-create "APP=$app"
	fi
	if svc_active rabbitmq && field_nonempty "$app" "rabbitmq.password"; then
		invoke rabbitmq rabbitmq-app-create "APP=$app"
	fi

done < <("$YQBIN" -r '.apps[].name' "$merged")

if [[ "$HAD_FAILURE" -ne 0 ]]; then
	echo '✗ apps-apply завершён с ошибками (см. сообщения make выше)' >&2
	exit 1
fi

echo "✓ apps-apply завершён"
