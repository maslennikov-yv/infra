#!/usr/bin/env bash
# Готовит APP_SECRETS для контракта infra-interface v2:
#   - если apps/conf/<APP>/<ENV>/secrets.yaml существует — используем его напрямую;
#   - иначе если apps/conf/<APP>/<ENV>/secrets.enc.yaml — sops --decrypt в
#     apps/.tmp/<APP>-<ENV>.secrets.yaml (chmod 600);
#   - иначе пишем пустой YAML ({}) в apps/.tmp/<APP>-<ENV>.secrets.yaml.
#
# Поведение «plain > encrypted» сохранено (как в apps-merge-app.sh): если есть оба,
# берём plain — он считается «свежим» оверрайдом.
#
# Использование: app-render-values-prep.sh <REPO_ROOT> <APP> <ENV>
# stdout: абсолютный путь к подготовленному secrets.yaml.
set -euo pipefail

REPO="${1:?repo_root}"
APP="${2:?APP}"
ENV="${3:?env name}"

CONFDIR="$REPO/apps/conf/$APP/$ENV"
PLAIN="$CONFDIR/secrets.yaml"
ENC="$CONFDIR/secrets.enc.yaml"

TMPDIR="$REPO/apps/.tmp"
install -d -m 700 "$TMPDIR"

if [[ -f "$PLAIN" ]]; then
	echo "$PLAIN"
	exit 0
fi

if [[ -f "$ENC" ]]; then
	if ! command -v sops >/dev/null 2>&1; then
		echo "✗ $ENC зашифрован sops, но sops не установлен. См. docs/runbooks/secrets-management.md." >&2
		exit 1
	fi
	OUT="$TMPDIR/$APP-$ENV.secrets.yaml"
	tmp=$(mktemp --suffix=.yaml 2>/dev/null || mktemp)
	if ! sops --decrypt "$ENC" >"$tmp" 2>/dev/null; then
		rm -f "$tmp"
		echo "✗ Не удалось расшифровать $ENC. Проверьте SOPS_AGE_KEY_FILE и .sops.yaml." >&2
		exit 1
	fi
	mv "$tmp" "$OUT"
	chmod 600 "$OUT"
	echo "$OUT"
	exit 0
fi

# Ни plain, ни enc — пишем пустой YAML, чтобы шаблон не падал.
OUT="$TMPDIR/$APP-$ENV.secrets.yaml"
printf '{}\n' >"$OUT"
chmod 600 "$OUT"
echo "$OUT"
