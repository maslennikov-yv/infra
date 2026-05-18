#!/usr/bin/env bash
# install.sh — устанавливает git hooks из scripts/git-hooks/ в .git/hooks/
# (симлинком, чтобы правки в репозитории сразу попадали в hook).
# Дополнительно: скачивает .tools/gitleaks при его отсутствии.
#
# Идемпотентно — повторный запуск переустанавливает симлинки и не ломает .tools/gitleaks.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

HOOKS_SRC="$REPO_ROOT/scripts/git-hooks"
HOOKS_DST="$(git rev-parse --git-path hooks)"
mkdir -p "$HOOKS_DST"

# 1) gitleaks: скачать в .tools/, если нет ни в PATH, ни в .tools/
if [ ! -x "$REPO_ROOT/.tools/gitleaks" ] && ! command -v gitleaks >/dev/null 2>&1; then
	arch=$(uname -m)
	case "$arch" in
		x86_64) gl_arch=x64 ;;
		aarch64|arm64) gl_arch=arm64 ;;
		*) echo "✗ неизвестная архитектура: $arch" >&2; exit 1 ;;
	esac
	ver=$(curl -fsSL https://api.github.com/repos/gitleaks/gitleaks/releases/latest \
		| grep -m1 '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')
	if [ -z "$ver" ]; then
		echo "✗ не удалось определить последнюю версию gitleaks" >&2
		exit 1
	fi
	echo "→ скачиваю gitleaks v${ver} (${gl_arch}) в .tools/ (gitignored)…"
	mkdir -p "$REPO_ROOT/.tools"
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT
	curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${ver}/gitleaks_${ver}_linux_${gl_arch}.tar.gz" \
		-o "$tmp/gitleaks.tgz"
	tar -xzf "$tmp/gitleaks.tgz" -C "$tmp" gitleaks
	mv "$tmp/gitleaks" "$REPO_ROOT/.tools/gitleaks"
	chmod +x "$REPO_ROOT/.tools/gitleaks"
	echo "  ✓ .tools/gitleaks ($(.tools/gitleaks version))"
else
	if [ -x "$REPO_ROOT/.tools/gitleaks" ]; then
		echo "→ gitleaks: уже в .tools/ ($("$REPO_ROOT/.tools/gitleaks" version))"
	else
		echo "→ gitleaks: уже в PATH ($(gitleaks version))"
	fi
fi

# 2) hooks → симлинками
for hook in pre-commit; do
	src="$HOOKS_SRC/$hook"
	dst="$HOOKS_DST/$hook"
	if [ ! -f "$src" ]; then
		echo "  skip: $src отсутствует"
		continue
	fi
	chmod +x "$src"
	# rm -f не падает, если $dst нет — снимает старый файл/симлинк перед установкой.
	rm -f "$dst"
	# Относительный путь от .git/hooks/ до scripts/git-hooks/<hook> —
	# симлинк выдерживает перемещение репозитория.
	rel="$(realpath --relative-to="$HOOKS_DST" "$src")"
	ln -s "$rel" "$dst"
	echo "  ✓ $hook → $rel"
done

echo ""
echo "✓ Git hooks установлены."
echo "  Проверка hook'а — поставьте в коммит реалистично-выглядящий секрет"
echo "  (например GitHub PAT формата 'ghp_' + 36 алфавитно-цифровых),"
echo "  hook должен заблокировать."
echo "  Обход (на свой риск):  SKIP_GITLEAKS=1 git commit ...   |   git commit --no-verify"
