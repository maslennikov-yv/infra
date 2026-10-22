#!/usr/bin/env bash
# Переход живого окружения с Bitnami Redis (release redis) на Valkey (release valkey).
# Runbook: docs/runbooks/redis-to-valkey.md. Шаги:
#   1. preflight: старый release redis есть, Secret redis/redis есть;
#   2. overlay ACL + helmfile apply только release valkey (рядом со старым);
#   3. ⏸ подтверждение: запись приложений в Redis остановлена (scale 0 / maintenance);
#   4. копирование ключей командами по типам + сверка (scripts/redis-copy-keys.py) —
#      RDB Redis 8 (v12) Valkey не читает, replicaof/RDB-restore невозможны;
#   5. helm uninstall redis (PVC redis-data-redis-master-0 остаётся — для отката);
#   6. make up ENABLED_SERVICES=redis: redis-compat (Service redis-master → valkey) + apps-apply;
#   7. redis-app-verify для приложений с Secret <APP>-redis.
#
# Env: ENV, KUBECONFIG, APPS_REGISTRY, REPO_ROOT (передаёт корневой Makefile); SKIP_CONFIRM=1 —
# без вопроса на шаге 3 (только если запись уже остановлена).
set -euo pipefail

ENV="${ENV:?ENV required}"
KUBECONFIG="${KUBECONFIG:?KUBECONFIG required}"
REPO="${REPO_ROOT:?REPO_ROOT required}"
REG="${APPS_REGISTRY:?APPS_REGISTRY required}"
export KUBECONFIG
NS=redis
k() { kubectl -n "$NS" "$@"; }
step() { echo ""; echo "=== $* (ENV=$ENV, ns=$NS) ==="; }

step "1/7 preflight"
helm -n "$NS" status redis >/dev/null 2>&1 || { echo "✗ release $NS/redis не найден — переходить не с чего (уже Valkey?)" >&2; exit 1; }
k get secret redis >/dev/null || { echo "✗ Secret $NS/redis не найден" >&2; exit 1; }
PW=$(k get secret redis -o jsonpath='{.data.redis-password}' | base64 -d)
[ -n "$PW" ] || { echo "✗ пустой redis-password в Secret $NS/redis" >&2; exit 1; }
command -v uv >/dev/null || { echo "✗ нужен uv (запуск scripts/redis-copy-keys.py с пакетом redis)" >&2; exit 1; }
echo "✓ release redis есть; сервер: $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"

step "2/7 release valkey рядом со старым"
APPS_REGISTRY="$REG" REPO_ROOT="$REPO" ENV="$ENV" "$REPO/scripts/redis-build-acl-overlay.sh"
(cd "$REPO" && ENV="$ENV" ENABLED_SERVICES=redis RABBITMQ_PASSWORD=x RABBITMQ_ERLANG_COOKIE=x \
	helmfile -f helmfile.yaml.gotmpl -e default -l name=valkey apply)
k rollout status deploy/valkey --timeout=180s

step "3/7 остановка записи"
if [ "${SKIP_CONFIRM:-}" != "1" ]; then
	echo "Остановите запись приложений в Redis (scale 0 воркеров/API или maintenance)."
	echo "Ключи, записанные в старый Redis после копирования, будут потеряны."
	read -r -p "Запись остановлена? [y/N] " ans
	[ "$ans" = y ] || [ "$ans" = Y ] || { echo "Отменено. Release valkey оставлен — удалить: helm -n $NS uninstall valkey"; exit 1; }
fi

step "4/7 копирование ключей redis → valkey"
# Порты занятыми быть не должны: чужая port-forward на том же порту молча отправила бы ключи
# не туда. Проверяем до запуска и что обе forward живы после.
for p in 16379 16380; do
	if ss -ltn 2>/dev/null | grep -q ":$p "; then echo "✗ порт $p уже занят (старая port-forward?) — освободите" >&2; exit 1; fi
done
# kubectl напрямую, не через функцию k: «k … &» даёт в $! PID подоболочки, и kill не гасит kubectl.
PF_LOG=$(mktemp)
kubectl -n "$NS" port-forward svc/redis-master 16379:6379 >"$PF_LOG" 2>&1 & P1=$!
kubectl -n "$NS" port-forward svc/valkey 16380:6379 >>"$PF_LOG" 2>&1 & P2=$!
trap 'kill $P1 $P2 2>/dev/null || true; rm -f "$PF_LOG"' EXIT
sleep 3
kill -0 $P1 2>/dev/null && kill -0 $P2 2>/dev/null || { echo "✗ port-forward не поднялась:" >&2; cat "$PF_LOG" >&2; exit 1; }
SRC_URL="redis://default:$PW@127.0.0.1:16379" DST_URL="redis://default:$PW@127.0.0.1:16380" \
	uv run -q --with 'redis>=5' python -I "$REPO/scripts/redis-copy-keys.py" \
	|| { echo "✗ копирование/сверка с ошибками — старый Redis не тронут, разберитесь и повторите" >&2; exit 1; }
kill $P1 $P2 2>/dev/null || true; wait $P1 $P2 2>/dev/null || true

step "5/7 удаление release redis (PVC остаётся для отката)"
helm -n "$NS" uninstall redis --wait
k get pvc

step "6/7 redis-compat + apps-apply"
make -C "$REPO" up ENV="$ENV" ENABLED_SERVICES=redis KUBECONFIG="$KUBECONFIG" APPS_REGISTRY="$REG"

step "7/7 smoke приложений"
FAIL=0
for app in $("${YQ:-$REPO/.tools/yq-mikefarah}" -r '.apps[] | select(.enabled == true) | .name' "$REG"); do
	ns=$("${YQ:-$REPO/.tools/yq-mikefarah}" -r ".apps[] | select(.name == \"$app\") | .app_ns // \"$app\"" "$REG")
	kubectl -n "$ns" get secret "$app-redis" >/dev/null 2>&1 || continue
	make -C "$REPO" redis-app-verify APP="$app" APP_NS="$ns" ENV="$ENV" KUBECONFIG="$KUBECONFIG" || FAIL=1
done
[ "$FAIL" = 0 ] || { echo "✗ smoke упал — см. выше; откат: docs/runbooks/redis-to-valkey.md" >&2; exit 1; }
echo ""
echo "✓ Переход на Valkey завершён. Приложениям нужен рестарт, чтобы перечитать REDIS_HOST"
echo "  (до этого их держит Service redis-master из redis-compat)."
