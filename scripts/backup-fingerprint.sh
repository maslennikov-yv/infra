#!/usr/bin/env bash
# backup-fingerprint.sh — structural snapshot одного APP под admin-creds.
#
# Назначение: снять «отпечаток» состояния всех сервисов, к которым подключён APP,
# до бэкапа (на источнике, ROLE=source) и после восстановления (на цели, ROLE=dst),
# чтобы backup-fingerprint-diff.sh сравнил два отпечатка и поймал расхождения,
# которые не покрывает `make doctor` + `*-app-verify`.
#
# Под admin-кредами (не APP-кредами), потому что для RabbitMQ management API,
# Redis ACL LIST, Kafka --describe и MinIO mc admin прав APP-юзера недостаточно
# (см. аудит в плане backup-verify).
#
# Структура fingerprint:
#   - structural (PASS/FAIL критерий после diff): то, что ДЕЙСТВИТЕЛЬНО восстанавливается
#     из *-backup-meta / *-backup-defs / pg_dumpall — топики, ACL, vhost, schemas,
#     политики, bucket-config. Этот блок diff'ается strict.
#   - informational (warning при расхождении, не FAIL): данные, которые НЕ бэкапятся
#     метой (Kafka offsets, MinIO du, CH row counts, Redis DBSIZE, RMQ queue depth).
#     Полезно для понимания «насколько данные расходятся», но не блокирует verify.
#
# Args (env):
#   APP                — имя приложения (из apps/registry.yaml). Обязательно.
#   ENV                — env, в котором снимаем (для пометки в JSON). Обязательно.
#   ROLE               — "source" или "dst". Обязательно.
#   REPO_ROOT          — корень репо. По умолчанию $(pwd).
#   KUBECONFIG         — kubeconfig того кластера, где снимаем. Обязательно.
#   YQ                 — путь к mikefarah yq. По умолчанию "yq".
#   APPS_REGISTRY      — путь к apps/registry.yaml. По умолчанию $REPO_ROOT/apps/registry.yaml.
#   APPS_MERGED_FILE   — путь к merged config (если уже посчитан вызывающей стороной).
#                        Если пусто — будет посчитан через scripts/apps-merge-config.sh.
#   OUT_FILE           — куда писать JSON. По умолчанию <REPORT_DIR>/fingerprint-<ROLE>-<ENV>-<TS>.json.
#   VERIFY_REPORT_DIR  — каталог для отчётов (если OUT_FILE не задан).
#                        По умолчанию: $REPO_ROOT/verify-reports/<TS>-<APP>/.
#   BACKUP_AGE_RECIPIENT — если задан, JSON-файл шифруется age recipient'ом (см. PR1 / docs/runbooks/backups-encryption.md).
#                          Структурная информация о prod может быть чувствительной.
#
# Stdout: progress + путь к итоговому JSON.
#
# Exit:
#   0 — fingerprint снят (хотя бы для одного сервиса; для отсутствующих сервисов
#       в structural будет {"status": "absent"}).
#   1 — критичная ошибка (нет admin Secret, kubectl недоступен, нет APP в реестре).

set -uo pipefail

APP="${APP:-}"
ENV_NAME="${ENV:-}"
ROLE="${ROLE:-}"
REPO_ROOT="${REPO_ROOT:-$(pwd)}"
KUBECONFIG_FILE="${KUBECONFIG:-}"
YQ_BIN="${YQ:-yq}"
APPS_REGISTRY="${APPS_REGISTRY:-$REPO_ROOT/apps/registry.yaml}"
APPS_MERGED_FILE="${APPS_MERGED_FILE:-}"
OUT_FILE="${OUT_FILE:-}"
VERIFY_REPORT_DIR="${VERIFY_REPORT_DIR:-}"
BACKUP_AGE_RECIPIENT="${BACKUP_AGE_RECIPIENT:-}"

err() { echo "$@" >&2; }

[ -n "$APP" ]      || { err "✗ APP не задан"; exit 1; }
[ -n "$ENV_NAME" ] || { err "✗ ENV не задан"; exit 1; }
[ -n "$ROLE" ]     || { err "✗ ROLE не задан (source|dst)"; exit 1; }
[ -n "$KUBECONFIG_FILE" ] || { err "✗ KUBECONFIG не задан"; exit 1; }
case "$ROLE" in source|dst) : ;; *) err "✗ ROLE должен быть source или dst"; exit 1 ;; esac
command -v kubectl >/dev/null 2>&1 || { err "✗ kubectl не найден"; exit 1; }
command -v jq      >/dev/null 2>&1 || { err "✗ jq не найден"; exit 1; }

TS=$(date -u +%Y%m%dT%H%M%SZ)
if [ -z "$OUT_FILE" ]; then
  if [ -z "$VERIFY_REPORT_DIR" ]; then
    VERIFY_REPORT_DIR="$REPO_ROOT/verify-reports/${TS}-${APP}"
  fi
  mkdir -p "$VERIFY_REPORT_DIR"
  OUT_FILE="$VERIFY_REPORT_DIR/fingerprint-${ROLE}-${ENV_NAME}-${TS}.json"
fi
mkdir -p "$(dirname "$OUT_FILE")"

# -----------------------------------------------------------------------------
# Merge config для APP. Содержит password/db/bucket/etc. ПЕР-приложение.
# -----------------------------------------------------------------------------
CLEAN_MERGED=0
if [ -z "$APPS_MERGED_FILE" ]; then
  APPS_MERGED_FILE=$(mktemp); CLEAN_MERGED=1
  if ! "$REPO_ROOT/scripts/apps-merge-config.sh" "$APPS_REGISTRY" "$REPO_ROOT" "$ENV_NAME" >"$APPS_MERGED_FILE"; then
    err "✗ apps-merge-config.sh упал"; rm -f "$APPS_MERGED_FILE"; exit 1
  fi
fi
trap 'if [ "$CLEAN_MERGED" = 1 ]; then rm -f "$APPS_MERGED_FILE"; fi' EXIT

# Helper: вытащить поле через app-config-get.sh; пустую строку трактуем как "нет".
cfg_get() {
  local path="$1"
  local v
  v=$("$REPO_ROOT/scripts/app-config-get.sh" "$APPS_MERGED_FILE" "$APP" "$path" 2>/dev/null || true)
  if [ -z "$v" ] || [ "$v" = "null" ]; then return 1; fi
  printf '%s' "$v"
}

# Helper: безопасно сериализовать строку как JSON-строку через jq.
jstr() { jq -Rn --arg s "$1" '$s'; }

# Helper: безопасно сериализовать stdin как JSON-массив строк (одна строка = один элемент).
# Используем `jq -Rs split` чтобы не зависеть от порядка чтения.
jarr_lines() {
  jq -Rn --arg s "$(cat)" '($s | split("\n") | map(select(length>0)))'
}

# Helper: «канонизировать» произвольный JSON-кандидат, прилетевший из kubectl exec/run.
# - Пустой ввод → "null"
# - Валидный JSON → как есть (первая строка через jq compact)
# - Невалидный → "null" + warning в stderr
# Используется в fp_minio для подстановки в --argjson, потому что прямой
# `--argjson user_info "$(head -1)"` падает на невалидном JSON / ошибках mc.
sanitize_json() {
  local label="$1" val="${2:-}"
  if [ -z "$val" ]; then echo "null"; return; fi
  local first
  first=$(echo "$val" | head -1)
  if [ -z "$first" ]; then echo "null"; return; fi
  if echo "$first" | jq -c '.' 2>/dev/null; then
    return
  fi
  err "    ⚠ fp_minio[$label]: невалидный JSON-фрагмент (truncating to null)"
  echo "null"
}

# -----------------------------------------------------------------------------
# Сервисные fingerprint-функции. Каждая печатает JSON-объект, который будет
# вставлен в общий fingerprint под ключом ".services.<svc>".
# При недостижимости сервиса/Secret выдают {"status":"absent","error":"..."}.
# -----------------------------------------------------------------------------

# --- Postgres ---------------------------------------------------------------
# admin: Secret postgres/postgres-postgresql.postgres-password.
# app db default: app_<APP>; переопределение через postgres.database в conf.
fp_postgres() {
  if ! cfg_get postgres.password >/dev/null; then
    jq -n '{status:"skipped",reason:"postgres.password не задан в merged для этого APP"}'
    return 0
  fi
  local db; db=$(cfg_get postgres.database || echo "app_$APP")
  local pod
  pod=$(kubectl --kubeconfig "$KUBECONFIG_FILE" -n postgres get pods \
    -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -z "$pod" ]; then
    jq -n --arg db "$db" '{status:"absent",database:$db,error:"postgres pod not found"}'
    return 0
  fi
  local pw
  pw=$(kubectl --kubeconfig "$KUBECONFIG_FILE" -n postgres get secret postgres-postgresql \
    -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d || true)
  if [ -z "$pw" ]; then
    jq -n --arg db "$db" '{status:"absent",database:$db,error:"admin secret missing"}'
    return 0
  fi
  # Список таблиц: schema, table_name, sort.
  local tables
  tables=$(kubectl --kubeconfig "$KUBECONFIG_FILE" -n postgres exec -i "$pod" -- \
    env PGPASSWORD="$pw" psql -U postgres -d "$db" -t -A -F "." -c \
    "SELECT schemaname, tablename FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1,2;" 2>/dev/null || true)
  # Row counts (informational) — по каждой таблице count(*).
  local counts_json="{}"
  if [ -n "$tables" ]; then
    local cnt_lines
    cnt_lines=$(while IFS=. read -r sch tbl; do
        [ -n "$sch" ] && [ -n "$tbl" ] || continue
        n=$(kubectl --kubeconfig "$KUBECONFIG_FILE" -n postgres exec -i "$pod" -- \
            env PGPASSWORD="$pw" psql -U postgres -d "$db" -t -A -c \
            "SELECT count(*) FROM \"$sch\".\"$tbl\";" 2>/dev/null | tr -d '[:space:]' || echo "?")
        printf '%s.%s\t%s\n' "$sch" "$tbl" "$n"
      done <<<"$tables")
    counts_json=$(echo "$cnt_lines" | jq -Rn '[inputs | split("\t") | select(length==2) | {(.[0]):(.[1]|tonumber? // .)}] | add // {}')
  fi
  # Schema hash: pg_dump --schema-only, отфильтрованный от version-зависимых строк.
  # Делаем через temp file + проверку size > 0, чтобы поймать упавший pg_dump:
  # если pg_dump пишет пусто, sha256sum пустого pipe всегда даёт e3b0c44298fc...
  # → два упавших dump'а будут давать одинаковый hash → false-PASS structural diff.
  local schema_hash="" tmp_dump
  tmp_dump=$(mktemp)
  if kubectl --kubeconfig "$KUBECONFIG_FILE" -n postgres exec -i "$pod" -- \
      env PGPASSWORD="$pw" pg_dump --schema-only --no-owner --no-comments -U postgres "$db" \
      > "$tmp_dump" 2>/dev/null && [ -s "$tmp_dump" ]; then
    schema_hash=$(grep -vE '^-- Dumped (from|by) ' "$tmp_dump" \
      | grep -vE '^SET (default_table_access_method|row_security|xmloption)' \
      | sha256sum | awk '{print $1}')
  fi
  rm -f "$tmp_dump"
  local tables_json
  tables_json=$(echo "$tables" | awk -F. 'NF==2 {print $1"."$2}' | jarr_lines)
  jq -n \
    --arg db "$db" \
    --argjson tables "$tables_json" \
    --arg schema_hash "${schema_hash:-}" \
    --argjson counts "$counts_json" \
    '{
      status: "ok",
      structural: {database:$db, tables:$tables, schema_hash:$schema_hash},
      informational: {row_counts:$counts}
    }'
}

# --- Redis ------------------------------------------------------------------
# admin: Secret redis/redis.redis-password.
# app user: app_<APP>; redis_db из registry/conf.
fp_redis() {
  if ! cfg_get redis.password >/dev/null; then
    jq -n '{status:"skipped",reason:"redis.password не задан"}'
    return 0
  fi
  local user="app_$APP"
  local db; db=$(cfg_get redis.db || echo "")
  if [ -z "$db" ]; then
    # fallback: registry.apps[].redis_db.
    db=$(NM="$APP" "$YQ_BIN" -r '.apps[] | select(.name == strenv(NM)) | .redis_db // ""' "$APPS_REGISTRY" 2>/dev/null || echo "")
  fi
  local pod
  pod=$(kubectl --kubeconfig "$KUBECONFIG_FILE" -n redis get pods \
    -l app.kubernetes.io/name=redis,app.kubernetes.io/component=master \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -z "$pod" ]; then
    jq -n --arg user "$user" --arg db "$db" '{status:"absent",user:$user,db:$db,error:"redis master pod not found"}'
    return 0
  fi
  local pw
  pw=$(kubectl --kubeconfig "$KUBECONFIG_FILE" -n redis get secret redis \
    -o jsonpath='{.data.redis-password}' 2>/dev/null | base64 -d || true)
  if [ -z "$pw" ]; then
    jq -n --arg user "$user" '{status:"absent",user:$user,error:"admin secret missing"}'
    return 0
  fi
  # ACL GETUSER возвращает массив строк key=value; нормализуем в map.
  local acl_raw
  acl_raw=$(kubectl --kubeconfig "$KUBECONFIG_FILE" -n redis exec -i "$pod" -- \
    env REDISCLI_AUTH="$pw" redis-cli ACL GETUSER "$user" 2>/dev/null || true)
  local acl_json="null"
  if [ -n "$acl_raw" ]; then
    # ACL GETUSER печатает пары "field\nvalue\nfield\nvalue\n...".
    # Группируем построчно: нечётная строка = ключ, чётная = значение.
    acl_json=$(echo "$acl_raw" | awk 'NR%2==1 {k=$0; next} {print k"\t"$0}' \
      | jq -Rn '[inputs | split("\t") | select(length==2) | {(.[0]): .[1]}] | add // {}')
  fi
  # DBSIZE на db приложения (informational).
  local dbsize="null"
  if [ -n "$db" ]; then
    local d
    d=$(kubectl --kubeconfig "$KUBECONFIG_FILE" -n redis exec -i "$pod" -- \
      env REDISCLI_AUTH="$pw" redis-cli -n "$db" DBSIZE 2>/dev/null | tr -d '[:space:]' || echo "")
    if [ -n "$d" ]; then dbsize="$d"; fi
  fi
  jq -n \
    --arg user "$user" \
    --arg db "$db" \
    --argjson acl "$acl_json" \
    --arg dbsize "$dbsize" \
    '{
      status: "ok",
      structural: {user:$user, db:$db, acl:$acl},
      informational: {dbsize: ($dbsize | tonumber? // null)}
    }'
}

# --- Kafka ------------------------------------------------------------------
# admin: Secret kafka/kafka-user-passwords.client-passwords (первое поле = user1).
# fingerprint работает через `kubectl run` helper-pod (как kafka-app-create), потому что
# admin client-tools (kafka-topics.sh, kafka-acls.sh) удобнее запускать с готовым
# admin.properties.
fp_kafka() {
  if ! cfg_get kafka.password >/dev/null; then
    jq -n '{status:"skipped",reason:"kafka.password не задан"}'
    return 0
  fi
  local user="app_$APP"
  local prefix="${APP}."
  local admin_pw
  admin_pw=$(kubectl --kubeconfig "$KUBECONFIG_FILE" -n kafka get secret kafka-user-passwords \
    -o jsonpath='{.data.client-passwords}' 2>/dev/null | base64 -d | cut -d, -f1 || true)
  if [ -z "$admin_pw" ]; then
    jq -n --arg user "$user" '{status:"absent",user:$user,error:"admin client-passwords missing"}'
    return 0
  fi
  local image
  image=$(kubectl --kubeconfig "$KUBECONFIG_FILE" -n kafka get sts -l app.kubernetes.io/name=kafka \
    -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)
  if [ -z "$image" ]; then
    jq -n --arg user "$user" '{status:"absent",user:$user,error:"kafka image not detected"}'
    return 0
  fi
  local helper="kafka-fp-$(date +%s)-$$"
  local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" RETURN
  # Скрипт внутри helper: топики (с фильтром по префиксу) + describe + ACL.
  cat >"$tmp/run.sh" <<'EOF'
set -u
cat > /tmp/admin.properties <<PROP
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-256
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="user1" password="$ADMIN_PW";
PROP
BS=kafka.kafka.svc.cluster.local:9092
echo "===TOPICS==="
kafka-topics.sh --bootstrap-server "$BS" --command-config /tmp/admin.properties --list 2>/dev/null \
  | awk -v p="$PREFIX" 'index($0,p)==1' | sort
echo "===DESCRIBE==="
for t in $(kafka-topics.sh --bootstrap-server "$BS" --command-config /tmp/admin.properties --list 2>/dev/null | awk -v p="$PREFIX" 'index($0,p)==1' | sort); do
  kafka-topics.sh --bootstrap-server "$BS" --command-config /tmp/admin.properties --describe --topic "$t" 2>/dev/null \
    | head -1
done
echo "===ACLS==="
kafka-acls.sh --bootstrap-server "$BS" --command-config /tmp/admin.properties \
  --list --principal "User:$USER" 2>/dev/null | sort
echo "===OFFSETS==="
for t in $(kafka-topics.sh --bootstrap-server "$BS" --command-config /tmp/admin.properties --list 2>/dev/null | awk -v p="$PREFIX" 'index($0,p)==1' | sort); do
  # Раньше: `awk ... t="$t"` после программы → awk трактует как файл, не assignment.
  # Корректно: `-v t="$t"` ДО программы.
  kafka-get-offsets.sh --bootstrap-server "$BS" --command-config /tmp/admin.properties --topic "$t" --time -1 2>/dev/null \
    | awk -F: -v t="$t" '{sum+=$3} END {printf "%s %d\n", t, sum+0}'
done
EOF
  local raw
  raw=$(kubectl --kubeconfig "$KUBECONFIG_FILE" -n kafka run "$helper" \
    --restart=Never --image="$image" --rm -i --quiet \
    --env="ADMIN_PW=$admin_pw" --env="PREFIX=$prefix" --env="USER=$user" \
    --command -- bash -ec "$(cat "$tmp/run.sh")" 2>/dev/null || true)
  if [ -z "$raw" ]; then
    jq -n --arg user "$user" '{status:"absent",user:$user,error:"kubectl run kafka helper failed"}'
    return 0
  fi
  local topics describe acls offsets
  topics=$(echo "$raw"   | awk '/^===TOPICS===/{f=1;next} /^===/{f=0} f')
  describe=$(echo "$raw" | awk '/^===DESCRIBE===/{f=1;next} /^===/{f=0} f')
  acls=$(echo "$raw"     | awk '/^===ACLS===/{f=1;next} /^===/{f=0} f')
  offsets=$(echo "$raw"  | awk '/^===OFFSETS===/{f=1;next} /^===/{f=0} f')
  local topics_json describe_json acls_json offsets_json
  topics_json=$(printf '%s\n' "$topics"     | jarr_lines)
  describe_json=$(printf '%s\n' "$describe" | jarr_lines)
  acls_json=$(printf '%s\n' "$acls"         | jarr_lines)
  offsets_json=$(printf '%s\n' "$offsets" | awk 'NF==2 {print $1"\t"$2}' \
    | jq -Rn '[inputs | split("\t") | select(length==2) | {(.[0]):(.[1]|tonumber? // 0)}] | add // {}')
  jq -n \
    --arg user "$user" \
    --arg prefix "$prefix" \
    --argjson topics "$topics_json" \
    --argjson describe "$describe_json" \
    --argjson acls "$acls_json" \
    --argjson offsets "$offsets_json" \
    '{
      status: "ok",
      structural: {user:$user, topic_prefix:$prefix, topics:$topics, describe:$describe, acls:$acls},
      informational: {offsets:$offsets}
    }'
}

# --- MinIO ------------------------------------------------------------------
# admin: Secret minio/minio.root-user / root-password.
# helper pod с minio/mc.
fp_minio() {
  if ! cfg_get minio.secret_key >/dev/null; then
    jq -n '{status:"skipped",reason:"minio.secret_key не задан"}'
    return 0
  fi
  local access_key bucket
  access_key=$(cfg_get minio.access_key || echo "$APP")
  bucket=$(cfg_get minio.bucket || echo "$APP")
  local root_user root_pw
  root_user=$(kubectl --kubeconfig "$KUBECONFIG_FILE" -n minio get secret minio \
    -o jsonpath='{.data.root-user}' 2>/dev/null | base64 -d || true)
  root_pw=$(kubectl --kubeconfig "$KUBECONFIG_FILE" -n minio get secret minio \
    -o jsonpath='{.data.root-password}' 2>/dev/null | base64 -d || true)
  if [ -z "$root_user" ] || [ -z "$root_pw" ]; then
    jq -n --arg ak "$access_key" --arg b "$bucket" '{status:"absent",access_key:$ak,bucket:$b,error:"root creds missing"}'
    return 0
  fi
  local helper="mc-fp-$(date +%s)-$$"
  local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" RETURN
  cat >"$tmp/run.sh" <<'EOF'
set -u
mc alias set local http://minio.minio.svc.cluster.local:9000 "$ROOT_USER" "$ROOT_PW" >/dev/null 2>&1
echo "===USERS==="
# filter к access_key APP-юзера (mc admin user list иногда возвращает доп. колонки)
mc admin user list local --json 2>/dev/null \
  | jq -c --arg ak "$ACCESS_KEY" 'select(.accessKey==$ak)' | sort
echo "===POLICY_USER==="
mc admin user info local "$ACCESS_KEY" --json 2>/dev/null | jq -c '{policyName, status}'
echo "===BUCKET_EXISTS==="
mc stat local/"$BUCKET" --json 2>/dev/null | jq -c '{name: (.url // "")}' || echo '{}'
echo "===BUCKET_VERSIONING==="
mc version info local/"$BUCKET" --json 2>/dev/null | jq -c '{status: (.versioning // .status // "off")}' || echo '{}'
echo "===BUCKET_QUOTA==="
mc admin bucket quota local/"$BUCKET" --json 2>/dev/null | jq -c '{quota: (.quota // 0), type: (.quotatype // "none")}' || echo '{}'
echo "===BUCKET_ANONYMOUS==="
mc anonymous get local/"$BUCKET" 2>/dev/null || echo "none"
echo "===POLICY_INFO==="
# policy объекта совпадает с именем bucket в minio-app-create (minio/Makefile:101+)
mc admin policy info local "minio-$ACCESS_KEY" --json 2>/dev/null | jq -c '{policy: .policyName, statements: (.policy.Statement | length // 0)}' || echo '{}'
echo "===BUCKET_DU==="
mc du local/"$BUCKET" --json 2>/dev/null | jq -c '{objects, size}' || echo '{}'
EOF
  local raw
  raw=$(kubectl --kubeconfig "$KUBECONFIG_FILE" -n minio run "$helper" \
    --restart=Never --image=quay.io/minio/mc:latest --rm -i --quiet \
    --env="ROOT_USER=$root_user" --env="ROOT_PW=$root_pw" \
    --env="ACCESS_KEY=$access_key" --env="BUCKET=$bucket" \
    --command -- sh -ec "$(cat "$tmp/run.sh")" 2>/dev/null || true)
  if [ -z "$raw" ]; then
    jq -n --arg ak "$access_key" '{status:"absent",access_key:$ak,error:"kubectl run mc helper failed"}'
    return 0
  fi
  extract_section() { echo "$raw" | awk -v s="===$1===" '$0==s{f=1;next} /^===/{f=0} f'; }
  local user_info policy_user bucket_exists versioning quota anonymous policy_info bucket_du
  user_info=$(extract_section USERS)
  policy_user=$(extract_section POLICY_USER)
  bucket_exists=$(extract_section BUCKET_EXISTS)
  versioning=$(extract_section BUCKET_VERSIONING)
  quota=$(extract_section BUCKET_QUOTA)
  anonymous=$(extract_section BUCKET_ANONYMOUS)
  policy_info=$(extract_section POLICY_INFO)
  bucket_du=$(extract_section BUCKET_DU)
  # anonymous parsing: `mc anonymous get` возвращает "Access permission for '...' is 'none'".
  # Раньше делали `tr -d '[:space:]'` — выходила бессмыслица. Берём последнее single-quoted
  # значение через awk (-F\').
  local anon_value
  anon_value=$(echo "$anonymous" | awk -F\' 'NF>=4 {print $(NF-1); exit} END{if(!NR) print "none"}')
  [ -n "$anon_value" ] || anon_value="none"
  # Безопасная сериализация через sanitize_json: на невалидном/multiline JSON → null
  # вместо падения jq --argjson (приводило к пустому fp_minio).
  jq -n \
    --arg ak "$access_key" \
    --arg bucket "$bucket" \
    --argjson user_info "$(sanitize_json user_info "$user_info")" \
    --argjson policy_user "$(sanitize_json policy_user "$policy_user")" \
    --argjson versioning "$(sanitize_json versioning "$versioning")" \
    --argjson quota "$(sanitize_json quota "$quota")" \
    --arg anonymous "$anon_value" \
    --argjson policy_info "$(sanitize_json policy_info "$policy_info")" \
    --argjson bucket_du "$(sanitize_json bucket_du "$bucket_du")" \
    '{
      status: "ok",
      structural: {
        access_key:$ak, bucket:$bucket,
        user_info:$user_info, policy_user:$policy_user,
        versioning:$versioning, quota:$quota,
        anonymous:$anonymous, policy_info:$policy_info
      },
      informational: {bucket_du:$bucket_du}
    }'
}

# --- ClickHouse -------------------------------------------------------------
# admin: Secret clickhouse/clickhouse.admin-password. user=default.
fp_clickhouse() {
  if ! cfg_get clickhouse.password >/dev/null; then
    jq -n '{status:"skipped",reason:"clickhouse.password не задан"}'
    return 0
  fi
  local db; db=$(cfg_get clickhouse.database || echo "$APP")
  local user="app_$APP"
  local pod
  pod=$(kubectl --kubeconfig "$KUBECONFIG_FILE" -n clickhouse get pods \
    -l app.kubernetes.io/name=clickhouse -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -z "$pod" ]; then
    jq -n --arg db "$db" '{status:"absent",database:$db,error:"clickhouse pod not found"}'
    return 0
  fi
  local pw
  pw=$(kubectl --kubeconfig "$KUBECONFIG_FILE" -n clickhouse get secret clickhouse \
    -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true)
  if [ -z "$pw" ]; then
    jq -n --arg db "$db" '{status:"absent",database:$db,error:"admin secret missing"}'
    return 0
  fi
  ch_exec() {
    kubectl --kubeconfig "$KUBECONFIG_FILE" -n clickhouse exec -i "$pod" -- \
      clickhouse-client --user=default --password="$pw" --query="$1" 2>/dev/null || true
  }
  local tables grants schema_hash="" tmp_schema
  tables=$(ch_exec "SELECT name FROM system.tables WHERE database='$db' ORDER BY name FORMAT TabSeparated")
  grants=$(ch_exec "SHOW GRANTS FOR \`$user\` FORMAT TabSeparated")
  # schema_hash через temp file + size check (см. fp_postgres коммент выше про пустой sha256).
  tmp_schema=$(mktemp)
  ch_exec "SELECT create_table_query FROM system.tables WHERE database='$db' ORDER BY name FORMAT TabSeparated" \
    > "$tmp_schema" 2>/dev/null
  if [ -s "$tmp_schema" ]; then
    schema_hash=$(sha256sum "$tmp_schema" | awk '{print $1}')
  fi
  rm -f "$tmp_schema"
  local tables_json grants_json counts_json="{}"
  tables_json=$(printf '%s\n' "$tables" | jarr_lines)
  grants_json=$(printf '%s\n' "$grants" | jarr_lines)
  if [ -n "$tables" ]; then
    local cnt_lines
    cnt_lines=$(while IFS= read -r t; do
      [ -n "$t" ] || continue
      n=$(ch_exec "SELECT count() FROM \`$db\`.\`$t\` FORMAT TabSeparated" | tr -d '[:space:]')
      printf '%s\t%s\n' "$t" "${n:-0}"
    done <<<"$tables")
    counts_json=$(echo "$cnt_lines" | jq -Rn '[inputs | split("\t") | select(length==2) | {(.[0]):(.[1]|tonumber? // 0)}] | add // {}')
  fi
  jq -n \
    --arg db "$db" --arg user "$user" \
    --argjson tables "$tables_json" \
    --argjson grants "$grants_json" \
    --arg schema_hash "$schema_hash" \
    --argjson counts "$counts_json" \
    '{
      status: "ok",
      structural: {database:$db, user:$user, tables:$tables, grants:$grants, schema_hash:$schema_hash},
      informational: {row_counts:$counts}
    }'
}

# --- RabbitMQ ---------------------------------------------------------------
# admin: Secret rabbitmq/rabbitmq.rabbitmq-password (user=user).
# Используем rabbitmqctl на pod-е для получения filtered definitions.
fp_rabbitmq() {
  if ! cfg_get rabbitmq.password >/dev/null; then
    jq -n '{status:"skipped",reason:"rabbitmq.password не задан"}'
    return 0
  fi
  local vhost; vhost=$(cfg_get rabbitmq.vhost || echo "$APP")
  local user="app_$APP"
  local pod
  pod=$(kubectl --kubeconfig "$KUBECONFIG_FILE" -n rabbitmq get pods \
    -l app.kubernetes.io/name=rabbitmq -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -z "$pod" ]; then
    jq -n --arg vhost "$vhost" '{status:"absent",vhost:$vhost,error:"rabbitmq pod not found"}'
    return 0
  fi
  rmq_exec() {
    kubectl --kubeconfig "$KUBECONFIG_FILE" -n rabbitmq exec -i "$pod" -- "$@" 2>/dev/null || true
  }
  # Полный export_definitions, потом фильтруем по vhost через jq.
  local defs
  defs=$(rmq_exec rabbitmqctl export_definitions /dev/stdout --silent)
  if [ -z "$defs" ] || ! echo "$defs" | jq empty 2>/dev/null; then
    jq -n --arg vhost "$vhost" '{status:"absent",vhost:$vhost,error:"export_definitions failed"}'
    return 0
  fi
  local filtered
  filtered=$(echo "$defs" | jq --arg v "$vhost" --arg u "$user" '{
    vhost_exists: (any(.vhosts[]?; .name == $v)),
    user_exists:  (any(.users[]?;  .name == $u)),
    user_permissions: ([.permissions[]? | select(.user == $u and .vhost == $v) | {configure,write,read}] | first // null),
    queues:    ([.queues[]?    | select(.vhost == $v) | {name, durable, auto_delete, arguments}] | sort_by(.name)),
    exchanges: ([.exchanges[]? | select(.vhost == $v and .name != "") | {name, type, durable, auto_delete, arguments}] | sort_by(.name)),
    bindings:  ([.bindings[]?  | select(.vhost == $v) | {source, destination, destination_type, routing_key, arguments}] | sort_by(.source, .destination, .routing_key)),
    policies:  ([.policies[]?  | select(.vhost == $v) | {name, pattern, "apply-to", definition, priority}] | sort_by(.name))
  }')
  # Queue depth (informational).
  local depth_json="{}"
  local q_raw
  q_raw=$(rmq_exec rabbitmqctl list_queues -p "$vhost" name messages_ready messages_unacknowledged --no-table-headers)
  if [ -n "$q_raw" ]; then
    depth_json=$(echo "$q_raw" | jq -Rn '
      [inputs | split("\t") | select(length>=3) | {(.[0]): {ready:(.[1]|tonumber? // 0), unack:(.[2]|tonumber? // 0)}}]
      | add // {}')
  fi
  jq -n \
    --arg vhost "$vhost" --arg user "$user" \
    --argjson struct "$filtered" \
    --argjson depth "$depth_json" \
    '{
      status: "ok",
      structural: ({vhost:$vhost, user:$user} + $struct),
      informational: {queue_depth:$depth}
    }'
}

# -----------------------------------------------------------------------------
# Главный sweep: вызываем fp_<svc> для каждого сервиса из data-services.txt.
# -----------------------------------------------------------------------------
DATA_LIST="$REPO_ROOT/scripts/lib/data-services.txt"
[ -f "$DATA_LIST" ] || { err "✗ нет $DATA_LIST"; exit 1; }
mapfile -t SVCS < <(grep -v '^[[:space:]]*#' "$DATA_LIST" | sed '/^[[:space:]]*$/d' | sed 's/[[:space:]]//g')

declare -A RESULTS
for svc in "${SVCS[@]}"; do
  echo "  снимаю fingerprint: $svc"
  _result=""
  case "$svc" in
    postgres)    _result=$(fp_postgres) ;;
    redis)       _result=$(fp_redis) ;;
    kafka)       _result=$(fp_kafka) ;;
    minio)       _result=$(fp_minio) ;;
    clickhouse)  _result=$(fp_clickhouse) ;;
    rabbitmq)    _result=$(fp_rabbitmq) ;;
    *)           _result='{"status":"unknown"}' ;;
  esac
  # Защита от тихого fail: если функция вернула пусто или невалидный JSON
  # (т.к. set -uo pipefail без -e маскирует kubectl exec failures), фиксируем
  # это как error-status, а не делаем вид что fingerprint снят.
  if [ -z "$_result" ] || ! echo "$_result" | jq empty 2>/dev/null; then
    err "  ⚠ fp_${svc} вернул пустой/невалидный JSON — фиксирую status:error"
    RESULTS[$svc]='{"status":"error","error":"fp_'"$svc"' returned empty or invalid JSON"}'
  else
    RESULTS[$svc]="$_result"
  fi
done
unset _result

# Сборка итогового JSON.
TMP_JSON=$(mktemp)
{
  printf '{\n'
  printf '  "app": %s,\n' "$(jstr "$APP")"
  printf '  "env": %s,\n' "$(jstr "$ENV_NAME")"
  printf '  "role": %s,\n' "$(jstr "$ROLE")"
  printf '  "timestamp": %s,\n' "$(jstr "$TS")"
  printf '  "services": {\n'
  n=${#SVCS[@]}; i=0
  for svc in "${SVCS[@]}"; do
    i=$((i+1))
    body="${RESULTS[$svc]:-null}"
    if [ "$i" -lt "$n" ]; then
      printf '    %s: %s,\n' "$(jstr "$svc")" "$body"
    else
      printf '    %s: %s\n' "$(jstr "$svc")" "$body"
    fi
  done
  printf '  }\n'
  printf '}\n'
} >"$TMP_JSON"

# Финальная валидация JSON.
if ! jq empty <"$TMP_JSON" 2>/dev/null; then
  err "✗ итоговый fingerprint не валидный JSON (см. $TMP_JSON)"
  exit 1
fi

# Pretty-print.
jq . "$TMP_JSON" >"$OUT_FILE"
rm -f "$TMP_JSON"
chmod 600 "$OUT_FILE"
echo "✓ fingerprint: $OUT_FILE"

# Опциональное шифрование.
if [ -n "$BACKUP_AGE_RECIPIENT" ]; then
  if command -v age >/dev/null 2>&1; then
    if age -r "$BACKUP_AGE_RECIPIENT" -o "${OUT_FILE}.age" "$OUT_FILE"; then
      rm -f "$OUT_FILE"
      echo "✓ зашифровано: ${OUT_FILE}.age (recipient=$BACKUP_AGE_RECIPIENT)"
    else
      err "⚠ age failed; plain fingerprint сохранён: $OUT_FILE"
    fi
  else
    err "⚠ BACKUP_AGE_RECIPIENT задан, но age не найден; plain fingerprint: $OUT_FILE"
  fi
fi

exit 0
