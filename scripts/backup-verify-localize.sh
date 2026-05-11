#!/usr/bin/env bash
# backup-verify-localize.sh — подменить prod URL в restored Secret'ах + apps/conf/.
#
# Контекст: env-restore из prod кладёт в Secret <APP>-minio поле MINIO_PUBLIC_ENDPOINT
# с prod hostname (например, https://s3.example.com), который используется backend'ом
# приложения для генерации presigned URL. В DST_ENV это hostname либо не резолвится,
# либо (хуже) указывает в prod — тогда local-приложение при первом presigned-запросе
# уходит в prod-MinIO. Скрипт меняет такие значения на in-cluster URL DST.
#
# Также прорабатывается apps/conf/<APP>/<DST_ENV>/secrets.yaml (восстановленный из env-backup
# с OVERWRITE_APPS_CONF=1) — поле minio.public_endpoint.
#
# Гарантии безопасности:
#   - Hardcoded guard: DST_ENV ∉ PROD_ENVS (по умолчанию "prod production").
#   - LOCALIZE_DRY_RUN=1 — печатает план без изменений.
#
# Args (env):
#   DST_ENV               — целевой env. Обязательно.
#   APP                   — APP, у которого правим. Обязательно (по нему вычисляем app_ns).
#   REPO_ROOT             — корень репо. По умолчанию $(pwd).
#   KUBECONFIG            — kubeconfig DST. Обязательно.
#   APPS_REGISTRY         — путь к apps/registry.yaml. По умолчанию $REPO_ROOT/apps/registry.yaml.
#   YQ                    — путь к mikefarah yq. По умолчанию "yq".
#   IN_CLUSTER_MINIO_URL  — URL для подмены. По умолчанию http://minio.minio.svc.cluster.local:9000.
#   PROD_ENVS             — blocklist. По умолчанию "prod production".
#   LOCALIZE_DRY_RUN      — печатать план без записи (1/0). По умолчанию 0.
#
# Stdout: список подмен + кратко итог.
#
# Exit:
#   0 — все подмены успешны (или ничего менять не пришлось).
#   1 — критичная ошибка (DST_ENV ∈ prod, нет k8s доступа, …).

set -uo pipefail

DST_ENV="${DST_ENV:-}"
APP="${APP:-}"
REPO_ROOT="${REPO_ROOT:-$(pwd)}"
KUBECONFIG_FILE="${KUBECONFIG:-}"
APPS_REGISTRY="${APPS_REGISTRY:-$REPO_ROOT/apps/registry.yaml}"
YQ_BIN="${YQ:-yq}"
IN_CLUSTER_MINIO_URL="${IN_CLUSTER_MINIO_URL:-http://minio.minio.svc.cluster.local:9000}"
PROD_ENVS="${PROD_ENVS:-prod production}"
LOCALIZE_DRY_RUN="${LOCALIZE_DRY_RUN:-0}"

err() { echo "$@" >&2; }

[ -n "$DST_ENV" ] || { err "✗ DST_ENV не задан"; exit 1; }
[ -n "$APP" ]     || { err "✗ APP не задан"; exit 1; }
[ -n "$KUBECONFIG_FILE" ] || { err "✗ KUBECONFIG не задан"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { err "✗ kubectl не найден"; exit 1; }

# Hardcoded guard.
for p in $PROD_ENVS; do
  if [ "$DST_ENV" = "$p" ]; then
    err "✗ localize запрещён для DST_ENV=$DST_ENV (PROD_ENVS=\"$PROD_ENVS\")"
    err "  Этот скрипт меняет данные в кластере; вызов с prod-целью — почти всегда ошибка."
    exit 1
  fi
done

# app_ns из реестра.
APP_NS=$(NM="$APP" "$YQ_BIN" -r '.apps[] | select(.name == strenv(NM)) | ((.app_ns | select(. != null and . != "")) // .name)' "$APPS_REGISTRY" 2>/dev/null || true)
[ -n "$APP_NS" ] || APP_NS="$APP"

echo "=== backup-verify-localize: DST_ENV=$DST_ENV APP=$APP app_ns=$APP_NS ==="
if [ "$LOCALIZE_DRY_RUN" = "1" ]; then echo "  режим: DRY-RUN (изменения не применяются)"; fi

CHANGES=0
SKIPPED=0
ERRORS=0

# ---------------------------------------------------------------------------
# 1. Secret <APP>-minio в namespace приложения.
#    Ключи, которые могут содержать prod URL: MINIO_PUBLIC_ENDPOINT (см. minio/Makefile:218).
#    MINIO_ENDPOINT обычно in-cluster и менять его не нужно — но проверим, что он
#    не указывает на внешний host.
# ---------------------------------------------------------------------------
SECRET_NAME="${APP}-minio"
echo ""
echo "-- Secret $APP_NS/$SECRET_NAME"

if ! kubectl --kubeconfig "$KUBECONFIG_FILE" -n "$APP_NS" get secret "$SECRET_NAME" >/dev/null 2>&1; then
  echo "  ↷ Secret не найден — приложение не привязано к MinIO (skip)"
  SKIPPED=$((SKIPPED+1))
else
  for key in MINIO_PUBLIC_ENDPOINT MINIO_ENDPOINT; do
    cur_b64=$(kubectl --kubeconfig "$KUBECONFIG_FILE" -n "$APP_NS" get secret "$SECRET_NAME" \
      -o jsonpath="{.data.$key}" 2>/dev/null || true)
    if [ -z "$cur_b64" ]; then
      echo "  ↷ ключ $key отсутствует"
      continue
    fi
    cur=$(printf '%s' "$cur_b64" | base64 -d 2>/dev/null || true)
    if [ -z "$cur" ]; then
      echo "  ⚠ ключ $key есть, но base64 не декодируется"
      continue
    fi
    # Логика: для MINIO_PUBLIC_ENDPOINT всегда подменяем на in-cluster URL, если он не in-cluster.
    # Для MINIO_ENDPOINT — только если содержит внешний (не *.svc.cluster.local) host.
    must_replace=0
    case "$key" in
      MINIO_PUBLIC_ENDPOINT)
        if [ "$cur" != "$IN_CLUSTER_MINIO_URL" ]; then must_replace=1; fi
        ;;
      MINIO_ENDPOINT)
        case "$cur" in
          *.svc.cluster.local*|*minio.minio*) must_replace=0 ;;
          *) must_replace=1 ;;
        esac
        ;;
    esac
    if [ "$must_replace" = "0" ]; then
      echo "  ✓ $key уже локализован: $cur"
      continue
    fi
    echo "  $key: $cur  →  $IN_CLUSTER_MINIO_URL"
    if [ "$LOCALIZE_DRY_RUN" = "1" ]; then
      CHANGES=$((CHANGES+1))
      continue
    fi
    new_b64=$(printf '%s' "$IN_CLUSTER_MINIO_URL" | base64 | tr -d '\n')
    if kubectl --kubeconfig "$KUBECONFIG_FILE" -n "$APP_NS" patch secret "$SECRET_NAME" \
        --type=json -p "[{\"op\":\"replace\",\"path\":\"/data/$key\",\"value\":\"$new_b64\"}]" >/dev/null; then
      echo "    ✓ применено"
      CHANGES=$((CHANGES+1))
    else
      echo "    ✗ kubectl patch упал"
      ERRORS=$((ERRORS+1))
    fi
  done
fi

# ---------------------------------------------------------------------------
# 2. apps/conf/<APP>/<DST_ENV>/secrets.yaml — minio.public_endpoint поле.
# ---------------------------------------------------------------------------
CONF_FILE="$REPO_ROOT/apps/conf/$APP/$DST_ENV/secrets.yaml"
echo ""
echo "-- $CONF_FILE"

if [ ! -f "$CONF_FILE" ]; then
  echo "  ↷ файл отсутствует — apps/conf не восстановлен (skip)"
  SKIPPED=$((SKIPPED+1))
else
  cur=$(APP_NAME="$APP" "$YQ_BIN" -r '.minio.public_endpoint // ""' "$CONF_FILE" 2>/dev/null || true)
  if [ -z "$cur" ]; then
    echo "  ↷ minio.public_endpoint отсутствует"
  elif [ "$cur" = "$IN_CLUSTER_MINIO_URL" ]; then
    echo "  ✓ minio.public_endpoint уже локализован: $cur"
  else
    echo "  minio.public_endpoint: $cur  →  $IN_CLUSTER_MINIO_URL"
    if [ "$LOCALIZE_DRY_RUN" = "1" ]; then
      CHANGES=$((CHANGES+1))
    else
      # yq inplace редактирование. Backup-копия .bak — на случай отката.
      cp -p "$CONF_FILE" "$CONF_FILE.localize.bak"
      if VAL="$IN_CLUSTER_MINIO_URL" "$YQ_BIN" -i '.minio.public_endpoint = strenv(VAL)' "$CONF_FILE" 2>/dev/null; then
        chmod 600 "$CONF_FILE"
        echo "    ✓ применено (backup: $CONF_FILE.localize.bak)"
        CHANGES=$((CHANGES+1))
      else
        echo "    ✗ yq -i упал"
        ERRORS=$((ERRORS+1))
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
echo ""
echo "=== localize summary: changes=$CHANGES skipped=$SKIPPED errors=$ERRORS ==="

if [ "$ERRORS" -gt 0 ]; then exit 1; fi
exit 0
