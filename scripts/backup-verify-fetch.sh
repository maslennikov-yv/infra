#!/usr/bin/env bash
# backup-verify-fetch.sh — скопировать на admin-машину свежие backup-файлы из SRC_ENV.
#
# Источник: либо удалённая нода (если в environments/<SRC_ENV>.mk задан SSH_HOST),
# либо локальная файловая система (если SSH_HOST пуст — SRC на этой же машине).
#
# Список загружаемых артефактов (если присутствуют — пропускаются с пометкой):
#   environments/backups/<SRC>/LATEST.tar.gz[.age]
#   postgres/backups/<SRC>/postgres-backup-LATEST.sql.gz[.age]
#   redis/backups/<SRC>/redis-backup-LATEST.tar.gz[.age]
#   kafka/backups/<SRC>/kafka-meta-LATEST.tar.gz[.age]
#   minio/backups/<SRC>/minio-meta-LATEST.tar.gz[.age]
#   clickhouse/backups/<SRC>/clickhouse-backup-LATEST.tar.gz[.age]
#   rabbitmq/backups/<SRC>/rabbitmq-defs-LATEST.json.gz[.age]
#   verify-reports/*/fingerprint-source-<SRC>-LATEST.json[.age]  (опционально)
#
# Args (env):
#   SRC_ENV               — имя env-источника. Обязательно.
#   APP                   — имя приложения (для имени incoming-каталога). Обязательно.
#   REPO_ROOT             — корень репо. По умолчанию $(pwd).
#   TARGET_DIR            — куда складывать. По умолчанию $REPO_ROOT/verify-reports/<TS>-<APP>/incoming/.
#   INCLUDE_FINGERPRINT   — копировать ли source-fingerprint (1/0). По умолчанию 1.
#   BACKUP_AGE_KEY_FILE   — для integrity-check .age файлов.
#   SSH_HOST, SSH_USER, SSH_KEY, SSH_PORT — если не заданы, читаем из environments/<SRC>.mk.
#                          SSH_USER по умолчанию "ubuntu", SSH_PORT 22.
#   REMOTE_REPO_ROOT      — путь к репо на удалённой ноде. По умолчанию /opt/infra
#                          (можно переопределить в environments/<SRC>.mk).
#   SKIP_MISSING          — если файл не найден, пропустить с warning вместо fail (1/0). По умолчанию 0.
#   REQUIRED_BACKUPS      — comma-separated список label'ов из ARTIFACTS, которые ОБЯЗАТЕЛЬНЫ.
#                           Остальные становятся optional. Пустое значение → все обязательны
#                           (legacy-поведение). Используется orchestrator'ом для auto-detect:
#                           APP может не использовать все 6 сервисов, и тогда missing-backups
#                           для них не должны валить пайплайн.
#                           Default labels в ARTIFACTS: env-backup, postgres, redis, kafka,
#                           minio, clickhouse, rabbitmq.
#
# Stdout: список скопированных файлов + integrity-status.
#
# Exit:
#   0 — все ожидаемые файлы скопированы и прошли integrity.
#   1 — что-то не скопировалось или integrity fail.

set -uo pipefail

SRC_ENV="${SRC_ENV:-}"
APP="${APP:-}"
REPO_ROOT="${REPO_ROOT:-$(pwd)}"
TARGET_DIR="${TARGET_DIR:-}"
INCLUDE_FINGERPRINT="${INCLUDE_FINGERPRINT:-1}"
BACKUP_AGE_KEY_FILE="${BACKUP_AGE_KEY_FILE:-}"
REMOTE_REPO_ROOT="${REMOTE_REPO_ROOT:-/opt/infra}"
SKIP_MISSING="${SKIP_MISSING:-0}"
REQUIRED_BACKUPS="${REQUIRED_BACKUPS:-}"

err() { echo "$@" >&2; }

[ -n "$SRC_ENV" ] || { err "✗ SRC_ENV не задан"; exit 1; }
[ -n "$APP" ]     || { err "✗ APP не задан"; exit 1; }

ENV_MK="$REPO_ROOT/environments/$SRC_ENV.mk"
[ -f "$ENV_MK" ] || { err "✗ $ENV_MK не найден"; exit 1; }

# Считать SSH-параметры из env (если не переопределены): mk-файл простой,
# формат "KEY = VAL" или "KEY ?= VAL". Пропускаем комментарии.
mk_get() {
  local key="$1"
  awk -v k="$key" '
    /^[[:space:]]*#/ { next }
    $1 == k && ($2 == "=" || $2 == "?=" || $2 == ":=") {
      val = ""
      for (i=3; i<=NF; i++) val = val (i==3 ? "" : " ") $i
      print val; exit
    }
  ' "$ENV_MK"
}

: "${SSH_HOST:=$(mk_get SSH_HOST)}"
: "${SSH_USER:=$(mk_get SSH_USER)}"
: "${SSH_KEY:=$(mk_get SSH_KEY)}"
: "${SSH_PORT:=$(mk_get SSH_PORT)}"
REMOTE_REPO_ROOT="${REMOTE_REPO_ROOT:-$(mk_get REMOTE_REPO_ROOT)}"
[ -n "$REMOTE_REPO_ROOT" ] || REMOTE_REPO_ROOT="/opt/infra"
[ -n "$SSH_USER" ] || SSH_USER="ubuntu"
[ -n "$SSH_PORT" ] || SSH_PORT=22

LOCAL_MODE=0
if [ -z "$SSH_HOST" ]; then
  LOCAL_MODE=1
  REMOTE_REPO_ROOT="$REPO_ROOT"
fi

if [ -z "$TARGET_DIR" ]; then
  TS=$(date -u +%Y%m%dT%H%M%SZ)
  TARGET_DIR="$REPO_ROOT/verify-reports/${TS}-${APP}/incoming"
fi
install -d -m 700 "$TARGET_DIR"

echo "=== backup-verify-fetch: SRC=$SRC_ENV → $TARGET_DIR ==="
if [ "$LOCAL_MODE" = "1" ]; then
  echo "  режим: локальный (SSH_HOST пуст в $SRC_ENV.mk)"
else
  echo "  режим: SSH $SSH_USER@$SSH_HOST:$SSH_PORT  (remote repo: $REMOTE_REPO_ROOT)"
fi

# -----------------------------------------------------------------------------
# Helpers для разрешения LATEST файла по glob, копирования, integrity.
# -----------------------------------------------------------------------------
ssh_opts=(-o StrictHostKeyChecking=accept-new -p "$SSH_PORT")
[ -n "$SSH_KEY" ] && ssh_opts+=(-i "$SSH_KEY")
remote_run() {
  if [ "$LOCAL_MODE" = "1" ]; then
    bash -c "$1"
  else
    ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" "$1"
  fi
}

# Найти свежий файл, соответствующий glob-у. Сначала .age (если есть), иначе plain.
# Возвращает абсолютный путь или пустую строку.
find_latest() {
  local dir="$1" pattern="$2"
  local script
  # bash на удалённой стороне; ls -1t выдаёт по mtime, head -1 — самый свежий.
  # Сначала пробуем .age-вариант, затем plain.
  script="d='$dir'; p='$pattern'; [ -d \"\$d\" ] || exit 0; \
    f=\$(ls -1t \"\$d/\"\$p.age 2>/dev/null | head -1); \
    [ -z \"\$f\" ] && f=\$(ls -1t \"\$d/\"\$p 2>/dev/null | head -1); \
    [ -n \"\$f\" ] && readlink -f \"\$f\""
  remote_run "$script"
}

# Скопировать файл из remote → local TARGET_DIR (или local cp при LOCAL_MODE).
copy_one() {
  local src="$1" dst_dir="$2"
  local dst="$dst_dir/$(basename "$src")"
  if [ "$LOCAL_MODE" = "1" ]; then
    cp -p "$src" "$dst"
  else
    scp -q "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST:$src" "$dst" >/dev/null
  fi
  printf '%s' "$dst"
}

# Integrity для одного локального файла.
integrity_check() {
  local f="$1"
  case "$f" in
    *.age)
      if [ -z "$BACKUP_AGE_KEY_FILE" ] || [ ! -f "$BACKUP_AGE_KEY_FILE" ]; then
        echo "no-key"; return 1
      fi
      if age --decrypt -i "$BACKUP_AGE_KEY_FILE" -o /dev/null "$f" 2>/dev/null; then
        echo "ok"; return 0
      fi
      echo "age-bad"; return 1
      ;;
    *.tar.gz)
      if tar -tzf "$f" >/dev/null 2>&1; then echo "ok"; return 0; fi
      echo "tar-bad"; return 1
      ;;
    *.gz|*.sql.gz|*.json.gz)
      if gunzip -t "$f" 2>/dev/null; then echo "ok"; return 0; fi
      echo "gz-bad"; return 1
      ;;
    *.json)
      if jq empty "$f" 2>/dev/null; then echo "ok"; return 0; fi
      echo "json-bad"; return 1
      ;;
    *)
      echo "no-check"; return 0
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Список артефактов: dir, pattern, human-name, optional?
# -----------------------------------------------------------------------------
# Поле optional вычисляется ниже из REQUIRED_BACKUPS (если задано).
ARTIFACTS=(
  "environments/backups/$SRC_ENV|*.tar.gz|env-backup|0"
  "postgres/backups/$SRC_ENV|postgres-backup-*.sql.gz|postgres|0"
  "redis/backups/$SRC_ENV|redis-backup-*.tar.gz|redis|0"
  "kafka/backups/$SRC_ENV|kafka-meta-*.tar.gz|kafka|0"
  "minio/backups/$SRC_ENV|minio-meta-*.tar.gz|minio|0"
  "clickhouse/backups/$SRC_ENV|clickhouse-backup-*.tar.gz|clickhouse|0"
  "rabbitmq/backups/$SRC_ENV|rabbitmq-defs-*.json.gz|rabbitmq|0"
)

# Если REQUIRED_BACKUPS задан — отметить лейблы НЕ из списка как optional=1.
# Это позволяет orchestrator'у сказать «APP не использует ClickHouse — отсутствие
# clickhouse-backup-* не должно валить fetch».
if [ -n "$REQUIRED_BACKUPS" ]; then
  declare -a NEW_ARTIFACTS=()
  for entry in "${ARTIFACTS[@]}"; do
    IFS='|' read -r d p l o <<<"$entry"
    case ",$REQUIRED_BACKUPS," in
      *",$l,"*) o=0 ;;
      *)        o=1 ;;
    esac
    NEW_ARTIFACTS+=("$d|$p|$l|$o")
  done
  ARTIFACTS=("${NEW_ARTIFACTS[@]}")
  echo "  required backups: $REQUIRED_BACKUPS (остальные optional)"
fi

# Опционально добавляем source-fingerprint (свежий из любого verify-reports/*/).
if [ "$INCLUDE_FINGERPRINT" = "1" ]; then
  ARTIFACTS+=("verify-reports|*/fingerprint-source-$SRC_ENV-*.json|fingerprint-source|1")
fi

FAIL=0
COPIED=()
declare -A INTEGRITY_RESULT=()

for entry in "${ARTIFACTS[@]}"; do
  IFS='|' read -r reldir pattern label optional <<<"$entry"
  remote_dir="$REMOTE_REPO_ROOT/$reldir"
  echo ""
  echo "-- $label  ($reldir / $pattern)"
  src_path=$(find_latest "$remote_dir" "$pattern" || true)
  if [ -z "$src_path" ]; then
    if [ "$optional" = "1" ] || [ "$SKIP_MISSING" = "1" ]; then
      echo "  ↷ не найден (skip; optional=$optional, SKIP_MISSING=$SKIP_MISSING)"
      continue
    fi
    echo "  ✗ не найден в $remote_dir"
    FAIL=$((FAIL+1))
    continue
  fi
  echo "  src: $src_path"
  if local_path=$(copy_one "$src_path" "$TARGET_DIR"); then
    echo "  dst: $local_path"
    res=$(integrity_check "$local_path" || true)
    INTEGRITY_RESULT[$local_path]="$res"
    if [ "$res" = "ok" ] || [ "$res" = "no-check" ]; then
      echo "  integrity: $res"
    else
      echo "  integrity: $res ✗"
      FAIL=$((FAIL+1))
    fi
    COPIED+=("$local_path")
  else
    echo "  ✗ копирование не удалось"
    FAIL=$((FAIL+1))
  fi
done

# -----------------------------------------------------------------------------
# Summary.
# -----------------------------------------------------------------------------
echo ""
echo "=== fetch summary ==="
echo "Целевой каталог: $TARGET_DIR"
for f in "${COPIED[@]}"; do
  sz=$(du -h "$f" 2>/dev/null | awk '{print $1}')
  printf "  %-12s %s\n" "${INTEGRITY_RESULT[$f]:-?}" "$f ($sz)"
done

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "✗ Ошибок: $FAIL (см. выше)"
  exit 1
fi

# Печатаем переменную для downstream скрипта (orchestrator).
echo ""
echo "BACKUP_FILES=\"$(printf '%s ' "${COPIED[@]}" | sed 's/ $//')\""

exit 0
