#!/usr/bin/env bash
# Печать аргументов --set для helm: app.volumes.enabled + app.volumes.hostPath на apps/src/<APP>.
# Использование из корня infra: ENV=local APP=<name> REPO_ROOT=<abs>
# Опционально: APPS_REGISTRY — если APP нет в registry, предупреждение в stderr, выход 0 (путь всё равно печатается).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

ENV="${ENV:?}"
if [[ "$ENV" != "local" ]]; then
	echo "✗ apps-local-src-helm-sets: только ENV=local (сейчас: $ENV)" >&2
	exit 1
fi

REPO="${REPO_ROOT:?}"
APP="${APP:?}"
REG="${APPS_REGISTRY:-$REPO/apps/registry.yaml}"

REPO_ABS=$(cd "$REPO" && pwd)
HOST_SRC=$(cd "$REPO_ABS" && realpath -m "apps/src/$APP")

if [[ ! $APP =~ ^[a-zA-Z0-9][-a-zA-Z0-9_]*$ ]]; then
	echo "✗ недопустимое имя APP" >&2
	exit 1
fi

if [[ -f "$REG" ]]; then
	yq_bin="${YQ:-yq}"
	if command -v "$yq_bin" >/dev/null 2>&1; then
		ver=$("$yq_bin" --version 2>&1 || true)
		if [[ "$ver" == *mikefarah* ]] || [[ "$ver" == *github.com/mikefarah* ]]; then
			hit=$(APP="$APP" "$yq_bin" -r '[.apps[] | select(.name == strenv(APP))] | length' "$REG" || echo 0)
			if [[ "${hit:-0}" == "0" ]]; then
				echo "⚠ APP=$APP не найден в $REG — путь всё равно печатается" >&2
			fi
		fi
	fi
fi

if [[ ! -d "$HOST_SRC" ]]; then
	echo "⚠ Каталог отсутствует: $HOST_SRC (проверьте clone или создайте перед deploy)" >&2
fi

escaped=${HOST_SRC//\\/\\\\}
escaped=${escaped//\"/\\\"}

printf '%s\n' "--set app.volumes.enabled=true --set app.volumes.hostPath=\"${escaped}\""
