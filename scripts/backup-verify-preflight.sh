#!/usr/bin/env bash
# backup-verify-preflight.sh — hard-checks перед запуском backup-verify.
#
# Цель: остановить пайплайн ДО любого destructive шага (env-restore, *-restore),
# если выявляется хоть один risk: восстановление в prod / в кластер источника,
# отсутствующее тулинг, повреждённые архивы, разъезжающиеся PG major-версии,
# нехватка диска, чужие helm releases на DST и т. п.
#
# Args (env):
#   SRC_ENV          — имя env-источника (e.g. prod). Обязательно.
#   DST_ENV          — имя env-цели    (e.g. local). Обязательно.
#   APP              — имя приложения для verify. Обязательно (для timestamp drift / fingerprint paths).
#   REPO_ROOT        — корень репо. По умолчанию $(pwd).
#   KUBECONFIG       — kubeconfig DST (стандартная Kubernetes env var). Обязательно.
#   YQ               — путь к mikefarah/yq, по умолчанию "yq".
#   APPS_REGISTRY    — путь к apps/registry.yaml; по умолчанию $REPO_ROOT/apps/registry.yaml.
#   BACKUP_AGE_KEY_FILE — путь к age private key (если бэкапы зашифрованы).
#   BACKUP_FILES     — пробелы-разделённый список ожидаемых backup-файлов (env-backup,
#                      postgres-backup, redis-backup, kafka-meta, minio-meta, clickhouse-backup,
#                      rabbitmq-defs). Пути относительно REPO_ROOT. Опционально; если пусто —
#                      пропускаем integrity check (его делает PR2.4 fetch-скрипт).
#   TIMESTAMP_DRIFT_HOURS — допустимый разрыв между timestamp'ами файлов BACKUP_FILES.
#                      По умолчанию 6. Превышение → FAIL.
#   MIN_DISK_FREE_MB — минимум свободного места на admin-машине (REPO_ROOT FS).
#                      По умолчанию 5120 (5 GiB). Если в BACKUP_FILES есть large file,
#                      реальный минимум = max(MIN_DISK_FREE_MB, sum(size)*3).
#   PROD_ENVS        — пробелы-разделённый blocklist для DST_ENV. По умолчанию "prod production".
#   FORCE            — игнорировать non-critical warnings. Critical fails всё равно блокируют.
#
# Stdout: таблица [check / status / detail]. Машино-читаемая копия в $VERIFY_REPORT_DIR/preflight.json
# если задан VERIFY_REPORT_DIR.
#
# Exit:
#   0 — все critical-checks PASS.
#   1 — хотя бы один critical FAIL.

set -uo pipefail

SRC_ENV="${SRC_ENV:-}"
DST_ENV="${DST_ENV:-}"
APP="${APP:-}"
REPO_ROOT="${REPO_ROOT:-$(pwd)}"
KUBECONFIG_FILE="${KUBECONFIG:-}"
YQ_BIN="${YQ:-yq}"
APPS_REGISTRY="${APPS_REGISTRY:-$REPO_ROOT/apps/registry.yaml}"
BACKUP_AGE_KEY_FILE="${BACKUP_AGE_KEY_FILE:-}"
BACKUP_FILES="${BACKUP_FILES:-}"
TIMESTAMP_DRIFT_HOURS="${TIMESTAMP_DRIFT_HOURS:-6}"
MIN_DISK_FREE_MB="${MIN_DISK_FREE_MB:-5120}"
PROD_ENVS="${PROD_ENVS:-prod production}"
FORCE="${FORCE:-0}"
VERIFY_REPORT_DIR="${VERIFY_REPORT_DIR:-}"

err() { echo "$@" >&2; }

# Hard-fail на отсутствие обязательных параметров.
[ -n "$SRC_ENV" ] || { err "✗ SRC_ENV не задан"; exit 1; }
[ -n "$DST_ENV" ] || { err "✗ DST_ENV не задан"; exit 1; }
[ -n "$APP" ]     || { err "✗ APP не задан"; exit 1; }
[ -n "$KUBECONFIG_FILE" ] || { err "✗ KUBECONFIG не задан"; exit 1; }

# Цветной вывод; на не-TTY — без ANSI.
if [ -t 1 ]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'; C_DIM=$'\033[0;90m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_DIM=""; C_OFF=""
fi

# Глобальные счётчики.
FAIL_COUNT=0
WARN_COUNT=0
PASS_COUNT=0
declare -a CHECK_LOG=()  # JSON-fragments для report

# record <name> <status: PASS|FAIL|WARN|SKIP> <detail>
record() {
  local name="$1" status="$2" detail="${3:-}"
  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT+1)); printf "  ${C_GRN}✓${C_OFF}  %-44s %s\n" "$name" "$detail" ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT+1)); printf "  ${C_RED}✗${C_OFF}  %-44s %s\n" "$name" "$detail" ;;
    WARN) WARN_COUNT=$((WARN_COUNT+1)); printf "  ${C_YEL}!${C_OFF}  %-44s %s\n" "$name" "$detail" ;;
    SKIP)                              printf "  ${C_DIM}-  %-44s %s${C_OFF}\n" "$name" "$detail" ;;
  esac
  # JSON-фрагмент для machine-report.
  local esc_detail
  esc_detail=$(printf '%s' "$detail" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '"%s"' "${detail//\"/\\\"}")
  CHECK_LOG+=("{\"check\":\"$name\",\"status\":\"$status\",\"detail\":$esc_detail}")
}

echo ""
echo "=== Pre-flight: SRC_ENV=$SRC_ENV → DST_ENV=$DST_ENV  APP=$APP ==="
echo ""

# -----------------------------------------------------------------------------
# 1. DST_ENV ∉ {prod, production}
# -----------------------------------------------------------------------------
in_prod_blocklist=0
for p in $PROD_ENVS; do
  [ "$DST_ENV" = "$p" ] && in_prod_blocklist=1
done
if [ "$in_prod_blocklist" = "1" ]; then
  record "DST_ENV not in prod blocklist" FAIL "DST_ENV=$DST_ENV входит в PROD_ENVS=\"$PROD_ENVS\""
else
  record "DST_ENV not in prod blocklist" PASS "DST_ENV=$DST_ENV"
fi

# -----------------------------------------------------------------------------
# 2. SRC_ENV != DST_ENV (текст)
# -----------------------------------------------------------------------------
if [ "$SRC_ENV" = "$DST_ENV" ]; then
  record "SRC_ENV != DST_ENV (text)" FAIL "оба = $SRC_ENV"
else
  record "SRC_ENV != DST_ENV (text)" PASS "$SRC_ENV vs $DST_ENV"
fi

# -----------------------------------------------------------------------------
# 3. cluster URL для DST != для SRC
#    SRC_KUBECONFIG берём из $REPO_ROOT/k8s/config/$SRC_ENV (если есть);
#    если нет — WARN (не критично, потому что обычно SRC удалённый и его kubeconfig
#    на admin-машине отсутствует).
# -----------------------------------------------------------------------------
if ! command -v kubectl >/dev/null 2>&1; then
  record "cluster URL src != dst"     FAIL "kubectl не найден"
else
  DST_URL=$(kubectl --kubeconfig "$KUBECONFIG_FILE" config view -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
  SRC_KUBECONFIG="$REPO_ROOT/k8s/config/$SRC_ENV"
  if [ -z "$DST_URL" ]; then
    record "cluster URL src != dst"   FAIL "не удалось прочитать server URL из DST KUBECONFIG=$KUBECONFIG_FILE"
  elif [ -f "$SRC_KUBECONFIG" ]; then
    SRC_URL=$(kubectl --kubeconfig "$SRC_KUBECONFIG" config view -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
    if [ -n "$SRC_URL" ] && [ "$SRC_URL" = "$DST_URL" ]; then
      record "cluster URL src != dst" FAIL "SRC и DST указывают на один кластер: $DST_URL"
    else
      record "cluster URL src != dst" PASS "src=$SRC_URL dst=$DST_URL"
    fi
  else
    record "cluster URL src != dst"   WARN "k8s/config/$SRC_ENV отсутствует — сверка пропущена (DST URL: $DST_URL)"
  fi
fi

# -----------------------------------------------------------------------------
# 4. Tooling: обязательное + специфичное для verify (mc, redis-cli, psql, ch-client, rabbitmqadmin)
# -----------------------------------------------------------------------------
TOOLING_FAIL=0
TOOLING_DETAIL=""
require_tool() {
  local t="$1" opt="${2:-0}"
  if command -v "$t" >/dev/null 2>&1; then
    return 0
  fi
  if [ "$opt" = "1" ]; then
    TOOLING_DETAIL+="${TOOLING_DETAIL:+, }$t(optional)"
  else
    TOOLING_DETAIL+="${TOOLING_DETAIL:+, }$t"
    TOOLING_FAIL=1
  fi
  return 1
}
require_tool kubectl
require_tool helm
require_tool jq
# yq через probe
if ! { [ -x "$YQ_BIN" ] || command -v "$YQ_BIN" >/dev/null 2>&1; }; then
  TOOLING_DETAIL+="${TOOLING_DETAIL:+, }yq(mikefarah/v4)"
  TOOLING_FAIL=1
fi
require_tool tar
require_tool gzip
require_tool openssl
# Опциональные client tools — нужны только если соответствующий сервис активен.
# Здесь делаем мягкий check: если отсутствуют, fingerprint будет ругаться позже.
require_tool mc 1
require_tool psql 1
require_tool redis-cli 1
require_tool clickhouse-client 1
require_tool rabbitmqadmin 1
# age обязателен, если есть зашифрованные backup-файлы.
NEED_AGE=0
if [ -n "$BACKUP_FILES" ]; then
  for f in $BACKUP_FILES; do
    case "$f" in *.age) NEED_AGE=1 ;; esac
  done
fi
if [ "$NEED_AGE" = "1" ]; then
  require_tool age
fi
if [ "$TOOLING_FAIL" = "1" ]; then
  record "tooling check" FAIL "отсутствуют: $TOOLING_DETAIL"
else
  record "tooling check" PASS "${TOOLING_DETAIL:-все есть}"
fi

# -----------------------------------------------------------------------------
# 5. Namespace label infra-env=$DST_ENV
#    Если на одном из ожидаемых namespace стоит infra-env != $DST_ENV → FAIL
#    (на чужой кластер бьём). Если label отсутствует — WARN (используйте
#    `make env-label-backfill ENV=$DST_ENV` перед verify).
# -----------------------------------------------------------------------------
if [ ! -f "$REPO_ROOT/environments/$DST_ENV.yaml" ]; then
  record "namespace infra-env label" WARN "environments/$DST_ENV.yaml отсутствует — сверка пропущена"
else
  PLATFORM_NS=$(awk '/^[A-Za-z0-9_-]+:/{svc=$1} /namespace:/{print $2}' "$REPO_ROOT/environments/$DST_ENV.yaml" | sort -u)
  APP_NS=""
  if [ -f "$APPS_REGISTRY" ]; then
    APP_NS=$("$YQ_BIN" -r '.apps[] | select(.enabled == true) | ((.app_ns | select(. != null and . != "")) // .name)' "$APPS_REGISTRY" 2>/dev/null | sort -u || true)
  fi
  WRONG_NS=()
  MISSING_LABEL_NS=()
  for ns in $PLATFORM_NS $APP_NS; do
    [ -n "$ns" ] || continue
    if ! kubectl --kubeconfig "$KUBECONFIG_FILE" get ns "$ns" >/dev/null 2>&1; then continue; fi
    cur=$(kubectl --kubeconfig "$KUBECONFIG_FILE" get ns "$ns" -o jsonpath='{.metadata.labels.infra-env}' 2>/dev/null || true)
    if [ -z "$cur" ]; then
      MISSING_LABEL_NS+=("$ns")
    elif [ "$cur" != "$DST_ENV" ]; then
      WRONG_NS+=("$ns(=$cur)")
    fi
  done
  if [ ${#WRONG_NS[@]} -gt 0 ]; then
    record "namespace infra-env label" FAIL "ns с чужим infra-env: ${WRONG_NS[*]} — DST_ENV=$DST_ENV не соответствует. Это чужой кластер."
  elif [ ${#MISSING_LABEL_NS[@]} -gt 0 ]; then
    record "namespace infra-env label" WARN "ns без label: ${MISSING_LABEL_NS[*]}. Запустите: make env-label-backfill ENV=$DST_ENV"
  else
    record "namespace infra-env label" PASS "все ns с infra-env=$DST_ENV"
  fi
fi

# -----------------------------------------------------------------------------
# 6. PG major version src == dst
#    SRC: helm release postgres из k8s/config/$SRC_ENV (если доступен).
#    DST: helm release postgres из активного KUBECONFIG.
#    Если DST ещё не развёрнут (нет release) — версия из values-$DST_ENV.yaml.
#    Если SRC kubeconfig нет — WARN.
# -----------------------------------------------------------------------------
get_pg_major_from_helm() {
  local kc="$1"
  local img
  img=$(helm --kubeconfig "$kc" get values postgres -n postgres -o json 2>/dev/null \
    | jq -r '.image.tag // .global.imageRegistry // empty' 2>/dev/null || true)
  if [ -z "$img" ]; then
    img=$(kubectl --kubeconfig "$kc" -n postgres get sts -o jsonpath='{range .items[*]}{.spec.template.spec.containers[*].image}{"\n"}{end}' 2>/dev/null \
      | grep -i postgresql | head -1 || true)
  fi
  # Extract first major version digits before ".".
  echo "$img" | grep -oE '[0-9]+' | head -1
}
get_pg_major_from_values() {
  local env="$1"
  local v="$REPO_ROOT/postgres/values-$env.yaml"
  [ -f "$v" ] || return 0
  "$YQ_BIN" -r '.image.tag // ""' "$v" 2>/dev/null | grep -oE '^[0-9]+' || true
}

DST_PG=$(get_pg_major_from_helm "$KUBECONFIG_FILE")
[ -n "$DST_PG" ] || DST_PG=$(get_pg_major_from_values "$DST_ENV")

SRC_PG=""
if [ -f "$REPO_ROOT/k8s/config/$SRC_ENV" ]; then
  SRC_PG=$(get_pg_major_from_helm "$REPO_ROOT/k8s/config/$SRC_ENV" 2>/dev/null || true)
fi
[ -n "$SRC_PG" ] || SRC_PG=$(get_pg_major_from_values "$SRC_ENV")

if [ -z "$SRC_PG" ] || [ -z "$DST_PG" ]; then
  record "PG major version src==dst" WARN "src=${SRC_PG:-?} dst=${DST_PG:-?} (не удалось определить — verify может упасть на несовместимости)"
elif [ "$SRC_PG" != "$DST_PG" ]; then
  record "PG major version src==dst" FAIL "src=$SRC_PG dst=$DST_PG — pg_dumpall между мажорными версиями ненадёжен"
else
  record "PG major version src==dst" PASS "PG $SRC_PG"
fi

# -----------------------------------------------------------------------------
# 7. Disk free на admin (REPO_ROOT FS). Минимум: max(MIN_DISK_FREE_MB, sum(BACKUP_FILES)*3).
# -----------------------------------------------------------------------------
df_kb=$(df -k "$REPO_ROOT" | awk 'NR==2 {print $4}')
df_mb=$((df_kb / 1024))
need_mb=$MIN_DISK_FREE_MB
if [ -n "$BACKUP_FILES" ]; then
  sum_kb=0
  for f in $BACKUP_FILES; do
    p="$f"
    [ -f "$p" ] || p="$REPO_ROOT/$f"
    if [ -f "$p" ]; then
      s=$(du -k "$p" | awk '{print $1}')
      sum_kb=$((sum_kb + s))
    fi
  done
  sum_mb=$((sum_kb / 1024))
  need_3x=$((sum_mb * 3))
  if [ "$need_3x" -gt "$need_mb" ]; then need_mb=$need_3x; fi
fi
if [ "$df_mb" -lt "$need_mb" ]; then
  record "disk free admin" FAIL "free=${df_mb} MiB < need=${need_mb} MiB (≥ MIN_DISK_FREE_MB=$MIN_DISK_FREE_MB или sum(backups)*3)"
else
  record "disk free admin" PASS "free=${df_mb} MiB (need ≥${need_mb} MiB)"
fi

# -----------------------------------------------------------------------------
# 8. Backup files integrity: gunzip -t для .gz, tar -tzf для .tar.gz,
#    age --decrypt --output=/dev/null для .age (требует BACKUP_AGE_KEY_FILE).
# -----------------------------------------------------------------------------
if [ -z "$BACKUP_FILES" ]; then
  record "backup files integrity" SKIP "BACKUP_FILES не задан"
else
  INTEGRITY_BAD=()
  for f in $BACKUP_FILES; do
    p="$f"
    [ -f "$p" ] || p="$REPO_ROOT/$f"
    if [ ! -f "$p" ]; then
      INTEGRITY_BAD+=("$f:missing"); continue
    fi
    case "$p" in
      *.age)
        if [ -z "$BACKUP_AGE_KEY_FILE" ] || [ ! -f "$BACKUP_AGE_KEY_FILE" ]; then
          INTEGRITY_BAD+=("$f:no-key"); continue
        fi
        if ! age --decrypt -i "$BACKUP_AGE_KEY_FILE" -o /dev/null "$p" 2>/dev/null; then
          INTEGRITY_BAD+=("$f:age-fail"); continue
        fi
        ;;
      *.tar.gz)
        if ! tar -tzf "$p" >/dev/null 2>&1; then
          INTEGRITY_BAD+=("$f:tar-bad"); continue
        fi
        ;;
      *.gz|*.sql.gz|*.json.gz)
        if ! gunzip -t "$p" 2>/dev/null; then
          INTEGRITY_BAD+=("$f:gz-bad"); continue
        fi
        ;;
    esac
  done
  if [ ${#INTEGRITY_BAD[@]} -gt 0 ]; then
    record "backup files integrity" FAIL "повреждены: ${INTEGRITY_BAD[*]}"
  else
    record "backup files integrity" PASS "проверено: $(echo $BACKUP_FILES | wc -w) файл(ов)"
  fi
fi

# -----------------------------------------------------------------------------
# 9. Backup timestamp drift < TIMESTAMP_DRIFT_HOURS
#    Timestamp извлекаем из имени файла: <prefix>-YYYYMMDD-HHMMSS[-PID].<ext>.
#    PID-суффикс (от PR1.6) игнорируется.
# -----------------------------------------------------------------------------
if [ -z "$BACKUP_FILES" ]; then
  record "backup timestamp drift" SKIP "BACKUP_FILES не задан"
else
  declare -a EPOCHS=()
  EXTRACT_FAIL=0
  for f in $BACKUP_FILES; do
    bn=$(basename "$f")
    # Find YYYYMMDD-HHMMSS pattern.
    ts=$(echo "$bn" | grep -oE '[0-9]{8}-[0-9]{6}' | head -1)
    if [ -z "$ts" ]; then EXTRACT_FAIL=1; break; fi
    # Convert to epoch via date -d.
    d=${ts:0:8}; t=${ts:9:6}
    iso="${d:0:4}-${d:4:2}-${d:6:2} ${t:0:2}:${t:2:2}:${t:4:2}"
    e=$(date -d "$iso" +%s 2>/dev/null || true)
    [ -n "$e" ] || { EXTRACT_FAIL=1; break; }
    EPOCHS+=("$e")
  done
  if [ "$EXTRACT_FAIL" = "1" ] || [ ${#EPOCHS[@]} -eq 0 ]; then
    record "backup timestamp drift" WARN "не удалось извлечь timestamp из всех файлов"
  else
    MIN=${EPOCHS[0]}; MAX=${EPOCHS[0]}
    for e in "${EPOCHS[@]}"; do
      [ "$e" -lt "$MIN" ] && MIN=$e
      [ "$e" -gt "$MAX" ] && MAX=$e
    done
    DRIFT=$((MAX - MIN))
    DRIFT_H=$((DRIFT / 3600))
    LIMIT_S=$((TIMESTAMP_DRIFT_HOURS * 3600))
    if [ "$DRIFT" -gt "$LIMIT_S" ]; then
      record "backup timestamp drift" FAIL "разрыв $DRIFT_H h > $TIMESTAMP_DRIFT_HOURS h (TIMESTAMP_DRIFT_HOURS)"
    else
      record "backup timestamp drift" PASS "разрыв ${DRIFT_H}h ≤ $TIMESTAMP_DRIFT_HOURS h"
    fi
  fi
fi

# -----------------------------------------------------------------------------
# 10. apps/conf swap marker.
#     backup-verify требует, чтобы apps/conf/ либо отсутствовал,
#     либо был сохранён в apps/conf.bak-verify-* (это делает orchestrator).
#     На preflight-этапе проверяем, что caller не запустил скрипт «вживую»
#     с активным apps/conf от чужого env.
# -----------------------------------------------------------------------------
if [ ! -d "$REPO_ROOT/apps/conf" ]; then
  record "apps/conf swap status" PASS "apps/conf отсутствует — будет восстановлен из env-backup"
else
  # Если каталог не пуст (не считая _example), это нужно либо сохранить, либо force.
  NON_EXAMPLE=$(find "$REPO_ROOT/apps/conf" -mindepth 1 -maxdepth 1 -type d ! -name '_example' 2>/dev/null | wc -l)
  if [ "$NON_EXAMPLE" -eq 0 ]; then
    record "apps/conf swap status" PASS "apps/conf пуст (только _example)"
  elif [ "$FORCE" = "1" ]; then
    record "apps/conf swap status" WARN "apps/conf содержит $NON_EXAMPLE app(s); FORCE=1 — будут перетёрты через OVERWRITE_APPS_CONF=1"
  else
    record "apps/conf swap status" FAIL "apps/conf содержит $NON_EXAMPLE app(s). Сохраните в apps/conf.bak-verify-TS/ или передайте FORCE=1"
  fi
fi

# -----------------------------------------------------------------------------
# 11. BACKUP_AGE_KEY_FILE existence/readability (только если есть .age файлы).
# -----------------------------------------------------------------------------
if [ "$NEED_AGE" = "1" ]; then
  if [ -z "$BACKUP_AGE_KEY_FILE" ]; then
    record "age key file" FAIL "обнаружены .age бэкапы, но BACKUP_AGE_KEY_FILE не задан"
  elif [ ! -f "$BACKUP_AGE_KEY_FILE" ]; then
    record "age key file" FAIL "BACKUP_AGE_KEY_FILE=$BACKUP_AGE_KEY_FILE не существует"
  elif [ ! -r "$BACKUP_AGE_KEY_FILE" ]; then
    record "age key file" FAIL "BACKUP_AGE_KEY_FILE=$BACKUP_AGE_KEY_FILE не readable"
  else
    record "age key file" PASS "$(basename "$BACKUP_AGE_KEY_FILE") readable"
  fi
else
  record "age key file" SKIP "нет .age бэкапов в BACKUP_FILES"
fi

# -----------------------------------------------------------------------------
# 12. helm list -A на DST: либо пустой, либо все releases в ns с infra-env=$DST_ENV.
# -----------------------------------------------------------------------------
if ! command -v helm >/dev/null 2>&1; then
  record "DST helm releases clean" SKIP "helm не найден"
else
  STRAY=()
  while IFS=$'\t' read -r name ns; do
    [ -z "$name" ] && continue
    [ -z "$ns" ] && continue
    cur=$(kubectl --kubeconfig "$KUBECONFIG_FILE" get ns "$ns" -o jsonpath='{.metadata.labels.infra-env}' 2>/dev/null || true)
    if [ -z "$cur" ] || [ "$cur" != "$DST_ENV" ]; then
      STRAY+=("$ns/$name(=${cur:-<no-label>})")
    fi
  done < <(helm --kubeconfig "$KUBECONFIG_FILE" list -A -o json 2>/dev/null | jq -r '.[] | [.name, .namespace] | @tsv' 2>/dev/null)
  if [ ${#STRAY[@]} -eq 0 ]; then
    record "DST helm releases clean" PASS "нет releases в ns без infra-env=$DST_ENV"
  elif [ "$FORCE" = "1" ]; then
    record "DST helm releases clean" WARN "stray releases (FORCE=1): ${STRAY[*]}"
  else
    record "DST helm releases clean" FAIL "releases в ns без infra-env=$DST_ENV: ${STRAY[*]}"
  fi
fi

# -----------------------------------------------------------------------------
# 13. APP найдено в apps/registry.yaml и enabled.
# -----------------------------------------------------------------------------
if [ ! -f "$APPS_REGISTRY" ]; then
  record "APP in registry" FAIL "$APPS_REGISTRY отсутствует"
else
  app_status=$(APP_NAME="$APP" "$YQ_BIN" -r '.apps[] | select(.name == strenv(APP_NAME)) | .enabled' "$APPS_REGISTRY" 2>/dev/null || true)
  case "$app_status" in
    true)  record "APP in registry" PASS "$APP enabled" ;;
    false) record "APP in registry" FAIL "$APP в реестре но enabled: false" ;;
    "")    record "APP in registry" FAIL "$APP не найден в $APPS_REGISTRY" ;;
    *)     record "APP in registry" FAIL "$APP enabled=$app_status (ожидалось true/false)" ;;
  esac
fi

# -----------------------------------------------------------------------------
# Финальный JSON-отчёт + verdict.
# -----------------------------------------------------------------------------
echo ""
echo "Pre-flight: PASS=$PASS_COUNT  WARN=$WARN_COUNT  FAIL=$FAIL_COUNT"

if [ -n "$VERIFY_REPORT_DIR" ]; then
  mkdir -p "$VERIFY_REPORT_DIR"
  REPORT="$VERIFY_REPORT_DIR/preflight.json"
  {
    printf '{\n'
    printf '  "src_env": "%s",\n' "$SRC_ENV"
    printf '  "dst_env": "%s",\n' "$DST_ENV"
    printf '  "app": "%s",\n' "$APP"
    printf '  "summary": {"pass": %d, "warn": %d, "fail": %d},\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
    printf '  "checks": [\n'
    n=${#CHECK_LOG[@]}; i=0
    for entry in "${CHECK_LOG[@]}"; do
      i=$((i+1))
      if [ "$i" -lt "$n" ]; then printf '    %s,\n' "$entry"; else printf '    %s\n' "$entry"; fi
    done
    printf '  ]\n'
    printf '}\n'
  } > "$REPORT"
  echo "JSON-отчёт: $REPORT"
fi

if [ "$FAIL_COUNT" -gt 0 ]; then exit 1; fi
exit 0
