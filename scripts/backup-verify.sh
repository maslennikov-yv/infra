#!/usr/bin/env bash
# backup-verify.sh — orchestrator полного цикла верификации бэкапа одного APP.
#
# Цель: на DST_ENV (по умолчанию local) прогнать полный disaster-recovery flow
# источника SRC_ENV — env-restore + make up + per-service *-restore + apps-apply +
# doctor — и сравнить structural fingerprint источника и цели. Это даёт жёсткую
# проверку, что бэкапы реально восстановимы и приводят к рабочему APP.
#
# Шаги (каждый логируется в REPORT_DIR/<step>.log; FAIL прерывает пайплайн,
# если STOP_ON_FAIL=1 (по умолчанию)):
#
#   1. preflight        — 13 hard-checks (scripts/backup-verify-preflight.sh).
#   2. fetch            — scp свежих *-backup* + env-backup [+ source-fingerprint]
#                         из SRC_ENV в REPORT_DIR/incoming/.
#   3. workspace-swap   — если apps/conf/ содержит чужие creds, перемещаем в
#                         apps/conf.bak-verify-<TS>/. На EXIT возвращаем.
#   4. clean            — (CLEAN=1) make down ENV=$DST + kubectl delete pvc + wait.
#   5. env-restore      — restored Secrets/CM/apps-conf из env-backup
#                         (OVERWRITE_APPS_CONF=1).
#   6. localize         — patch MINIO_PUBLIC_ENDPOINT (defense from prod-leak).
#   7. up               — make up ENV=$DST SKIP_APPS_APPLY=1
#                         (apps-apply делаем явно после *-restore).
#   8. data-restore     — postgres-restore (PG_ON_ERROR_STOP=1, SKIP_CONFIRM=1),
#                         redis-restore-acl, kafka-restore-meta-topics,
#                         minio-restore-meta, clickhouse-restore, rabbitmq-restore-defs.
#   9. apps-apply       — приведение SCRAM/ACL/IAM к creds из apps/conf.
#  10. doctor           — make doctor + per-app smoke.
#  11. fingerprint-dst  — снять structural fingerprint в DST.
#  12. diff              — сравнить с source fingerprint (если есть).
#  13. summary          — собрать summary.md + summary.json + финальный verdict.
#
# Артефакты: REPORT_DIR=$REPO_ROOT/verify-reports/<TS>-<APP>/
#
# Args (env):
#   SRC_ENV               — env-источник. Обязательно.
#   DST_ENV               — env-цель. Обязательно (по дефолту "local").
#   APP                   — приложение для verify. Обязательно.
#   REPO_ROOT             — корень репо. По умолчанию $(pwd).
#   KUBECONFIG            — kubeconfig DST. Обязательно.
#   STOP_ON_FAIL          — 1 (default) — прервать на первом FAIL; 0 — попытаться все шаги.
#   CLEAN                 — 1 → шаг 4 (helm down + PVC delete). Default 0.
#   CLEAN_AFTER           — 1 → после успешного verify сделать make down ENV=$DST. Default 0.
#   SRC_FINGERPRINT       — путь к source-fingerprint. Если пусто — попытаемся найти в
#                           REPORT_DIR/incoming/ (fetch.sh кладёт его туда).
#   BACKUP_AGE_KEY_FILE   — для расшифровки .age бэкапов и fingerprint.
#   BACKUP_AGE_RECIPIENT  — для шифрования dst-fingerprint и summary.
#   APPS_REGISTRY, YQ     — как в других скриптах.
#   FORCE                 — пропустить non-critical preflight warnings.
#   PROD_ENVS             — blocklist для DST_ENV. По умолчанию "prod production".
#                           Hardcoded guard в начале — orchestrator отказывается работать с
#                           DST_ENV из этого списка независимо от SKIP_STEPS.
#   TIMEOUT_PVC_DELETE    — таймаут ожидания удаления PVC в шаге clean. По умолчанию 180s.
#   REQUIRED_BACKUPS      — comma-separated список label'ов backup'ов, без которых fetch падает.
#                           По умолчанию orchestrator auto-detect'ит из merged config APP.
#   ALLOW_SRC_KUBECONFIG_MISSING — пробрасывается в env-restore. Default 1 (orchestrator
#                           уже сделал DST_ENV guard и preflight cluster URL check).
#   SKIP_STEPS            — comma-separated имена шагов для пропуска (для отладки/resume).
#                           Допустимо: preflight,fetch,workspace-swap,clean,env-restore,
#                                      localize,up,data-restore,apps-apply,doctor,
#                                      fingerprint-dst,diff,summary
#
# Exit:
#   0 — PASS (все critical шаги ok, fingerprint-diff verdict=PASS или нет source-fingerprint).
#   1 — FAIL (хоть один critical шаг упал или fingerprint-diff verdict=FAIL).

set -uo pipefail

SRC_ENV="${SRC_ENV:-}"
DST_ENV="${DST_ENV:-local}"
APP="${APP:-}"
REPO_ROOT="${REPO_ROOT:-$(pwd)}"
KUBECONFIG_FILE="${KUBECONFIG:-}"
STOP_ON_FAIL="${STOP_ON_FAIL:-1}"
CLEAN="${CLEAN:-0}"
CLEAN_AFTER="${CLEAN_AFTER:-0}"
SRC_FINGERPRINT="${SRC_FINGERPRINT:-}"
BACKUP_AGE_KEY_FILE="${BACKUP_AGE_KEY_FILE:-}"
BACKUP_AGE_RECIPIENT="${BACKUP_AGE_RECIPIENT:-}"
APPS_REGISTRY="${APPS_REGISTRY:-$REPO_ROOT/apps/registry.yaml}"
YQ_BIN="${YQ:-yq}"
FORCE="${FORCE:-0}"
TIMEOUT_PVC_DELETE="${TIMEOUT_PVC_DELETE:-180}"
SKIP_STEPS="${SKIP_STEPS:-}"

err() { echo "$@" >&2; }

[ -n "$SRC_ENV" ] || { err "✗ SRC_ENV не задан"; exit 1; }
[ -n "$DST_ENV" ] || { err "✗ DST_ENV не задан"; exit 1; }
[ -n "$APP" ]     || { err "✗ APP не задан"; exit 1; }
[ -n "$KUBECONFIG_FILE" ] || { err "✗ KUBECONFIG не задан"; exit 1; }

# Hardcoded prod guard. preflight (шаг 1) тоже проверяет, но он может быть отключён
# через SKIP_STEPS — в этом случае без guard'а здесь весь destructive flow поедет в prod.
# Этот guard НЕ обходится SKIP_STEPS — он перед всеми шагами.
PROD_ENVS_DEFAULT="${PROD_ENVS:-prod production}"
for _p in $PROD_ENVS_DEFAULT; do
  if [ "$DST_ENV" = "$_p" ]; then
    err "✗ backup-verify запрещён для DST_ENV=$DST_ENV (PROD_ENVS=\"$PROD_ENVS_DEFAULT\")"
    err "  Этот пайплайн делает env-restore + helmfile apply + apps-apply в DST — запуск с"
    err "  prod-целью почти всегда ошибка (особенно при опечатке KUBECONFIG)."
    err "  Если нужна верификация бэкапа prod В САМ prod (DR-rehearsal в том же кластере) —"
    err "  это отдельный сценарий, не покрывается backup-verify."
    exit 1
  fi
done
unset _p

# Цвета (только на TTY).
if [ -t 1 ]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'; C_DIM=$'\033[0;90m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_DIM=""; C_BLD=""; C_OFF=""
fi

# -----------------------------------------------------------------------------
# Workspace.
# -----------------------------------------------------------------------------
TS=$(date -u +%Y%m%dT%H%M%SZ)
REPORT_DIR="$REPO_ROOT/verify-reports/${TS}-${APP}"
install -d -m 700 "$REPORT_DIR"
install -d -m 700 "$REPORT_DIR/logs"
INCOMING_DIR="$REPORT_DIR/incoming"

# Сохраняем state шагов для финального отчёта.
declare -A STEP_STATUS=()   # PASS|FAIL|SKIP
declare -A STEP_DETAIL=()
declare -A STEP_DURATION=()
ORDER=(preflight fetch workspace-swap clean env-restore localize up data-restore apps-apply doctor fingerprint-dst diff summary)

skip_requested() {
  case ",$SKIP_STEPS," in
    *",$1,"*) return 0 ;;
    *)        return 1 ;;
  esac
}

# Сохранённые swap'ы для cleanup.
APPS_CONF_SWAP=""
# Флаг: env-restore создавал apps/conf «с нуля» (до verify его не было или он был пустой).
# Только в этом случае cleanup изолирует apps/conf в apps/conf.from-verify-<TS>
# (D3-фикс). Если workspace-swap был SKIP_STEP'нут, мы НЕ знаем что было до verify
# и НЕ трогаем активный apps/conf — иначе уносим легитимные creds юзера.
APPS_CONF_CREATED_BY_VERIFY=0

# -----------------------------------------------------------------------------
# Cleanup-обработчик: всегда восстанавливаем apps/conf swap и (опционально) DST.
# -----------------------------------------------------------------------------
cleanup() {
  local rc=$?
  # Восстановление swap'нутого apps/conf — explicit error handling: silent || true
  # маскировал бы критичные mv-failures и приводил бы к `mv X Y/` (move INTO directory)
  # при существующем destination → silent workspace corruption.
  if [ -n "$APPS_CONF_SWAP" ] && [ -d "$APPS_CONF_SWAP" ]; then
    if [ -d "$REPO_ROOT/apps/conf" ]; then
      local restored_swap="$REPO_ROOT/apps/conf.restored-${TS}"
      if mv "$REPO_ROOT/apps/conf" "$restored_swap"; then
        echo "  ↺ восстановленный apps/conf сохранён: $restored_swap"
      else
        err "  ✗ cleanup: не удалось переместить apps/conf в $restored_swap."
        err "    Ручной откат: rm -rf $REPO_ROOT/apps/conf && mv $APPS_CONF_SWAP $REPO_ROOT/apps/conf"
        echo "Отчёт: $REPORT_DIR/"
        exit "$rc"
      fi
    fi
    if mv "$APPS_CONF_SWAP" "$REPO_ROOT/apps/conf"; then
      echo "  ↺ apps/conf swap восстановлен: $APPS_CONF_SWAP → apps/conf"
    else
      err "  ✗ cleanup: не удалось вернуть swap $APPS_CONF_SWAP → apps/conf."
      err "    Ручной откат: mv $APPS_CONF_SWAP $REPO_ROOT/apps/conf"
      echo "Отчёт: $REPORT_DIR/"
      exit "$rc"
    fi
  elif [ "$APPS_CONF_CREATED_BY_VERIFY" = "1" ] && [ -d "$REPO_ROOT/apps/conf" ]; then
    # apps/conf не существовал до verify (или был пустой), env-restore создал его
    # с prod-creds. Изолируем, чтобы не оставлять prod-creds в активном apps/conf.
    # Триггерится только если workspace-swap БЫЛ выполнен и зафиксировал отсутствие
    # apps/conf до verify (флаг APPS_CONF_CREATED_BY_VERIFY=1). Если step был SKIP'нут,
    # мы не знаем initial state и НЕ трогаем.
    local out_swap="$REPO_ROOT/apps/conf.from-verify-${TS}"
    if mv "$REPO_ROOT/apps/conf" "$out_swap" 2>/dev/null; then
      install -d -m 700 "$REPO_ROOT/apps/conf"
      echo "  ↺ prod-creds из verify изолированы: $out_swap"
      echo "    (apps/conf теперь пустой; перенесите content вручную если нужно)"
    fi
  fi
  # CLEAN_AFTER только при rc=0.
  if [ "$rc" = "0" ] && [ "$CLEAN_AFTER" = "1" ]; then
    echo ""
    echo "${C_DIM}=== CLEAN_AFTER=1: make down ENV=$DST_ENV ===${C_OFF}"
    make -C "$REPO_ROOT" down ENV="$DST_ENV" KUBECONFIG="$KUBECONFIG_FILE" 2>&1 \
      | tee "$REPORT_DIR/logs/cleanup-down.log" >/dev/null || true
  fi
  echo ""
  echo "Отчёт: ${C_BLD}$REPORT_DIR/${C_OFF}"
  exit "$rc"
}
trap cleanup EXIT INT TERM

# -----------------------------------------------------------------------------
# Helpers.
# -----------------------------------------------------------------------------
# step <name> <human label> <command...>
# Запускает command, направляет stdout+stderr в $REPORT_DIR/logs/<name>.log,
# обновляет STEP_STATUS/STEP_DETAIL/STEP_DURATION. При FAIL и STOP_ON_FAIL=1 — exit 1.
step() {
  local name="$1" label="$2"; shift 2
  if skip_requested "$name"; then
    STEP_STATUS[$name]="SKIP"; STEP_DETAIL[$name]="SKIP_STEPS=$SKIP_STEPS"
    printf "\n${C_DIM}── %-16s %s   (skipped via SKIP_STEPS)${C_OFF}\n" "$name" "$label"
    return 0
  fi
  printf "\n${C_BLD}── %-16s %s${C_OFF}\n" "$name" "$label"
  local log="$REPORT_DIR/logs/${name}.log"
  local t0 t1
  t0=$(date +%s)
  if "$@" >"$log" 2>&1; then
    t1=$(date +%s)
    STEP_STATUS[$name]="PASS"
    STEP_DURATION[$name]=$((t1 - t0))
    STEP_DETAIL[$name]="ok (${STEP_DURATION[$name]}s, log: $log)"
    printf "  ${C_GRN}✓ %s${C_OFF}\n" "${STEP_DETAIL[$name]}"
    return 0
  else
    t1=$(date +%s)
    STEP_STATUS[$name]="FAIL"
    STEP_DURATION[$name]=$((t1 - t0))
    STEP_DETAIL[$name]="FAIL (${STEP_DURATION[$name]}s, log: $log)"
    printf "  ${C_RED}✗ %s${C_OFF}\n" "${STEP_DETAIL[$name]}"
    if [ "$STOP_ON_FAIL" = "1" ]; then
      # Покажем хвост лога, чтобы было ясно почему.
      err ""
      err "${C_DIM}--- последние 20 строк $log ---${C_OFF}"
      tail -n 20 "$log" >&2 || true
      exit 1
    fi
    return 1
  fi
}

# Найти свежий файл по glob внутри INCOMING_DIR.
find_in_incoming() {
  local glob="$1"
  ls -1t "$INCOMING_DIR"/$glob 2>/dev/null | head -1
}

echo "${C_BLD}=== backup-verify  ${SRC_ENV} → ${DST_ENV}   APP=${APP} ===${C_OFF}"
echo "${C_DIM}Report:   $REPORT_DIR${C_OFF}"
echo "${C_DIM}TS:       $TS${C_OFF}"
echo "${C_DIM}CLEAN=$CLEAN  CLEAN_AFTER=$CLEAN_AFTER  STOP_ON_FAIL=$STOP_ON_FAIL${C_OFF}"

# -----------------------------------------------------------------------------
# Detect REQUIRED_BACKUPS auto: env-backup всегда + по одному сервису на каждый
# не-пустой <svc>.password (для minio: minio.secret_key) в merged config APP.
# Без этого fetch требует все 6 backups, даже если APP не использует ClickHouse/RabbitMQ.
# Передаётся в fetch через env REQUIRED_BACKUPS=label1,label2,...
# Лейблы соответствуют тем, что в ARTIFACTS в backup-verify-fetch.sh.
# -----------------------------------------------------------------------------
APPS_MERGED_FILE_FOR_DETECT=$(mktemp)
trap_old_exit=$(trap -p EXIT | grep -oP "(?<=-- ').*(?=' EXIT)" || true)
# Не перетираем существующий trap EXIT (cleanup) — добавляем явный rm в нём ниже.
if "$REPO_ROOT/scripts/apps-merge-config.sh" "$APPS_REGISTRY" "$REPO_ROOT" >"$APPS_MERGED_FILE_FOR_DETECT" 2>/dev/null; then
  REQUIRED_BACKUPS="env-backup"
  for _svc in postgres redis kafka minio clickhouse rabbitmq; do
    case "$_svc" in
      minio) _field="minio.secret_key" ;;
      *)     _field="$_svc.password" ;;
    esac
    _v=$("$REPO_ROOT/scripts/app-config-get.sh" "$APPS_MERGED_FILE_FOR_DETECT" "$APP" "$_field" 2>/dev/null || true)
    if [ -n "$_v" ] && [ "$_v" != "null" ]; then
      REQUIRED_BACKUPS="$REQUIRED_BACKUPS,$_svc"
    fi
  done
  unset _svc _field _v
  echo "${C_DIM}Required: $REQUIRED_BACKUPS${C_OFF}"
else
  REQUIRED_BACKUPS=""
  echo "${C_DIM}Required: <auto-detect failed, fetch потребует все стандартные бэкапы>${C_OFF}"
fi
rm -f "$APPS_MERGED_FILE_FOR_DETECT"
export REQUIRED_BACKUPS

# =============================================================================
# 1. preflight (БЕЗ BACKUP_FILES; их integrity проверит шаг 2 fetch).
# =============================================================================
step preflight "Pre-flight (13 hard-checks)" \
  env \
    SRC_ENV="$SRC_ENV" DST_ENV="$DST_ENV" APP="$APP" \
    REPO_ROOT="$REPO_ROOT" KUBECONFIG="$KUBECONFIG_FILE" YQ="$YQ_BIN" \
    APPS_REGISTRY="$APPS_REGISTRY" \
    BACKUP_AGE_KEY_FILE="$BACKUP_AGE_KEY_FILE" \
    BACKUP_FILES="" \
    FORCE="$FORCE" \
    VERIFY_REPORT_DIR="$REPORT_DIR" \
    "$REPO_ROOT/scripts/backup-verify-preflight.sh"

# =============================================================================
# 2. fetch.
# =============================================================================
step fetch "Fetch backups SRC → admin" \
  env \
    SRC_ENV="$SRC_ENV" APP="$APP" \
    REPO_ROOT="$REPO_ROOT" \
    TARGET_DIR="$INCOMING_DIR" \
    INCLUDE_FINGERPRINT="1" \
    BACKUP_AGE_KEY_FILE="$BACKUP_AGE_KEY_FILE" \
    "$REPO_ROOT/scripts/backup-verify-fetch.sh"

# Восстанавливаем BACKUP_FILES из fetch-лога.
BACKUP_FILES=""
if [ -f "$REPORT_DIR/logs/fetch.log" ]; then
  BACKUP_FILES=$(grep '^BACKUP_FILES=' "$REPORT_DIR/logs/fetch.log" | tail -1 | sed 's/^BACKUP_FILES="\(.*\)"$/\1/')
fi

# Source fingerprint: либо передан, либо ищем в incoming/ свежий .json (или .age).
if [ -z "$SRC_FINGERPRINT" ]; then
  SRC_FINGERPRINT=$(find_in_incoming "fingerprint-source-${SRC_ENV}-*.json.age" || true)
  [ -n "$SRC_FINGERPRINT" ] || SRC_FINGERPRINT=$(find_in_incoming "fingerprint-source-${SRC_ENV}-*.json" || true)
fi

# =============================================================================
# 3. workspace-swap apps/conf.
# =============================================================================
APPS_CONF_DIR="$REPO_ROOT/apps/conf"
if skip_requested workspace-swap; then
  STEP_STATUS[workspace-swap]="SKIP"
  printf "\n${C_DIM}── %-16s %s   (skipped via SKIP_STEPS)${C_OFF}\n" "workspace-swap" "apps/conf swap"
else
  printf "\n${C_BLD}── %-16s %s${C_OFF}\n" "workspace-swap" "apps/conf swap"
  if [ -d "$APPS_CONF_DIR" ]; then
    non_example=$(find "$APPS_CONF_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '_example' 2>/dev/null | wc -l)
    if [ "$non_example" -gt 0 ]; then
      APPS_CONF_SWAP="$REPO_ROOT/apps/conf.bak-verify-${TS}"
      mv "$APPS_CONF_DIR" "$APPS_CONF_SWAP"
      install -d -m 700 "$APPS_CONF_DIR"
      # Восстанавливаем _example, если он был — чтобы apps-merge-config не выпал.
      if [ -d "$APPS_CONF_SWAP/_example" ]; then
        cp -rp "$APPS_CONF_SWAP/_example" "$APPS_CONF_DIR/_example"
      fi
      STEP_STATUS[workspace-swap]="PASS"
      STEP_DETAIL[workspace-swap]="$non_example app(s) сдвинуто в $APPS_CONF_SWAP"
      printf "  ${C_GRN}✓ %s${C_OFF}\n" "${STEP_DETAIL[workspace-swap]}"
    else
      # apps/conf был пуст (только _example) — swap не нужен, но env-restore
      # положит туда prod-creds. Отметим что cleanup должен их изолировать.
      APPS_CONF_CREATED_BY_VERIFY=1
      STEP_STATUS[workspace-swap]="PASS"
      STEP_DETAIL[workspace-swap]="apps/conf пуст — swap не нужен, cleanup изолирует prod-creds"
      printf "  ${C_GRN}✓ %s${C_OFF}\n" "${STEP_DETAIL[workspace-swap]}"
    fi
  else
    # apps/conf отсутствовал — env-restore создаст с prod-creds, cleanup изолирует.
    APPS_CONF_CREATED_BY_VERIFY=1
    STEP_STATUS[workspace-swap]="PASS"
    STEP_DETAIL[workspace-swap]="apps/conf отсутствует — будет создан env-restore, cleanup изолирует"
    printf "  ${C_GRN}✓ %s${C_OFF}\n" "${STEP_DETAIL[workspace-swap]}"
  fi
fi

# =============================================================================
# 4. clean (опционально, только если CLEAN=1).
#    make down + delete PVCs с label managed-by=Helm в platform-namespaces.
#    Wait до удаления PVC.
# =============================================================================
clean_dst() {
  set -e
  echo "==== make down ENV=$DST_ENV ===="
  make -C "$REPO_ROOT" down ENV="$DST_ENV" KUBECONFIG="$KUBECONFIG_FILE"
  echo ""
  echo "==== delete PVCs (managed-by=Helm в platform namespaces) ===="
  for ns in postgres redis kafka minio clickhouse rabbitmq monitoring; do
    kubectl --kubeconfig "$KUBECONFIG_FILE" -n "$ns" delete pvc \
      -l app.kubernetes.io/managed-by=Helm --ignore-not-found --wait=false 2>&1 || true
  done
  echo ""
  echo "==== wait for PVCs to disappear (timeout ${TIMEOUT_PVC_DELETE}s) ===="
  local deadline=$(( $(date +%s) + TIMEOUT_PVC_DELETE ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    remaining=0
    for ns in postgres redis kafka minio clickhouse rabbitmq monitoring; do
      n=$(kubectl --kubeconfig "$KUBECONFIG_FILE" -n "$ns" get pvc -l app.kubernetes.io/managed-by=Helm --no-headers 2>/dev/null | wc -l)
      remaining=$((remaining + n))
    done
    if [ "$remaining" = "0" ]; then echo "✓ все PVC удалены"; return 0; fi
    sleep 5
    echo "  PVC остаётся: $remaining (жду ещё $((deadline - $(date +%s)))s)"
  done
  echo "✗ PVC не удалились за $TIMEOUT_PVC_DELETE сек"
  return 1
}

if [ "$CLEAN" = "1" ]; then
  # ВАЖНО: clean_dst использует $REPO_ROOT/$DST_ENV/$KUBECONFIG_FILE/$TIMEOUT_PVC_DELETE из
  # этого shell. Раньше тут было `bash -c "$(declare -f clean_dst); clean_dst"` — новый bash
  # стартовал БЕЗ env-проброса родительских переменных, и под `set -u` в clean_dst
  # обращение к $REPO_ROOT крашило шаг. Теперь вызываем функцию напрямую — она работает
  # в текущем shell, переменные доступны как обычно.
  step clean "DST clean (helm down + PVC delete + wait)" clean_dst
else
  STEP_STATUS[clean]="SKIP"
  STEP_DETAIL[clean]="CLEAN=0 (передайте CLEAN=1 если нужен wipe DST)"
  printf "\n${C_DIM}── %-16s %s   (CLEAN=0)${C_OFF}\n" "clean" "DST clean"
fi

# =============================================================================
# 5. env-restore (всегда с OVERWRITE_APPS_CONF=1 — apps/conf был перенесён swap'ом).
# =============================================================================
if skip_requested env-restore; then
  STEP_STATUS[env-restore]="SKIP"; STEP_DETAIL[env-restore]="SKIP_STEPS=$SKIP_STEPS"
  printf "\n${C_DIM}── %-16s %s   (skipped via SKIP_STEPS)${C_OFF}\n" "env-restore" "env-restore"
else
  ENV_BACKUP_FILE=$(find_in_incoming "${SRC_ENV}-*.tar.gz.age" || true)
  [ -n "$ENV_BACKUP_FILE" ] || ENV_BACKUP_FILE=$(find_in_incoming "${SRC_ENV}-*.tar.gz" || true)
  if [ -z "$ENV_BACKUP_FILE" ]; then
    STEP_STATUS[env-restore]="FAIL"
    STEP_DETAIL[env-restore]="env-backup не найден в $INCOMING_DIR"
    printf "\n${C_RED}✗ env-restore: %s${C_OFF}\n" "${STEP_DETAIL[env-restore]}"
    [ "$STOP_ON_FAIL" = "1" ] && exit 1
  else
    # ALLOW_SRC_KUBECONFIG_MISSING=1 — типичная ситуация в backup-verify: на admin машине
    # нет prod kubeconfig (security). orchestrator уже сделал собственный hardcoded
    # DST_ENV ∈ PROD_ENVS guard (стр. ~80) + preflight cluster URL check (шаг 1),
    # дублирующая проверка через k8s/config/$SRC_ENV нам не нужна.
    step env-restore "env-restore $(basename "$ENV_BACKUP_FILE")" \
      make -C "$REPO_ROOT" env-restore \
        BACKUP_FILE="$ENV_BACKUP_FILE" ENV="$DST_ENV" \
        KUBECONFIG="$KUBECONFIG_FILE" \
        CONFIRM=1 OVERWRITE_APPS_CONF=1 \
        ALLOW_SRC_KUBECONFIG_MISSING=1 \
        BACKUP_AGE_KEY_FILE="$BACKUP_AGE_KEY_FILE"
  fi
fi

# =============================================================================
# 6. localize: подменить MINIO_PUBLIC_ENDPOINT на in-cluster URL DST.
#    ВНИМАНИЕ: запускаем ДО make up, чтобы pod'ы стартовали уже с локальными
#    значениями (Secret монтируется в env приложения).
# =============================================================================
step localize "Localize MINIO_PUBLIC_ENDPOINT" \
  env \
    DST_ENV="$DST_ENV" APP="$APP" \
    REPO_ROOT="$REPO_ROOT" KUBECONFIG="$KUBECONFIG_FILE" YQ="$YQ_BIN" \
    APPS_REGISTRY="$APPS_REGISTRY" \
    "$REPO_ROOT/scripts/backup-verify-localize.sh"

# =============================================================================
# 7. up (SKIP_APPS_APPLY=1 — apps-apply делаем после *-restore).
# =============================================================================
step up "make up ENV=$DST_ENV SKIP_APPS_APPLY=1" \
  make -C "$REPO_ROOT" up ENV="$DST_ENV" KUBECONFIG="$KUBECONFIG_FILE" SKIP_APPS_APPLY=1

# =============================================================================
# 8. data-restore: per-service. Failure НЕ останавливает остальные —
#    собираем общую картину, вердикт по step.
# =============================================================================
data_restore() {
  set -uo pipefail
  local sub_fail=0
  declare -a steps=()
  # Постгрес: пользуемся PR1.1 — PG_ON_ERROR_STOP=1 + SKIP_CONFIRM=1.
  pg=$(ls -1t "$INCOMING_DIR"/postgres-backup-*.sql.gz{.age,} 2>/dev/null | head -1)
  if [ -n "${pg:-}" ]; then
    echo "==== postgres-restore $pg ===="
    if make -C "$REPO_ROOT" postgres-restore \
        ENV="$DST_ENV" KUBECONFIG="$KUBECONFIG_FILE" \
        BACKUP_FILE="$pg" \
        SKIP_CONFIRM=1 PG_ON_ERROR_STOP=1 \
        BACKUP_AGE_KEY_FILE="$BACKUP_AGE_KEY_FILE"; then
      echo "✓ postgres-restore ok"; steps+=("postgres:ok")
    else
      echo "✗ postgres-restore FAIL"; steps+=("postgres:fail"); sub_fail=$((sub_fail+1))
    fi
  else
    echo "↷ postgres-backup-* отсутствует в incoming"; steps+=("postgres:absent")
  fi
  # Redis.
  rd=$(ls -1t "$INCOMING_DIR"/redis-backup-*.tar.gz{.age,} 2>/dev/null | head -1)
  if [ -n "${rd:-}" ]; then
    echo "==== redis-restore-acl $rd ===="
    if make -C "$REPO_ROOT" redis-restore-acl \
        ENV="$DST_ENV" KUBECONFIG="$KUBECONFIG_FILE" \
        BACKUP_FILE="$rd" BACKUP_AGE_KEY_FILE="$BACKUP_AGE_KEY_FILE"; then
      echo "✓ redis-restore-acl ok"; steps+=("redis:ok")
    else
      echo "✗ redis-restore-acl FAIL"; steps+=("redis:fail"); sub_fail=$((sub_fail+1))
    fi
  else
    echo "↷ redis-backup-* отсутствует"; steps+=("redis:absent")
  fi
  # Kafka.
  kf=$(ls -1t "$INCOMING_DIR"/kafka-meta-*.tar.gz{.age,} 2>/dev/null | head -1)
  if [ -n "${kf:-}" ]; then
    echo "==== kafka-restore-meta-topics $kf ===="
    if make -C "$REPO_ROOT" kafka-restore-meta-topics \
        ENV="$DST_ENV" KUBECONFIG="$KUBECONFIG_FILE" \
        BACKUP_FILE="$kf" SKIP_CONFIRM=1 BACKUP_AGE_KEY_FILE="$BACKUP_AGE_KEY_FILE"; then
      echo "✓ kafka-restore-meta-topics ok"; steps+=("kafka:ok")
    else
      echo "✗ kafka-restore-meta-topics FAIL"; steps+=("kafka:fail"); sub_fail=$((sub_fail+1))
    fi
  else
    echo "↷ kafka-meta-* отсутствует"; steps+=("kafka:absent")
  fi
  # MinIO.
  mn=$(ls -1t "$INCOMING_DIR"/minio-meta-*.tar.gz{.age,} 2>/dev/null | head -1)
  if [ -n "${mn:-}" ]; then
    echo "==== minio-restore-meta $mn ===="
    if make -C "$REPO_ROOT" minio-restore-meta \
        ENV="$DST_ENV" KUBECONFIG="$KUBECONFIG_FILE" \
        BACKUP_FILE="$mn" SKIP_CONFIRM=1 BACKUP_AGE_KEY_FILE="$BACKUP_AGE_KEY_FILE"; then
      echo "✓ minio-restore-meta ok"; steps+=("minio:ok")
    else
      echo "✗ minio-restore-meta FAIL"; steps+=("minio:fail"); sub_fail=$((sub_fail+1))
    fi
  else
    echo "↷ minio-meta-* отсутствует"; steps+=("minio:absent")
  fi
  # ClickHouse.
  ch=$(ls -1t "$INCOMING_DIR"/clickhouse-backup-*.tar.gz{.age,} 2>/dev/null | head -1)
  if [ -n "${ch:-}" ]; then
    echo "==== clickhouse-restore $ch ===="
    if make -C "$REPO_ROOT" clickhouse-restore \
        ENV="$DST_ENV" KUBECONFIG="$KUBECONFIG_FILE" \
        BACKUP_FILE="$ch" SKIP_CONFIRM=1 BACKUP_AGE_KEY_FILE="$BACKUP_AGE_KEY_FILE"; then
      echo "✓ clickhouse-restore ok"; steps+=("clickhouse:ok")
    else
      echo "✗ clickhouse-restore FAIL"; steps+=("clickhouse:fail"); sub_fail=$((sub_fail+1))
    fi
  else
    echo "↷ clickhouse-backup-* отсутствует"; steps+=("clickhouse:absent")
  fi
  # RabbitMQ.
  rmq=$(ls -1t "$INCOMING_DIR"/rabbitmq-defs-*.json.gz{.age,} 2>/dev/null | head -1)
  if [ -n "${rmq:-}" ]; then
    echo "==== rabbitmq-restore-defs $rmq ===="
    if make -C "$REPO_ROOT" rabbitmq-restore-defs \
        ENV="$DST_ENV" KUBECONFIG="$KUBECONFIG_FILE" \
        BACKUP_FILE="$rmq" SKIP_CONFIRM=1 BACKUP_AGE_KEY_FILE="$BACKUP_AGE_KEY_FILE"; then
      echo "✓ rabbitmq-restore-defs ok"; steps+=("rabbitmq:ok")
    else
      echo "✗ rabbitmq-restore-defs FAIL"; steps+=("rabbitmq:fail"); sub_fail=$((sub_fail+1))
    fi
  else
    echo "↷ rabbitmq-defs-* отсутствует"; steps+=("rabbitmq:absent")
  fi
  echo ""
  echo "summary: ${steps[*]}"
  return "$sub_fail"
}

# Аналогично clean_dst: вызов через bash -c "$(declare -f ...)" терял env, теперь напрямую.
step data-restore "Per-service data restore" data_restore

# =============================================================================
# 9. apps-apply.
# =============================================================================
step apps-apply "make apps-apply ENV=$DST_ENV (создание SCRAM/ACL/IAM)" \
  env \
    APPS_REGISTRY="$APPS_REGISTRY" REPO_ROOT="$REPO_ROOT" \
    ENV="$DST_ENV" KUBECONFIG="$KUBECONFIG_FILE" \
    YQ="$YQ_BIN" \
    "$REPO_ROOT/scripts/apps-apply.sh"

# =============================================================================
# 10. doctor.
# =============================================================================
step doctor "make doctor ENV=$DST_ENV" \
  make -C "$REPO_ROOT" doctor ENV="$DST_ENV" KUBECONFIG="$KUBECONFIG_FILE"

# =============================================================================
# 11. fingerprint-dst.
# =============================================================================
DST_FINGERPRINT_OUT="$REPORT_DIR/fingerprint-dst-${DST_ENV}-${TS}.json"
step fingerprint-dst "Снять fingerprint на DST" \
  env \
    APP="$APP" ENV="$DST_ENV" ROLE="dst" \
    REPO_ROOT="$REPO_ROOT" KUBECONFIG="$KUBECONFIG_FILE" YQ="$YQ_BIN" \
    APPS_REGISTRY="$APPS_REGISTRY" \
    OUT_FILE="$DST_FINGERPRINT_OUT" \
    "$REPO_ROOT/scripts/backup-fingerprint.sh"

# Если шифрование включено, fingerprint.sh переименовал в .age.
if [ -f "${DST_FINGERPRINT_OUT}.age" ]; then DST_FINGERPRINT_OUT="${DST_FINGERPRINT_OUT}.age"; fi

# =============================================================================
# 12. diff (если есть source-fingerprint).
# =============================================================================
if [ -n "$SRC_FINGERPRINT" ] && [ -f "$SRC_FINGERPRINT" ]; then
  step diff "Сравнение fingerprint source vs dst" \
    env \
      SRC_FINGERPRINT="$SRC_FINGERPRINT" DST_FINGERPRINT="$DST_FINGERPRINT_OUT" \
      REPO_ROOT="$REPO_ROOT" \
      BACKUP_AGE_KEY_FILE="$BACKUP_AGE_KEY_FILE" \
      OUT_REPORT_MD="$REPORT_DIR/diff.md" \
      OUT_DIFF_JSON="$REPORT_DIR/diff.json" \
      "$REPO_ROOT/scripts/backup-fingerprint-diff.sh"
else
  STEP_STATUS[diff]="SKIP"
  STEP_DETAIL[diff]="source-fingerprint не найден (передайте SRC_FINGERPRINT=...). DST-fingerprint сохранён в $DST_FINGERPRINT_OUT — diff можно сделать вручную позже."
  printf "\n${C_YEL}!  diff: %s${C_OFF}\n" "${STEP_DETAIL[diff]}"
fi

# =============================================================================
# 13. summary.
# =============================================================================
SUMMARY_MD="$REPORT_DIR/summary.md"
SUMMARY_JSON="$REPORT_DIR/summary.json"

# Финальный verdict.
CRITICAL_FAIL=0
WARN=0
for step_name in preflight fetch workspace-swap env-restore localize up data-restore apps-apply doctor fingerprint-dst diff; do
  case "${STEP_STATUS[$step_name]:-}" in
    FAIL) CRITICAL_FAIL=$((CRITICAL_FAIL+1)) ;;
    WARN) WARN=$((WARN+1)) ;;
  esac
done
# Также читаем verdict из diff.json (если был).
DIFF_VERDICT=""
if [ -f "$REPORT_DIR/diff.json" ]; then
  DIFF_VERDICT=$(jq -r '.summary.verdict // ""' "$REPORT_DIR/diff.json" 2>/dev/null || true)
  if [ "$DIFF_VERDICT" = "FAIL" ]; then CRITICAL_FAIL=$((CRITICAL_FAIL+1)); fi
fi
if [ "$CRITICAL_FAIL" -gt 0 ]; then VERDICT="FAIL"; else VERDICT="PASS"; fi

# Помечаем summary как in-progress ДО генерации файлов, чтобы он отображался в самой
# таблице со статусом, а не "—".
STEP_STATUS[summary]="PASS"
STEP_DETAIL[summary]="генерируется"

# Markdown summary.
{
  echo "# backup-verify summary"
  echo ""
  echo "- **APP**: \`$APP\`"
  echo "- **SRC_ENV**: \`$SRC_ENV\`"
  echo "- **DST_ENV**: \`$DST_ENV\`"
  echo "- **TS**: \`$TS\`"
  echo "- **CLEAN**: \`$CLEAN\` (CLEAN_AFTER=\`$CLEAN_AFTER\`)"
  echo "- **Verdict**: **$VERDICT** (critical fails=$CRITICAL_FAIL, warns=$WARN)"
  if [ -n "$DIFF_VERDICT" ]; then echo "- **Fingerprint diff**: \`$DIFF_VERDICT\`"; fi
  echo ""
  echo "## Steps"
  echo ""
  echo "| # | step | status | detail |"
  echo "|---:|---|---|---|"
  local_i=0
  for step_name in "${ORDER[@]}"; do
    local_i=$((local_i+1))
    s="${STEP_STATUS[$step_name]:-}"
    d="${STEP_DETAIL[$step_name]:-}"
    d_san=$(printf '%s' "$d" | tr '|' '/' | tr -d '\n')
    echo "| $local_i | $step_name | ${s:-—} | $d_san |"
  done
  echo ""
  echo "## Artifacts"
  echo ""
  for f in "$REPORT_DIR"/*.json "$REPORT_DIR"/*.md; do
    [ -f "$f" ] || continue
    echo "- \`$(basename "$f")\` ($(du -h "$f" | awk '{print $1}'))"
  done
  echo ""
  if [ -d "$INCOMING_DIR" ]; then
    echo "### incoming/"
    ls -lh "$INCOMING_DIR" 2>/dev/null | tail -n +2 | awk '{print "- `" $9 "` (" $5 ")"}'
  fi
  echo ""
  echo "## Logs"
  echo ""
  for f in "$REPORT_DIR/logs"/*.log; do
    [ -f "$f" ] || continue
    echo "- \`logs/$(basename "$f")\` ($(du -h "$f" | awk '{print $1}'))"
  done
} > "$SUMMARY_MD"

# JSON summary.
{
  printf '{\n'
  printf '  "app": %s,\n' "$(jq -Rn --arg s "$APP" '$s')"
  printf '  "src_env": %s,\n' "$(jq -Rn --arg s "$SRC_ENV" '$s')"
  printf '  "dst_env": %s,\n' "$(jq -Rn --arg s "$DST_ENV" '$s')"
  printf '  "timestamp": %s,\n' "$(jq -Rn --arg s "$TS" '$s')"
  printf '  "verdict": %s,\n' "$(jq -Rn --arg s "$VERDICT" '$s')"
  printf '  "diff_verdict": %s,\n' "$(jq -Rn --arg s "$DIFF_VERDICT" '$s')"
  printf '  "steps": {\n'
  first=1
  for step_name in "${ORDER[@]}"; do
    [ "$first" = "1" ] && first=0 || printf ',\n'
    printf '    "%s": {"status": %s, "detail": %s, "duration_s": %s}' \
      "$step_name" \
      "$(jq -Rn --arg s "${STEP_STATUS[$step_name]:-}" '$s')" \
      "$(jq -Rn --arg s "${STEP_DETAIL[$step_name]:-}" '$s')" \
      "${STEP_DURATION[$step_name]:-0}"
  done
  printf '\n  }\n'
  printf '}\n'
} > "$SUMMARY_JSON"

# Опциональное шифрование summary.
if [ -n "$BACKUP_AGE_RECIPIENT" ] && command -v age >/dev/null 2>&1; then
  for f in "$SUMMARY_MD" "$SUMMARY_JSON" "$REPORT_DIR/diff.md" "$REPORT_DIR/diff.json"; do
    [ -f "$f" ] || continue
    if age -r "$BACKUP_AGE_RECIPIENT" -o "${f}.age" "$f" 2>/dev/null; then
      rm -f "$f"
    fi
  done
fi

STEP_DETAIL[summary]="$SUMMARY_MD"

# -----------------------------------------------------------------------------
# Финальный вывод.
# -----------------------------------------------------------------------------
echo ""
echo "${C_BLD}=== итог: $VERDICT ===${C_OFF}"
echo ""
for step_name in "${ORDER[@]}"; do
  s="${STEP_STATUS[$step_name]:-—}"
  d="${STEP_DURATION[$step_name]:-0}"
  case "$s" in
    PASS) printf "  ${C_GRN}%-5s${C_OFF}  %-16s  %ds\n" "$s" "$step_name" "$d" ;;
    FAIL) printf "  ${C_RED}%-5s${C_OFF}  %-16s  %ds\n" "$s" "$step_name" "$d" ;;
    SKIP) printf "  ${C_DIM}%-5s  %-16s  %ds${C_OFF}\n" "$s" "$step_name" "$d" ;;
    WARN) printf "  ${C_YEL}%-5s${C_OFF}  %-16s  %ds\n" "$s" "$step_name" "$d" ;;
    *)    printf "  %-5s  %-16s  %ds\n" "$s" "$step_name" "$d" ;;
  esac
done
echo ""
echo "Summary:  $SUMMARY_MD"
[ -f "$SUMMARY_JSON" ] && echo "JSON:     $SUMMARY_JSON"
[ -f "$REPORT_DIR/diff.md" ] && echo "Diff:     $REPORT_DIR/diff.md"

if [ "$VERDICT" = "FAIL" ]; then exit 1; fi
exit 0
