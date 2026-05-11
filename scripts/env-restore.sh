#!/usr/bin/env bash
# env-restore.sh — обратная операция к make env-backup.
#
# Распаковывает tar.gz с бэкапом окружения и применяет:
#   1) Secrets и ConfigMaps в namespaces (платформенные + приложенческие).
#   2) apps/conf/<APP>/ — копирует в REPO_ROOT/apps/conf/<APP>/, ЕСЛИ каталога ещё нет
#      (НЕ перезатирает существующий локальный конфиг).
#   3) apps/registry.yaml — копирует только при отсутствии локального файла; иначе
#      печатает предупреждение и diff-указание (живой реестр может быть свежее бэкапа).
#
# Поля Kubernetes metadata (creationTimestamp, resourceVersion, uid, selfLink, managedFields,
# ownerReferences) удаляются из применяемых yaml через yq, чтобы apply прошёл чисто.
# Если yq недоступен — yaml применяется как есть (kubectl стерпит, но могут быть warnings).
#
# Args (env vars):
#   BACKUP_FILE — путь к tar.gz, обязательно.
#   KUBECONFIG  — путь к kubeconfig, обязательно.
#   REPO_ROOT   — корень репозитория, по умолчанию текущая директория.
#   YQ          — путь к mikefarah yq, по умолчанию "yq".
#   CONFIRM=1   — пропустить интерактивное подтверждение.
#   SKIP_APPS_CONF=1   — НЕ восстанавливать apps/conf/ (только k8s ресурсы).
#   SKIP_K8S=1         — НЕ применять Secrets/ConfigMaps (только apps/conf/).
#   OVERWRITE_APPS_CONF=1 — перетереть существующие apps/conf/<APP>/ из архива
#                          (по умолчанию НЕ перетираются, чтобы не убить локальные creds).
#                          Используется backup-verify: на verify-стенде нужны именно prod creds.
#   ALLOW_SRC_EQUALS_DST=1 — отключить sanity-check «архив этого env применяется в тот же
#                          кластер, где env-backup был снят» (по умолчанию запрещено,
#                          чтобы не зальить prod снимком из prod при опечатке KUBECONFIG).
#
# Stdout: progress + summary. Exit 0 при успехе.

set -euo pipefail

BACKUP_FILE="${BACKUP_FILE:-}"
KUBECONFIG_FILE="${KUBECONFIG:-}"
REPO_ROOT="${REPO_ROOT:-$(pwd)}"
YQ_BIN="${YQ:-yq}"
CONFIRM="${CONFIRM:-0}"
SKIP_APPS_CONF="${SKIP_APPS_CONF:-0}"
SKIP_K8S="${SKIP_K8S:-0}"
OVERWRITE_APPS_CONF="${OVERWRITE_APPS_CONF:-0}"
ALLOW_SRC_EQUALS_DST="${ALLOW_SRC_EQUALS_DST:-0}"

err() { echo "$@" >&2; }

[ -n "$BACKUP_FILE" ] || { err "✗ BACKUP_FILE не задан"; exit 1; }
[ -f "$BACKUP_FILE" ] || { err "✗ Файл $BACKUP_FILE не найден"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { err "✗ kubectl не найден"; exit 1; }

if [ "$SKIP_K8S" != "1" ]; then
  [ -n "$KUBECONFIG_FILE" ] || { err "✗ KUBECONFIG не задан"; exit 1; }
  [ -f "$KUBECONFIG_FILE" ] || { err "✗ kubeconfig $KUBECONFIG_FILE не найден"; exit 1; }
fi

HAS_YQ=0
if command -v "$YQ_BIN" >/dev/null 2>&1; then HAS_YQ=1; fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "Распаковка $BACKUP_FILE..."
tar -xzf "$BACKUP_FILE" -C "$TMP"

# В архиве ровно один корневой каталог (имя окружения).
mapfile -t roots < <(find "$TMP" -mindepth 1 -maxdepth 1 -type d)
case "${#roots[@]}" in
	0) err "✗ Архив пуст или повреждён"; exit 1 ;;
	1) ARCHIVE_ROOT="${roots[0]}" ;;
	*) err "✗ Ожидался ровно один корневой каталог в архиве, нашёл ${#roots[@]}: ${roots[*]}"; exit 1 ;;
esac
ENV_NAME=$(basename "$ARCHIVE_ROOT")
echo "Окружение из архива: $ENV_NAME"

# Sanity-check «архив этого env применяется в тот же кластер, где env-backup был снят».
# Сравниваем server URL kubeconfig из архива (k8s/config/$ENV_NAME) с активным KUBECONFIG.
# Если оба указывают на одинаковый kube-API → восстановление prod-снимка в prod-кластер,
# что почти всегда — ошибка оператора (опечатка KUBECONFIG или ENV).
#
# Если k8s/config/$ENV_NAME отсутствует на admin (типично для backup-verify: prod kubeconfig
# не лежит на admin), мы НЕ можем проверить URL. По умолчанию это FAIL — иначе sanity-check
# тихо обходится и любой prod-snapshot можно случайно залить куда угодно. Обход:
#   - ALLOW_SRC_KUBECONFIG_MISSING=1 — пропустить sanity-check без kubeconfig источника (для verify).
#   - ALLOW_SRC_EQUALS_DST=1 — намеренный DR-restore того же env (cluster тот же).
if [ "$SKIP_K8S" != "1" ] && [ "$ALLOW_SRC_EQUALS_DST" != "1" ]; then
  SRC_KUBECONFIG="$REPO_ROOT/k8s/config/$ENV_NAME"
  if [ -f "$SRC_KUBECONFIG" ] && [ -f "$KUBECONFIG_FILE" ]; then
    SRC_URL=$(kubectl --kubeconfig "$SRC_KUBECONFIG" config view -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
    DST_URL=$(kubectl --kubeconfig "$KUBECONFIG_FILE" config view -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
    if [ -n "$SRC_URL" ] && [ -n "$DST_URL" ] && [ "$SRC_URL" = "$DST_URL" ]; then
      err ""
      err "✗ Sanity-check fail: kubeconfig источника (k8s/config/$ENV_NAME) и целевой KUBECONFIG"
      err "  указывают на ОДИН кластер ($DST_URL)."
      err "  Это значит, что снимок env=$ENV_NAME применяется в тот же кластер, где он снят —"
      err "  обычно опечатка KUBECONFIG/ENV. Если это намеренный DR-restore в свой же кластер,"
      err "  передайте ALLOW_SRC_EQUALS_DST=1."
      exit 1
    fi
  elif [ ! -f "$SRC_KUBECONFIG" ] && [ "${ALLOW_SRC_KUBECONFIG_MISSING:-0}" != "1" ]; then
    err ""
    err "✗ Sanity-check невозможен: k8s/config/$ENV_NAME отсутствует на admin-машине,"
    err "  поэтому server URL источника не сверить с целевым KUBECONFIG=$KUBECONFIG_FILE."
    err ""
    err "  Если уверены, что DST ≠ SRC (типичный случай для backup-verify: prod-снимок"
    err "  в local-кластер) — передайте ALLOW_SRC_KUBECONFIG_MISSING=1."
    err "  Альтернатива: положите prod kubeconfig в k8s/config/$ENV_NAME (read-only)."
    exit 1
  fi
fi

# Pre-flight summary
echo ""
echo "Содержимое архива:"

NAMESPACES=()
if [ -d "$ARCHIVE_ROOT/namespaces" ]; then
  for ns_dir in "$ARCHIVE_ROOT/namespaces"/*/; do
    [ -d "$ns_dir" ] || continue
    ns=$(basename "$ns_dir")
    NAMESPACES+=("$ns")
    sec_count=0; cm_count=0
    if [ "$HAS_YQ" = 1 ]; then
      [ -f "$ns_dir/secrets.yaml" ]    && sec_count=$("$YQ_BIN" '.items | length' "$ns_dir/secrets.yaml"    2>/dev/null || echo 0)
      [ -f "$ns_dir/configmaps.yaml" ] && cm_count=$( "$YQ_BIN" '.items | length' "$ns_dir/configmaps.yaml" 2>/dev/null || echo 0)
    fi
    printf "  ns=%-20s  secrets=%s  configmaps=%s\n" "$ns" "$sec_count" "$cm_count"
  done
fi

APPS_CONF_NEW=()
APPS_CONF_EXIST=()
if [ -d "$ARCHIVE_ROOT/apps/conf" ]; then
  for app_dir in "$ARCHIVE_ROOT/apps/conf"/*/; do
    [ -d "$app_dir" ] || continue
    app=$(basename "$app_dir")
    if [ -d "$REPO_ROOT/apps/conf/$app" ]; then
      APPS_CONF_EXIST+=("$app")
    else
      APPS_CONF_NEW+=("$app")
    fi
  done
fi

if [ ${#APPS_CONF_NEW[@]} -gt 0 ]; then
  echo ""
  echo "  apps/conf/ — будут добавлены (отсутствуют локально):"
  printf "    %s\n" "${APPS_CONF_NEW[@]}"
fi
if [ ${#APPS_CONF_EXIST[@]} -gt 0 ]; then
  if [ "$OVERWRITE_APPS_CONF" = "1" ]; then
    echo "  apps/conf/ — уже есть локально, БУДУТ ПЕРЕЗАПИСАНЫ (OVERWRITE_APPS_CONF=1):"
  else
    echo "  apps/conf/ — уже есть локально, НЕ перезаписываются (OVERWRITE_APPS_CONF=1 чтобы перезаписать):"
  fi
  printf "    %s\n" "${APPS_CONF_EXIST[@]}"
fi

REGISTRY_ACTION="none"
if [ -f "$ARCHIVE_ROOT/apps/registry.yaml" ]; then
  if [ ! -f "$REPO_ROOT/apps/registry.yaml" ]; then
    REGISTRY_ACTION="copy"
  elif ! cmp -s "$ARCHIVE_ROOT/apps/registry.yaml" "$REPO_ROOT/apps/registry.yaml"; then
    REGISTRY_ACTION="diff"
  fi
fi
case "$REGISTRY_ACTION" in
  copy) echo "  apps/registry.yaml: будет скопирован (локального нет)";;
  diff) echo "  apps/registry.yaml: ⚠ отличается от локального (локальный НЕ перезаписывается)";;
esac

# Confirm
if [ "$CONFIRM" != "1" ]; then
  echo ""
  if [ -t 0 ]; then
    printf "Продолжить? [y/N] "
    read -r ans
    case "$ans" in y|Y|yes|YES) : ;; *) echo "Отменено"; exit 1 ;; esac
  else
    err "✗ Для неинтерактивного запуска: CONFIRM=1"
    exit 1
  fi
fi

# Apply k8s resources
APPLIED_NS=0; APPLIED_FILES=0; FAILED_FILES=0
if [ "$SKIP_K8S" != "1" ]; then
  for ns in "${NAMESPACES[@]}"; do
    ns_dir="$ARCHIVE_ROOT/namespaces/$ns"
    echo ""
    echo "=== ns=$ns ==="
    kubectl --kubeconfig "$KUBECONFIG_FILE" create namespace "$ns" --dry-run=client -o yaml \
      | kubectl --kubeconfig "$KUBECONFIG_FILE" apply -f - >/dev/null
    APPLIED_NS=$((APPLIED_NS+1))

    for f in secrets.yaml configmaps.yaml; do
      [ -s "$ns_dir/$f" ] || continue
      # пустой List (items: []) пропускаем
      if [ "$HAS_YQ" = 1 ]; then
        items=$("$YQ_BIN" '.items | length' "$ns_dir/$f" 2>/dev/null || echo 0)
        if [ "$items" = "0" ]; then echo "  ↷ $f пуст, пропускаем"; continue; fi
        if "$YQ_BIN" \
          'del(.items[].metadata.creationTimestamp,
               .items[].metadata.resourceVersion,
               .items[].metadata.uid,
               .items[].metadata.selfLink,
               .items[].metadata.managedFields,
               .items[].metadata.ownerReferences)' \
          "$ns_dir/$f" \
          | kubectl --kubeconfig "$KUBECONFIG_FILE" apply -f - >/dev/null
        then
          echo "  ✓ applied $f"
          APPLIED_FILES=$((APPLIED_FILES+1))
        else
          echo "  ✗ failed: $f"
          FAILED_FILES=$((FAILED_FILES+1))
        fi
      else
        if kubectl --kubeconfig "$KUBECONFIG_FILE" apply -f "$ns_dir/$f" >/dev/null 2>&1; then
          echo "  ✓ applied $f (без yq-фильтрации)"
          APPLIED_FILES=$((APPLIED_FILES+1))
        else
          echo "  ✗ failed: $f"
          FAILED_FILES=$((FAILED_FILES+1))
        fi
      fi
    done
  done
fi

# Restore apps/conf/<APP>/ (новые всегда; существующие — только при OVERWRITE_APPS_CONF=1).
# Существующие apps/conf по умолчанию не перетираются, чтобы локальные креды и edited-secrets
# не убились молча; OVERWRITE_APPS_CONF=1 используется backup-verify, где целевой стенд
# должен работать на тех же creds, что и источник.
RESTORED_APPS_CONF=0
OVERWRITTEN_APPS_CONF=0
if [ "$SKIP_APPS_CONF" != "1" ]; then
  TO_PROCESS=()
  for app in "${APPS_CONF_NEW[@]}"; do TO_PROCESS+=("new:$app"); done
  if [ "$OVERWRITE_APPS_CONF" = "1" ]; then
    for app in "${APPS_CONF_EXIST[@]}"; do TO_PROCESS+=("overwrite:$app"); done
  fi
  if [ ${#TO_PROCESS[@]} -gt 0 ]; then
    echo ""
    echo "=== apps/conf/ ==="
    install -d -m 700 "$REPO_ROOT/apps/conf"
    for entry in "${TO_PROCESS[@]}"; do
      mode="${entry%%:*}"
      app="${entry#*:}"
      if [ "$mode" = "overwrite" ]; then
        rm -rf "$REPO_ROOT/apps/conf/$app"
      fi
      cp -r "$ARCHIVE_ROOT/apps/conf/$app" "$REPO_ROOT/apps/conf/$app"
      chmod -R go-rwx "$REPO_ROOT/apps/conf/$app"
      if [ "$mode" = "overwrite" ]; then
        echo "  ✓ overwritten apps/conf/$app"
        OVERWRITTEN_APPS_CONF=$((OVERWRITTEN_APPS_CONF+1))
      else
        echo "  ✓ restored apps/conf/$app"
        RESTORED_APPS_CONF=$((RESTORED_APPS_CONF+1))
      fi
    done
  fi
fi

# Restore apps/registry.yaml (только если отсутствует)
if [ "$REGISTRY_ACTION" = "copy" ]; then
  cp "$ARCHIVE_ROOT/apps/registry.yaml" "$REPO_ROOT/apps/registry.yaml"
  echo "  ✓ restored apps/registry.yaml"
fi

echo ""
echo "Summary:"
echo "  namespaces processed: $APPLIED_NS"
echo "  k8s manifests applied: $APPLIED_FILES (failed: $FAILED_FILES)"
if [ "$OVERWRITE_APPS_CONF" = "1" ]; then
  echo "  apps/conf/ restored:  $RESTORED_APPS_CONF new + $OVERWRITTEN_APPS_CONF overwritten"
else
  echo "  apps/conf/ restored:  $RESTORED_APPS_CONF (existing kept: ${#APPS_CONF_EXIST[@]}; OVERWRITE_APPS_CONF=1 чтобы перезаписать)"
fi
if [ "$REGISTRY_ACTION" = "diff" ]; then
  echo "  ⚠ apps/registry.yaml локальный отличается от бэкапа. Сравните вручную:"
  echo "      diff $REPO_ROOT/apps/registry.yaml $ARCHIVE_ROOT/apps/registry.yaml"
fi

echo ""
echo "Дальше:"
echo "  1) make up ENV=$ENV_NAME      (helmfile apply поверх восстановленных Secret-ов)"
echo "  2) make apps-apply ENV=$ENV_NAME   (пересоздать учётки приложений из apps/conf)"
echo "  3) restore данных сервисов — см. <service>/BACKUP.md"

if [ "$FAILED_FILES" -gt 0 ]; then exit 2; fi
exit 0
