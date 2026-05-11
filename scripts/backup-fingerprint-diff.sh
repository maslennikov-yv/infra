#!/usr/bin/env bash
# backup-fingerprint-diff.sh — сравнение source vs dst fingerprint.
#
# PASS/FAIL критерий: structural-блок DST полностью соответствует source.
#   - oba "ok" и structural равны → PASS
#   - oba "skipped" (нет creds для APP) → PASS (приложение не подключено)
#   - один "ok" другой "skipped"/"absent" → FAIL
#   - oba "ok", но structural отличаются → FAIL с per-key diff
#
# Informational-блок диагностирует data-divergence (DBSIZE, count(), offsets,
# bucket_du, queue_depth). Расхождения здесь — WARN, не блокируют PASS:
# для большинства сервисов *-backup-meta не содержит данных, и DST после
# restore будет пустым по дизайну (см. план backup-verify).
#
# Args (env):
#   SRC_FINGERPRINT — путь к source JSON (или .age). Обязательно.
#   DST_FINGERPRINT — путь к dst JSON (или .age). Обязательно.
#   REPO_ROOT       — корень репо. По умолчанию $(pwd).
#   BACKUP_AGE_KEY_FILE — для расшифровки .age, если входы зашифрованы.
#   OUT_REPORT_MD   — путь к human-readable отчёту. По умолчанию рядом с DST_FINGERPRINT/diff.md.
#   OUT_DIFF_JSON   — путь к machine-readable JSON-диффу. По умолчанию рядом с DST/diff.json.
#
# Stdout: краткий per-service статус + итоговый verdict.
#
# Exit:
#   0 — PASS (structural совпадает; informational расхождения возможны).
#   1 — FAIL.

set -uo pipefail

SRC_FINGERPRINT="${SRC_FINGERPRINT:-}"
DST_FINGERPRINT="${DST_FINGERPRINT:-}"
REPO_ROOT="${REPO_ROOT:-$(pwd)}"
BACKUP_AGE_KEY_FILE="${BACKUP_AGE_KEY_FILE:-}"
OUT_REPORT_MD="${OUT_REPORT_MD:-}"
OUT_DIFF_JSON="${OUT_DIFF_JSON:-}"

err() { echo "$@" >&2; }
[ -n "$SRC_FINGERPRINT" ] || { err "✗ SRC_FINGERPRINT не задан"; exit 1; }
[ -n "$DST_FINGERPRINT" ] || { err "✗ DST_FINGERPRINT не задан"; exit 1; }
[ -f "$SRC_FINGERPRINT" ] || { err "✗ файл не найден: $SRC_FINGERPRINT"; exit 1; }
[ -f "$DST_FINGERPRINT" ] || { err "✗ файл не найден: $DST_FINGERPRINT"; exit 1; }
command -v jq >/dev/null 2>&1 || { err "✗ jq не найден"; exit 1; }

# Если на входе .age — используем backup-decrypt.sh (passthrough для plain).
SRC_PLAIN=$(BACKUP_AGE_KEY_FILE="$BACKUP_AGE_KEY_FILE" "$REPO_ROOT/scripts/backup-decrypt.sh" "$SRC_FINGERPRINT") || exit 1
DST_PLAIN=$(BACKUP_AGE_KEY_FILE="$BACKUP_AGE_KEY_FILE" "$REPO_ROOT/scripts/backup-decrypt.sh" "$DST_FINGERPRINT") || exit 1
trap '
  if [ "$SRC_PLAIN" != "$SRC_FINGERPRINT" ]; then rm -f -- "$SRC_PLAIN"; fi
  if [ "$DST_PLAIN" != "$DST_FINGERPRINT" ]; then rm -f -- "$DST_PLAIN"; fi
' EXIT

jq empty "$SRC_PLAIN" 2>/dev/null || { err "✗ $SRC_FINGERPRINT не валидный JSON"; exit 1; }
jq empty "$DST_PLAIN" 2>/dev/null || { err "✗ $DST_FINGERPRINT не валидный JSON"; exit 1; }

APP=$(jq -r '.app // ""' "$SRC_PLAIN")
SRC_ENV=$(jq -r '.env // ""' "$SRC_PLAIN")
DST_ENV=$(jq -r '.env // ""' "$DST_PLAIN")
SRC_TS=$(jq -r '.timestamp // ""' "$SRC_PLAIN")
DST_TS=$(jq -r '.timestamp // ""' "$DST_PLAIN")
APP_DST=$(jq -r '.app // ""' "$DST_PLAIN")

if [ "$APP" != "$APP_DST" ]; then
  err "✗ app в SRC ($APP) ≠ DST ($APP_DST)"; exit 1
fi

# Если пути не заданы — кладём рядом с DST_FINGERPRINT.
DST_DIR=$(dirname "$DST_FINGERPRINT")
[ -n "$OUT_REPORT_MD" ] || OUT_REPORT_MD="$DST_DIR/diff.md"
[ -n "$OUT_DIFF_JSON" ] || OUT_DIFF_JSON="$DST_DIR/diff.json"

# -----------------------------------------------------------------------------
# Per-service сравнение.
# -----------------------------------------------------------------------------
declare -A SVC_STATUS=()   # PASS|FAIL|WARN|SKIP
declare -A SVC_DETAIL=()   # короткое описание
declare -A SVC_STRUCT_DIFF=()      # JSON: что отличается в structural
declare -A SVC_INFO_DIFF=()        # JSON: что отличается в informational

SERVICES=$(jq -r '.services | keys[]' "$SRC_PLAIN" | sort -u)
DST_SERVICES=$(jq -r '.services | keys[]' "$DST_PLAIN" | sort -u)
ALL_SERVICES=$(printf '%s\n%s\n' "$SERVICES" "$DST_SERVICES" | sort -u)

FAIL_COUNT=0; WARN_COUNT=0; PASS_COUNT=0; SKIP_COUNT=0

# diff_obj <jq-path-in-src.json> <jq-path-in-dst.json> <file_src> <file_dst>
# Возвращает JSON-объект {removed_or_changed_keys, added_keys} с per-path значениями
# или null, если объекты эквивалентны (после canonical sort).
diff_obj() {
  local path="$1" fs="$2" fd="$3"
  jq -n --slurpfile s "$fs" --slurpfile d "$fd" --arg p "$path" '
    def at($x; $p):
      ($p | split(".")) as $segs
      | reduce $segs[] as $k ($x[0]; if . == null then null else .[$k] end);
    def canon: if type == "object" then to_entries | sort_by(.key) | from_entries | walk(if type == "object" then to_entries | sort_by(.key) | from_entries else . end) else . end;
    (at($s; $p) | canon) as $src |
    (at($d; $p) | canon) as $dst |
    if $src == $dst then null
    else
      {
        src: $src,
        dst: $dst
      }
    end
  '
}

for svc in $ALL_SERVICES; do
  src_status=$(jq -r --arg s "$svc" '.services[$s].status // "missing"' "$SRC_PLAIN")
  dst_status=$(jq -r --arg s "$svc" '.services[$s].status // "missing"' "$DST_PLAIN")

  # Категории:
  # - oba skipped или oba missing → SKIP (приложение не использует сервис)
  # - oba ok → diff structural strict; informational soft
  # - один ok другой нет → FAIL
  # - один absent другой ok → FAIL
  case "${src_status}/${dst_status}" in
    skipped/skipped | missing/missing | skipped/missing | missing/skipped)
      SVC_STATUS[$svc]="SKIP"
      SVC_DETAIL[$svc]="нет creds в merged для $svc (src=$src_status,dst=$dst_status)"
      SKIP_COUNT=$((SKIP_COUNT+1))
      ;;
    error/* | */error)
      SVC_STATUS[$svc]="FAIL"
      SVC_DETAIL[$svc]="fp_${svc} вернул error (src=$src_status, dst=$dst_status) — kubectl exec или admin-creds сбой"
      FAIL_COUNT=$((FAIL_COUNT+1))
      ;;
    ok/ok)
      sd=$(diff_obj "services.$svc.structural" "$SRC_PLAIN" "$DST_PLAIN")
      id=$(diff_obj "services.$svc.informational" "$SRC_PLAIN" "$DST_PLAIN")
      if [ "$sd" = "null" ]; then
        # structural идентичны
        if [ "$id" = "null" ]; then
          SVC_STATUS[$svc]="PASS"
          SVC_DETAIL[$svc]="structural+informational совпадают"
          PASS_COUNT=$((PASS_COUNT+1))
        else
          SVC_STATUS[$svc]="WARN"
          SVC_DETAIL[$svc]="structural совпадает; informational расходится (см. diff.json — обычно ожидаемо: данные не бэкапятся)"
          SVC_INFO_DIFF[$svc]="$id"
          WARN_COUNT=$((WARN_COUNT+1))
          PASS_COUNT=$((PASS_COUNT+1))  # PASS на verdict-уровне
        fi
      else
        SVC_STATUS[$svc]="FAIL"
        SVC_DETAIL[$svc]="structural расходится — restore воспроизвёл не то"
        SVC_STRUCT_DIFF[$svc]="$sd"
        if [ "$id" != "null" ]; then SVC_INFO_DIFF[$svc]="$id"; fi
        FAIL_COUNT=$((FAIL_COUNT+1))
      fi
      ;;
    *)
      SVC_STATUS[$svc]="FAIL"
      SVC_DETAIL[$svc]="асимметрия: src=$src_status, dst=$dst_status"
      FAIL_COUNT=$((FAIL_COUNT+1))
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Печать summary + запись отчётов.
# -----------------------------------------------------------------------------
echo ""
echo "=== Fingerprint diff: $APP   src=$SRC_ENV ($SRC_TS)  →  dst=$DST_ENV ($DST_TS) ==="
echo ""
for svc in $ALL_SERVICES; do
  printf "  %-12s %-5s %s\n" "$svc" "${SVC_STATUS[$svc]}" "${SVC_DETAIL[$svc]}"
done
echo ""
echo "Verdict: PASS=$PASS_COUNT  WARN=$WARN_COUNT  FAIL=$FAIL_COUNT  SKIP=$SKIP_COUNT"

# -- Markdown report --
{
  echo "# Fingerprint diff: $APP"
  echo ""
  echo "- source: env=\`$SRC_ENV\` ts=\`$SRC_TS\`"
  echo "- dst:    env=\`$DST_ENV\` ts=\`$DST_TS\`"
  echo ""
  echo "| service | status | detail |"
  echo "|---|---|---|"
  for svc in $ALL_SERVICES; do
    d=$(printf '%s' "${SVC_DETAIL[$svc]}" | tr '|' '/')
    echo "| $svc | ${SVC_STATUS[$svc]} | $d |"
  done
  echo ""
  echo "Verdict: **$([ "$FAIL_COUNT" -gt 0 ] && echo FAIL || echo PASS)** (pass=$PASS_COUNT warn=$WARN_COUNT fail=$FAIL_COUNT skip=$SKIP_COUNT)"
  echo ""
  # Раскладка structural-diff'ов.
  for svc in $ALL_SERVICES; do
    if [ -n "${SVC_STRUCT_DIFF[$svc]:-}" ]; then
      echo ""
      echo "## structural diff: $svc"
      echo ""
      echo '```json'
      echo "${SVC_STRUCT_DIFF[$svc]}" | jq .
      echo '```'
    fi
  done
  for svc in $ALL_SERVICES; do
    if [ -n "${SVC_INFO_DIFF[$svc]:-}" ]; then
      echo ""
      echo "## informational diff: $svc"
      echo ""
      echo '```json'
      echo "${SVC_INFO_DIFF[$svc]}" | jq .
      echo '```'
    fi
  done
} > "$OUT_REPORT_MD"

# -- JSON report (machine-readable) --
{
  printf '{\n'
  printf '  "app": %s,\n' "$(jq -Rn --arg s "$APP" '$s')"
  printf '  "src": {"env": %s, "ts": %s, "path": %s},\n' \
    "$(jq -Rn --arg s "$SRC_ENV" '$s')" "$(jq -Rn --arg s "$SRC_TS" '$s')" "$(jq -Rn --arg s "$SRC_FINGERPRINT" '$s')"
  printf '  "dst": {"env": %s, "ts": %s, "path": %s},\n' \
    "$(jq -Rn --arg s "$DST_ENV" '$s')" "$(jq -Rn --arg s "$DST_TS" '$s')" "$(jq -Rn --arg s "$DST_FINGERPRINT" '$s')"
  printf '  "summary": {"pass":%d,"warn":%d,"fail":%d,"skip":%d,"verdict":"%s"},\n' \
    "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$([ "$FAIL_COUNT" -gt 0 ] && echo FAIL || echo PASS)"
  printf '  "services": {\n'
  first=1
  for svc in $ALL_SERVICES; do
    [ "$first" = "1" ] && first=0 || printf ',\n'
    sd="${SVC_STRUCT_DIFF[$svc]:-null}"
    id="${SVC_INFO_DIFF[$svc]:-null}"
    printf '    "%s": {"status": "%s", "detail": %s, "structural_diff": %s, "informational_diff": %s}' \
      "$svc" "${SVC_STATUS[$svc]}" \
      "$(jq -Rn --arg s "${SVC_DETAIL[$svc]}" '$s')" \
      "$sd" "$id"
  done
  printf '\n  }\n'
  printf '}\n'
} > "$OUT_DIFF_JSON"

# Финальная валидация JSON.
if ! jq empty "$OUT_DIFF_JSON" 2>/dev/null; then
  err "⚠ итоговый diff.json не валидный (см. $OUT_DIFF_JSON)"
fi

echo ""
echo "Markdown report: $OUT_REPORT_MD"
echo "JSON diff:       $OUT_DIFF_JSON"

if [ "$FAIL_COUNT" -gt 0 ]; then exit 1; fi
exit 0
