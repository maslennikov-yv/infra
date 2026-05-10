#!/usr/bin/env bash
# Удаляет ветку top-level-ключа SERVICE из apps/conf/<APP>/secrets.yaml.
# SERVICE: postgres|redis|kafka|minio|clickhouse|rabbitmq
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/apps-yq-probe.sh
source "$DIR/apps-yq-probe.sh"

REPO="${1:?repo_root}"
APP="${2:?APP}"
SERVICE="${3:?service}"

# Валидация APP — defence-in-depth от path-traversal.
if ! [[ "$APP" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]]; then
	echo "✗ неверное имя APP: $APP (ожидается ^[a-z0-9][a-z0-9_-]{0,62}\$)" >&2
	exit 1
fi

case "$SERVICE" in
postgres | redis | kafka | minio | clickhouse | rabbitmq) ;;
*)
	echo "✗ Неизвестный сервис: $SERVICE" >&2
	exit 1
	;;
esac

secrets="$REPO/apps/conf/$APP/secrets.yaml"
[[ -f "$secrets" ]] || exit 0

"$YQBIN" eval "del(.${SERVICE})" -i "$secrets"
