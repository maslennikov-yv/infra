#!/bin/bash
# Run inside postgres pod. Uses env: ADMIN_PASSWORD, APP_USER, APP_DB, APP_PASSWORD.
# Запускайте через `make app-create` / `make pg-app-create` — Makefile сам
# подбирает ADMIN_PASSWORD (override → файл в поде → kubectl get secret).
set -eu
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD не передан, вызывайте через make app-create / pg-app-create}"
: "${APP_USER:?}" "${APP_DB:?}" "${APP_PASSWORD:?}"
export PGPASSWORD="$ADMIN_PASSWORD"

# psql-переменные: :'var' подставляется как SQL-литерал (с экранированием
# одиночных кавычек), :"var" — как SQL-идентификатор. Это даёт безопасную
# подстановку имён ролей/БД и пароля для произвольных значений.

psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
  -v app_user="$APP_USER" -v app_password="$APP_PASSWORD" \
  -c "DO \$\$BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user') THEN EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password'); END IF; END\$\$;"

psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
  -v app_user="$APP_USER" -v app_password="$APP_PASSWORD" \
  -c "ALTER ROLE :\"app_user\" PASSWORD :'app_password';"

if ! psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
       -v app_db="$APP_DB" \
       -tAc "SELECT 1 FROM pg_database WHERE datname = :'app_db'" | grep -q 1; then
  psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -v app_db="$APP_DB" -v app_user="$APP_USER" \
    -c "CREATE DATABASE :\"app_db\" OWNER :\"app_user\";"
fi

psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
  -v app_user="$APP_USER" \
  -c "REVOKE CONNECT ON DATABASE postgres FROM :\"app_user\";"

psql -v ON_ERROR_STOP=1 -U postgres -d "$APP_DB" \
  -v app_user="$APP_USER" \
  -c "REVOKE ALL ON SCHEMA public FROM PUBLIC; GRANT ALL ON SCHEMA public TO :\"app_user\";"

psql -v ON_ERROR_STOP=1 -U postgres -d "$APP_DB" \
  -v app_user="$APP_USER" \
  -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO :\"app_user\";"

psql -v ON_ERROR_STOP=1 -U postgres -d "$APP_DB" \
  -v app_user="$APP_USER" \
  -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO :\"app_user\";"

psql -v ON_ERROR_STOP=1 -U postgres -d "$APP_DB" \
  -v app_user="$APP_USER" \
  -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO :\"app_user\";"

psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
  -v app_user="$APP_USER" -v app_db="$APP_DB" \
  -c "ALTER ROLE :\"app_user\" IN DATABASE :\"app_db\" SET search_path TO public;"

export PGPASSWORD="$APP_PASSWORD"
psql -v ON_ERROR_STOP=1 -U "$APP_USER" -d "$APP_DB" -c "SELECT 1" >/dev/null \
  || { echo "✗ Проверка подключения не удалась"; exit 1; }
echo "✓ Проверка подключения успешна"
