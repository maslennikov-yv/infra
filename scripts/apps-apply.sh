#!/usr/bin/env bash
# Применить учётки приложений из merge для сервисов с учётом ENABLED_SERVICES / EXCLUDE_SERVICES.
# Окружение: APPS_REGISTRY, REPO_ROOT, ENV; опционально ENABLED_SERVICES, EXCLUDE_SERVICES, KUBECONFIG, YQ.
# APPS_APPLY_CONTINUE_ON_ERROR=1 — не останавливаться на первой ошибке make; в конце exit 1 если были ошибки.
# APPS_APPLY_DRY_RUN=1 — не выполнять make, печатать «would create / would update / would drop / drift».
# APPS_APPLY_DROP_DISABLED=1 — для записей enabled: false с существующим Secret вызывать <service>-app-drop SKIP_CONFIRM=1
#                              (без флага — печатается предупреждение «drift», ничего не удаляется).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/apps-yq-probe.sh"

REG="${APPS_REGISTRY:?}"
REPO="${REPO_ROOT:?}"
ENV="${ENV:-local}"

DRY_RUN="${APPS_APPLY_DRY_RUN:-0}"
DROP_DISABLED="${APPS_APPLY_DROP_DISABLED:-0}"

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

# Имя Secret приложения по сервису — соответствует логике <service>-app-create.
secret_name_for() {
	local svc="$1" app="$2"
	echo "${app}-${svc}"
}

# app_ns по имени приложения (из реестра, fallback = name).
# Фильтр `select(. != null and . != "")` — yq оператор `//` пропускает только null/missing,
# но пустая строка ("") truthy → без фильтра привело бы к kubectl get -n "" (false-positive).
app_ns_for() {
	local app="$1"
	NM="$app" "$YQBIN" -r '.apps[] | select(.name == strenv(NM)) | ((.app_ns | select(. != null and . != "")) // .name)' "$REG" 2>/dev/null || true
}

# kubectl get secret <secret> -n <ns> — true если есть.
secret_exists() {
	local ns="$1" name="$2"
	[[ -n "$ns" && -n "$name" ]] || return 1
	command -v kubectl >/dev/null 2>&1 || return 1
	kubectl get secret "$name" -n "$ns" >/dev/null 2>&1
}

HAD_FAILURE=0

# invoke <label> <maketarget> <app> [extra args...]
# В DRY_RUN режиме не запускает make — печатает предполагаемое действие на основе
# наличия Secret в namespace приложения.
invoke() {
	local label=$1 maketarget=$2 app=$3
	shift 3
	if [[ "$DRY_RUN" == "1" ]]; then
		local ns secret existing="absent"
		ns=$(app_ns_for "$app")
		secret=$(secret_name_for "$label" "$app")
		if secret_exists "$ns" "$secret"; then existing="present"; fi
		if [[ "$existing" == "present" ]]; then
			echo "  [dry-run] would update $label: $ns/$secret  (Secret уже существует)"
		else
			echo "  [dry-run] would create $label: $ns/$secret"
		fi
		return 0
	fi
	echo "=== apps-apply: $label APP=$app ==="
	if (
		cd "$REPO"
		export APPS_MERGED_FILE="$merged"
		export APPS_REGISTRY="$REG"
		export REPO_ROOT="$REPO"
		make "$maketarget" ENV="$ENV" "APP=$app" "$@"
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

# invoke_drop <label> <maketarget> <app>
# Аналогично invoke, но для удаления учётки. Передаёт SKIP_CONFIRM=1.
invoke_drop() {
	local label=$1 maketarget=$2 app=$3
	if [[ "$DRY_RUN" == "1" ]]; then
		local ns secret
		ns=$(app_ns_for "$app")
		secret=$(secret_name_for "$label" "$app")
		echo "  [dry-run] would drop $label: $ns/$secret  (APPS_APPLY_DROP_DISABLED=1)"
		return 0
	fi
	echo "=== apps-apply: drop $label APP=$app (enabled: false) ==="
	if (
		cd "$REPO"
		export APPS_MERGED_FILE="$merged"
		export APPS_REGISTRY="$REG"
		export REPO_ROOT="$REPO"
		make "$maketarget" ENV="$ENV" "APP=$app" SKIP_CONFIRM=1
	); then
		return 0
	fi
	echo "✗ apps-apply: drop $label APP=$app — ошибка make ($maketarget)" >&2
	if [[ "${APPS_APPLY_CONTINUE_ON_ERROR:-}" == "1" ]]; then
		HAD_FAILURE=1
	else
		exit 1
	fi
}

# === Проход 1: создать/обновить учётки enabled: true приложений ===
if [[ "$DRY_RUN" == "1" ]]; then
	echo "=== apps-apply (DRY-RUN): enabled: true ==="
fi
while IFS= read -r app; do
	[[ -n "${app:-}" ]] || continue

	if svc_active postgres && field_nonempty "$app" "postgres.password"; then
		invoke postgres pg-app-create "$app"
	fi
	if svc_active redis && field_nonempty "$app" "redis.password"; then
		invoke redis redis-app-create "$app"
	fi
	if svc_active kafka && field_nonempty "$app" "kafka.password"; then
		invoke kafka kafka-app-create "$app"
	fi
	if svc_active minio && field_nonempty "$app" "minio.secret_key"; then
		invoke minio minio-app-create "$app"
	fi
	if svc_active clickhouse && field_nonempty "$app" "clickhouse.password"; then
		invoke clickhouse clickhouse-app-create "$app"
	fi
	if svc_active rabbitmq && field_nonempty "$app" "rabbitmq.password"; then
		invoke rabbitmq rabbitmq-app-create "$app"
	fi

done < <("$YQBIN" -r '.apps[].name' "$merged")

# === Проход 2: drift detection / drop для enabled: false приложений ===
DRIFT_COUNT=0
DROPPED_COUNT=0

if [[ "$DRY_RUN" == "1" ]]; then
	echo ""
	echo "=== apps-apply (DRY-RUN): enabled: false (проверка дрейфа) ==="
fi

while IFS= read -r app_disabled; do
	[[ -n "${app_disabled:-}" ]] || continue
	ns=$(app_ns_for "$app_disabled")
	[[ -n "$ns" ]] || continue

	for svc in postgres redis kafka minio clickhouse rabbitmq; do
		svc_active "$svc" || continue
		secret=$(secret_name_for "$svc" "$app_disabled")
		# Имя корневой make-цели для drop (postgres использует pg-app-drop, остальные следуют шаблону).
		case "$svc" in
			postgres) drop_target=pg-app-drop ;;
			*)        drop_target="${svc}-app-drop" ;;
		esac
		if secret_exists "$ns" "$secret"; then
			if [[ "$DROP_DISABLED" == "1" ]]; then
				DROPPED_COUNT=$((DROPPED_COUNT + 1))
				invoke_drop "$svc" "$drop_target" "$app_disabled"
			else
				DRIFT_COUNT=$((DRIFT_COUNT + 1))
				echo "⚠ drift: $ns/$secret существует, но в registry $app_disabled = enabled: false."
				echo "  Выполните либо APPS_APPLY_DROP_DISABLED=1 make apps-apply, либо make $drop_target APP=$app_disabled."
			fi
		fi
	done
done < <("$YQBIN" -r '.apps[] | select(.enabled == false) | .name' "$REG")

if [[ "$HAD_FAILURE" -ne 0 ]]; then
	echo '✗ apps-apply завершён с ошибками (см. сообщения make выше)' >&2
	exit 1
fi

if [[ "$DRY_RUN" == "1" ]]; then
	echo ""
	echo "✓ apps-apply (DRY-RUN) завершён. Drift-учёток: $DRIFT_COUNT, would drop (если APPS_APPLY_DROP_DISABLED=1): $DROPPED_COUNT"
elif [[ "$DROP_DISABLED" == "1" ]]; then
	echo "✓ apps-apply завершён. Drop disabled: $DROPPED_COUNT"
elif [[ "$DRIFT_COUNT" -gt 0 ]]; then
	echo "✓ apps-apply завершён. Обнаружен дрейф ($DRIFT_COUNT учёток), см. ⚠ выше"
else
	echo "✓ apps-apply завершён"
fi
