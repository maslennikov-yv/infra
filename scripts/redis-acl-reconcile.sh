#!/usr/bin/env bash
# Реконсилирует Redis ACL по состоянию apps/registry.yaml + apps/conf/<APP>/<ENV>/.
#
# Принцип: источник истины — merged apps config; никаких per-app ACL SETUSER в обход
# ConfigMap. Результат переживает рестарт пода и не зависит от порядка вызовов.
#
# Алгоритм:
#  1. Регенерировать overlay `redis/values-<ENV>.acl.yaml` через
#     scripts/redis-build-acl-overlay.sh. helmfile подхватывает overlay
#     дополнительным values-файлом → Bitnami chart рендерит users.acl в
#     ConfigMap уже с app-users. Это значит: следующий `helm upgrade` (даже
#     минуя `make up`) не откатит ACL.
#  2. Собрать desired users.acl: default (с хэшем admin-пароля) + все enabled
#     приложения с непустым redis.password. Формат строк bit-to-bit совпадает
#     с тем, что генерирует Bitnami chart из overlay — иначе helm-upgrade
#     увидит diff и сделает rolling restart redis-master впустую.
#  3. kubectl apply ConfigMap redis-configuration (поле data."users.acl") —
#     persistence: при рестарте пода Bitnami start-script копирует users.acl
#     из ConfigMap в emptyDir, на который указывает aclfile.
#  4. kubectl exec ... cat > /opt/bitnami/redis/etc/users.acl — для немедленного
#     применения (emptyDir не синхронизируется с ConfigMap в рантайме).
#  5. redis-cli ACL LOAD — атомарная замена ACL в памяти содержимым aclfile.
#
# Env (обязательно): APPS_REGISTRY, REPO_ROOT, ENV.
# Env (опционально): APPS_MERGED_FILE (если уже подготовлен; иначе скрипт вычислит),
#                    NAMESPACE (default: redis), RELEASE (default: redis),
#                    REDIS_AUTH_SECRET_NAME (default: redis),
#                    REDIS_AUTH_SECRET_PASSWORD_KEY (default: redis-password),
#                    KUBECONFIG.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/apps-yq-probe.sh"

REG="${APPS_REGISTRY:?APPS_REGISTRY required}"
REPO="${REPO_ROOT:?REPO_ROOT required}"
ENV="${ENV:?ENV required}"

NAMESPACE="${NAMESPACE:-redis}"
RELEASE="${RELEASE:-redis}"
SECRET_NAME="${REDIS_AUTH_SECRET_NAME:-redis}"
SECRET_KEY="${REDIS_AUTH_SECRET_PASSWORD_KEY:-redis-password}"

command -v kubectl >/dev/null 2>&1 || { echo "✗ kubectl не найден в PATH" >&2; exit 1; }
command -v jq      >/dev/null 2>&1 || { echo "✗ jq не найден в PATH (нужен для патча ConfigMap)" >&2; exit 1; }

MERGED="${APPS_MERGED_FILE:-}"
CLEAN_MERGED=0
if [[ -z "$MERGED" ]]; then
	MERGED=$(mktemp)
	CLEAN_MERGED=1
	"$SCRIPT_DIR/apps-merge-config.sh" "$REG" "$REPO" "$ENV" >"$MERGED"
fi

declare -a CLEANUP_FILES=()
[[ "$CLEAN_MERGED" == "1" ]] && CLEANUP_FILES+=("$MERGED")
cleanup() {
	local f
	for f in "${CLEANUP_FILES[@]:-}"; do
		[[ -n "$f" ]] && rm -f "$f"
	done
}
trap cleanup EXIT INT TERM

# Шаг 1: регенерация overlay для helm. Если overlay уже актуален —
# build-overlay сохраняет mtime и ничего не пишет. helmfile подхватит файл
# при следующем apply (см. helmfile.yaml.gotmpl, $hasRedisAcl).
APPS_REGISTRY="$REG" REPO_ROOT="$REPO" ENV="$ENV" APPS_MERGED_FILE="$MERGED" \
	"$SCRIPT_DIR/redis-build-acl-overlay.sh"

POD=$(kubectl get pods -n "$NAMESPACE" \
	-l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/name=redis,app.kubernetes.io/component=master" \
	-o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "$POD" ]]; then
	echo "✗ Redis master pod не найден в namespace $NAMESPACE (label app.kubernetes.io/instance=$RELEASE,component=master)" >&2
	exit 1
fi

if ! kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
	echo "✗ Secret $NAMESPACE/$SECRET_NAME не найден" >&2
	exit 1
fi
ADMIN_PW=$(kubectl get secret -n "$NAMESPACE" "$SECRET_NAME" \
	-o jsonpath="{.data['$SECRET_KEY']}" 2>/dev/null | base64 -d)
if [[ -z "$ADMIN_PW" ]]; then
	echo "✗ Не удалось прочитать ключ '$SECRET_KEY' из Secret $NAMESPACE/$SECRET_NAME" >&2
	exit 1
fi
ADMIN_HASH=$(printf '%s' "$ADMIN_PW" | sha256sum | awk '{print $1}')

USERS_ACL=$(mktemp)
CLEANUP_FILES+=("$USERS_ACL")

# default user — формат совпадает с тем, что рендерит чарт redis в templates/configmap.yaml.
printf 'user default on #%s ~* &* +@all\n' "$ADMIN_HASH" >>"$USERS_ACL"

# Запрещённые команды для приложений: ACL/CONFIG/SHUTDOWN, FLUSH*/KEYS, репликация,
# модули, debug/monitor. Список синхронен со старой логикой redis/Makefile app-create.
DENY="-ACL -CONFIG -SHUTDOWN -MODULE -DEBUG -COMMAND -KEYS -FLUSHALL -FLUSHDB -LATENCY -MEMORY -MONITOR -SAVE -BGSAVE -BGREWRITEAOF -REPLCONF -REPLICAOF -SLAVEOF -SYNC -PSYNC"

APP_COUNT=0
SKIPPED=()
while IFS= read -r app; do
	[[ -n "$app" ]] || continue
	PW=$("$SCRIPT_DIR/app-config-get.sh" "$MERGED" "$app" redis.password 2>/dev/null || true)
	if [[ -z "$PW" || "$PW" == "null" ]]; then
		SKIPPED+=("$app")
		continue
	fi

	USERNAME=$("$SCRIPT_DIR/app-config-get.sh" "$MERGED" "$app" redis.username 2>/dev/null || true)
	[[ -z "$USERNAME" || "$USERNAME" == "null" ]] && USERNAME="app_$app"

	KEY_PREFIX=$("$SCRIPT_DIR/app-config-get.sh" "$MERGED" "$app" redis.key_prefix 2>/dev/null || true)
	if [[ -z "$KEY_PREFIX" || "$KEY_PREFIX" == "null" ]]; then
		KEYS_PAT="~${app}:*"
		CH_PAT="&${app}:*"
	else
		KEYS_PAT="~${KEY_PREFIX}*"
		CH_PAT="&${KEY_PREFIX}*"
	fi
	APP_HASH=$(printf '%s' "$PW" | sha256sum | awk '{print $1}')
	# Формат строки совпадает с рендером Bitnami chart из auth.acl.users
	# (см. redis/redis/templates/configmap.yaml L66) — это критично, иначе
	# helm-upgrade увидит diff в ConfigMap и сделает rolling restart redis-master.
	# &<prefix>* — pub/sub channel pattern (симметрично keys); без него
	# SUBSCRIBE/PUBLISH у приложения падают с NOPERM.
	printf 'user %s on #%s %s %s +@all %s\n' \
		"$USERNAME" "$APP_HASH" "$KEYS_PAT" "$CH_PAT" "$DENY" >>"$USERS_ACL"
	APP_COUNT=$((APP_COUNT + 1))
done < <("$YQBIN" -r '.apps[] | select(.enabled == true) | .name' "$MERGED")

echo "→ desired users.acl: 1 default + $APP_COUNT app users"
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
	echo "  (пропущено без redis.password в merged: ${SKIPPED[*]})"
fi

if ! kubectl get cm -n "$NAMESPACE" redis-configuration >/dev/null 2>&1; then
	echo "✗ ConfigMap $NAMESPACE/redis-configuration не найден. Сначала разверните Redis (make up ENABLED_SERVICES=redis)." >&2
	exit 1
fi

CONTENT=$(cat "$USERS_ACL")
kubectl get cm -n "$NAMESPACE" redis-configuration -o json |
	jq --arg c "$CONTENT" '.data["users.acl"]=$c' |
	kubectl apply -f - >/dev/null
echo "✓ ConfigMap $NAMESPACE/redis-configuration patched (users.acl)"

# Перезапись aclfile в живом поде. emptyDir (app-conf-dir) не синхронизируется
# с ConfigMap projection в рантайме — Bitnami копирует только при старте пода.
kubectl exec -i "$POD" -n "$NAMESPACE" -c redis -- \
	sh -c 'cat > /opt/bitnami/redis/etc/users.acl' <"$USERS_ACL"
echo "✓ aclfile перезаписан в поде $POD (/opt/bitnami/redis/etc/users.acl)"

# ACL LOAD: атомарное замещение текущих пользователей содержимым aclfile.
# Полное замещение — это и есть реконсилиация: пользователи, исчезнувшие из
# конфига, выпадают из памяти.
OUT=$(kubectl exec "$POD" -n "$NAMESPACE" -c redis -- env REDISCLI_AUTH="$ADMIN_PW" \
	redis-cli --no-auth-warning ACL LOAD 2>&1)
if [[ "$OUT" != "OK" ]]; then
	echo "✗ ACL LOAD failed: $OUT" >&2
	exit 1
fi
echo "✓ Redis ACL LOAD OK ($NAMESPACE/$POD)"
echo "✓ redis-acl-reconcile завершён (ENV=$ENV, apps=$APP_COUNT)"
