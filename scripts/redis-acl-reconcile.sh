#!/usr/bin/env bash
# Реконсилирует Valkey ACL по состоянию apps/registry.yaml + apps/conf/<APP>/<ENV>/.
#
# Принцип: источник истины — merged apps config; никаких per-app ACL SETUSER в обход
# Secret valkey-auth. Результат переживает рестарт пода и не зависит от порядка вызовов.
#
# Алгоритм:
#  1. Регенерировать overlay `redis/values-<ENV>.acl.yaml` (auth.aclConfig) через
#     scripts/redis-build-acl-overlay.sh. helmfile подхватывает overlay
#     дополнительным values-файлом → чарт valkey кладёт aclConfig в Secret
#     valkey-auth. Следующий `helm upgrade` (даже минуя `make up`) не откатит ACL.
#  2. Desired users.acl = user default (хэш admin-пароля из Secret redis/redis) +
#     aclConfig из overlay. Это байт-в-байт то, что init-контейнер чарта собирает
#     при старте пода (redis/valkey/templates/init_config.yaml).
#  3. Патч Secret valkey-auth (ключ aclConfig) — persistence: при рестарте пода
#     init-контейнер пересоберёт aclfile уже с ним.
#  4. kubectl exec ... > /etc/valkey/users.acl — для немедленного применения
#     (emptyDir собирается только при старте пода).
#  5. ACL LOAD — атомарная замена ACL в памяти содержимым aclfile.
#
# Env (обязательно): APPS_REGISTRY, REPO_ROOT, ENV.
# Env (опционально): APPS_MERGED_FILE (если уже подготовлен; иначе скрипт вычислит),
#                    NAMESPACE (default: redis), RELEASE (default: valkey),
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
RELEASE="${RELEASE:-valkey}"
SECRET_NAME="${REDIS_AUTH_SECRET_NAME:-redis}"
SECRET_KEY="${REDIS_AUTH_SECRET_PASSWORD_KEY:-redis-password}"
OVERLAY="$REPO/redis/values-$ENV.acl.yaml"
AUTH_SECRET="$RELEASE-auth"

command -v kubectl >/dev/null 2>&1 || { echo "✗ kubectl не найден в PATH" >&2; exit 1; }
command -v jq      >/dev/null 2>&1 || { echo "✗ jq не найден в PATH (нужен для патча Secret)" >&2; exit 1; }

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

# Шаг 1: регенерация overlay для helm (единственный источник строк app-users).
APPS_REGISTRY="$REG" REPO_ROOT="$REPO" ENV="$ENV" APPS_MERGED_FILE="$MERGED" OUTPUT_FILE="$OVERLAY" \
	"$SCRIPT_DIR/redis-build-acl-overlay.sh"
ACL_CONFIG=$("$YQBIN" -r '.auth.aclConfig // ""' "$OVERLAY")
APP_COUNT=$(printf '%s' "$ACL_CONFIG" | grep -c '^user ' || true)

POD=$(kubectl get pods -n "$NAMESPACE" \
	-l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/name=valkey" \
	--field-selector=status.phase=Running \
	-o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "$POD" ]]; then
	echo "✗ Valkey pod не найден в namespace $NAMESPACE (label app.kubernetes.io/instance=$RELEASE)" >&2
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
# Как init.sh чарта: строка default (permissions из values auth.aclUsers.default), затем aclConfig.
printf 'user default on #%s ~* &* +@all\n' "$ADMIN_HASH" >"$USERS_ACL"
[[ -n "$ACL_CONFIG" ]] && printf '%s' "$ACL_CONFIG" >>"$USERS_ACL"

echo "→ desired users.acl: 1 default + $APP_COUNT app users"

# Шаг 3: Secret valkey-auth. Чарт создаёт его только при непустом aclConfig — если
# приложения есть, а Secret нет, значит helm ещё не применял overlay.
if kubectl get secret -n "$NAMESPACE" "$AUTH_SECRET" >/dev/null 2>&1; then
	kubectl get secret -n "$NAMESPACE" "$AUTH_SECRET" -o json |
		jq --arg c "$(printf '%s' "$ACL_CONFIG" | base64 -w0)" \
			'if $c == "" then del(.data.aclConfig) else .data.aclConfig=$c end' |
		kubectl apply -f - >/dev/null
	echo "✓ Secret $NAMESPACE/$AUTH_SECRET patched (aclConfig)"
elif [[ "$APP_COUNT" -gt 0 ]]; then
	echo "✗ Secret $NAMESPACE/$AUTH_SECRET не найден, а app-users есть. Сначала: make up ENABLED_SERVICES=redis" >&2
	exit 1
fi

# Шаг 4: перезапись aclfile в живом поде (init ставит 0400 — снимаем на время записи).
kubectl exec -i "$POD" -n "$NAMESPACE" -c "$RELEASE" -- \
	sh -c 'chmod 0600 /etc/valkey/users.acl && cat > /etc/valkey/users.acl && chmod 0400 /etc/valkey/users.acl' <"$USERS_ACL"
echo "✓ aclfile перезаписан в поде $POD (/etc/valkey/users.acl)"

# Шаг 5: ACL LOAD — полное замещение: пользователи, исчезнувшие из конфига, выпадают из памяти.
OUT=$(kubectl exec "$POD" -n "$NAMESPACE" -c "$RELEASE" -- env REDISCLI_AUTH="$ADMIN_PW" \
	valkey-cli --no-auth-warning ACL LOAD 2>&1)
if [[ "$OUT" != "OK" ]]; then
	echo "✗ ACL LOAD failed: $OUT" >&2
	exit 1
fi
echo "✓ Valkey ACL LOAD OK ($NAMESPACE/$POD)"
echo "✓ redis-acl-reconcile завершён (ENV=$ENV, apps=$APP_COUNT)"
