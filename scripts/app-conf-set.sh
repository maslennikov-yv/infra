#!/usr/bin/env bash
# Объединяет YAML со stdin с apps/conf/<APP>/secrets.yaml (создаёт при необходимости).
# Использование: app-conf-set.sh <repo_root> <APP> <stdin=yaml>
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/apps-yq-probe.sh
source "$DIR/apps-yq-probe.sh"

REPO="${1:?repo_root}"
APP="${2:?APP}"

secrets="$REPO/apps/conf/$APP/secrets.yaml"
mkdir -p "$(dirname "$secrets")"

patch=$(mktemp)
trap 'rm -f "$patch" "$secrets".new' EXIT INT TERM
cat >"$patch"

if [[ ! -s "$secrets" ]]; then
	echo '{}' >"$secrets"
elif ! "$YQBIN" '.' "$secrets" >/dev/null 2>&1; then
	echo '{}' >"$secrets"
fi

"$YQBIN" eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$secrets" "$patch" >"${secrets}.new"
mv "${secrets}.new" "$secrets"
rm -f "$patch"
