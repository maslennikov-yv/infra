#!/bin/bash
# Run inside postgres pod. Uses env: ADMIN_PASSWORD, APP_USER, APP_DB, APP_PASSWORD
set -e
if [ -n "$ADMIN_PASSWORD" ]; then
  export PGPASSWORD="$ADMIN_PASSWORD"
else
  export PGPASSWORD=$(cat /opt/bitnami/postgresql/secrets/postgres-password 2>/dev/null | tr -d '\n')
fi
[ -z "$PGPASSWORD" ] && { echo "✗ Не удалось прочитать пароль postgres (задайте POSTGRES_ADMIN_PASSWORD=...)"; exit 1; }

psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "DO \$\$BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='$APP_USER') THEN CREATE ROLE \"$APP_USER\" LOGIN PASSWORD '$APP_PASSWORD'; END IF; END\$\$;"
psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "ALTER ROLE \"$APP_USER\" PASSWORD '$APP_PASSWORD';"
if ! psql -v ON_ERROR_STOP=1 -U postgres -d postgres -t -c "SELECT 1 FROM pg_database WHERE datname='$APP_DB'" | grep -q 1; then
  psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "CREATE DATABASE \"$APP_DB\" OWNER \"$APP_USER\";"
fi
psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "REVOKE CONNECT ON DATABASE postgres FROM \"$APP_USER\";"
psql -v ON_ERROR_STOP=1 -U postgres -d "$APP_DB" -c "REVOKE ALL ON SCHEMA public FROM PUBLIC; GRANT ALL ON SCHEMA public TO \"$APP_USER\";"
psql -v ON_ERROR_STOP=1 -U postgres -d "$APP_DB" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO \"$APP_USER\";"
psql -v ON_ERROR_STOP=1 -U postgres -d "$APP_DB" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO \"$APP_USER\";"
psql -v ON_ERROR_STOP=1 -U postgres -d "$APP_DB" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO \"$APP_USER\";"
psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "ALTER ROLE \"$APP_USER\" IN DATABASE \"$APP_DB\" SET search_path TO public;"
export PGPASSWORD="$APP_PASSWORD"
psql -v ON_ERROR_STOP=1 -U "$APP_USER" -d "$APP_DB" -c "SELECT 1" >/dev/null || { echo "✗ Проверка подключения не удалась"; exit 1; }
echo "✓ Проверка подключения успешна"
