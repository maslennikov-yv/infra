#!/usr/bin/env bash
# Объединяет YAML со stdin с apps/conf/<APP>/<ENV>/secrets.yaml (создаёт при необходимости).
# Использование: app-conf-set.sh <repo_root> <APP> <ENV> <stdin=yaml>
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/apps-yq-probe.sh
source "$DIR/apps-yq-probe.sh"

REPO="${1:?repo_root}"
APP="${2:?APP}"
ENV="${3:?env name}"

# Валидация APP — defence-in-depth от path-traversal через apps/conf/<APP>/<ENV>/secrets.yaml.
# Все стандартные вызовы (Makefile, configure-infra.mjs) проверяют APP до нас, но
# полагаться на это нельзя.
if ! [[ "$APP" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]]; then
	echo "✗ неверное имя APP: $APP (ожидается ^[a-z0-9][a-z0-9_-]{0,62}\$)" >&2
	exit 1
fi

secrets="$REPO/apps/conf/$APP/$ENV/secrets.yaml"
mkdir -p "$(dirname "$secrets")"

patch=$(mktemp)
trap 'rm -f "$patch" "$secrets".new' EXIT INT TERM
cat >"$patch"

if [[ ! -s "$secrets" ]]; then
	echo '{}' >"$secrets"
elif ! "$YQBIN" '.' "$secrets" >/dev/null 2>&1; then
	echo "✗ $secrets существует, но не валидный YAML — отказываюсь перезаписать (потеряли бы данные)." >&2
	echo "  Исправьте файл вручную или удалите его перед app-conf-set." >&2
	exit 1
fi

"$YQBIN" eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$secrets" "$patch" >"${secrets}.new"
mv "${secrets}.new" "$secrets"
rm -f "$patch"
