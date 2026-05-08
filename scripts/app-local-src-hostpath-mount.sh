#!/usr/bin/env bash
# Смонтировать REPO_ROOT/apps/src/<APP> в pod(s) через hostPath (только ENV=local, MicroK8s на той же машине).
# Переменные: ENV, REPO_ROOT, APP, APPS_REGISTRY; KUBECONFIG; опционально APPS_MERGED_FILE, APP_NS.
# Обязательно: APP_LOCAL_K8S_WORKLOAD=deployment|deploy|statefulset|sts|daemonset|ds|pod + /имя
# Опционально: APP_LOCAL_SRC_MOUNT_PATH (по умолчанию /work/src); APP_LOCAL_SRC_CONTAINER — один контейнер (init или app);
# APP_LOCAL_SRC_READ_ONLY=1 — readOnly в volumeMount; mount добавляется и в initContainers и в containers.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/apps-yq-probe.sh"

ENV="${ENV:?}"
if [[ "$ENV" != "local" ]]; then
	echo "✗ app-local-src-hostpath-mount: только ENV=local (сейчас: $ENV)" >&2
	exit 1
fi

REPO="${REPO_ROOT:?}"
APP="${APP:?}"
REG="${APPS_REGISTRY:?}"

REPO_ABS=$(cd "$REPO" && pwd)
HOST_SRC="$REPO_ABS/apps/src/$APP"

WK="${APP_LOCAL_K8S_WORKLOAD:-}"
if [[ -z "${WK// /}" ]]; then
	echo "✗ Задайте APP_LOCAL_K8S_WORKLOAD=<kind>/<имя> (deployment|deploy|statefulset|sts|daemonset|ds|pod)" >&2
	exit 1
fi

if [[ -n "${APPS_MERGED_FILE:-}" && -f "${APPS_MERGED_FILE:-}" ]]; then
	merged_file="$APPS_MERGED_FILE"
	clean_merged=0
else
	merged_file=$(mktemp)
	clean_merged=1
	if ! "$SCRIPT_DIR/apps-merge-config.sh" "$REG" "$REPO_ABS" >"$merged_file"; then
		rm -f "$merged_file"
		exit 1
	fi
fi

APP_NS_RAW=$("$SCRIPT_DIR/app-config-get.sh" "$merged_file" "$APP" app_ns || true)
[[ "$clean_merged" -eq 1 ]] && rm -f "$merged_file"
if [[ -n "${APP_NS:-}" ]]; then
	NS="$APP_NS"
elif [[ -n "${APP_NS_RAW:-}" && "$APP_NS_RAW" != "null" ]]; then
	NS="$APP_NS_RAW"
else
	NS="$APP"
fi

export APP_NS="$NS"
export APP_LOCAL_SRC_HOST_PATH="$HOST_SRC"
export APP_LOCAL_SRC_MOUNT_PATH="${APP_LOCAL_SRC_MOUNT_PATH:-/work/src}"
export APP_LOCAL_SRC_READ_ONLY="${APP_LOCAL_SRC_READ_ONLY:-}"

if [[ ! -d "$HOST_SRC" ]]; then
	echo "⚠ На хосте нет каталога $HOST_SRC — на ноде кластера pod увидит пустую директорию после первого монтирования (DirectoryOrCreate)." >&2
fi

python3 "$SCRIPT_DIR/lib/app-local-src-hostpath-mount.py"
