#!/usr/bin/env bash
# Клонирование репозитория приложения в apps/src/<APP> (обычный clone, не submodule).
# Использование: apps-src-clone.sh <REPO_ROOT> <APP> <URL> [BRANCH]
# Exit: 0 — клон создан; 2 — каталог уже есть и это git-репозиторий; 3 — каталог есть, но не git; 1 — ошибка.
set -euo pipefail

REPO_ROOT="${1:?REPO_ROOT}"
APP="${2:?APP}"
URL="${3:?URL}"
BRANCH="${4:-}"

DEST="$REPO_ROOT/apps/src/$APP"

if [[ -e "$DEST" ]]; then
	if [[ -d "$DEST/.git" ]]; then
		echo "apps-src-clone: уже есть репозиторий: $DEST (exit 2)" >&2
		exit 2
	fi
	echo "apps-src-clone: путь занят, не git: $DEST (exit 3)" >&2
	exit 3
fi

mkdir -p "$(dirname "$DEST")"
if [[ -n "${BRANCH// /}" ]]; then
	git clone -b "$BRANCH" -- "$URL" "$DEST"
else
	git clone -- "$URL" "$DEST"
fi

echo "apps-src-clone: готово → $DEST"
