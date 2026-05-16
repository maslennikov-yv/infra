#!/usr/bin/env bash
# check-tools.sh — проверка минимальных версий тулинга для работы репозитория.
#
# Назначение: при первой развёртке на новой машине быстро понять, чего не хватает.
# Минимумы — по факту используемых фич; если завышено — поправьте здесь, не в коде Makefile.
#
# Args (env):
#   YQ — путь к mikefarah/yq, по умолчанию "yq".
#
# Stdout: таблица «инструмент / найдено / минимум / OK|≥|<|—».
# Exit:
#   0 — все обязательные инструменты ок (или выше минимума).
#   1 — хотя бы один отсутствует или ниже минимума.

set -uo pipefail
# Без -e: ниже мы намеренно проверяем `command -v` через if + продолжаем после
# отсутствующих инструментов (показываем «—» в таблице, а не падаем).

YQ_BIN="${YQ:-yq}"
GOMPLATE_BIN="${GOMPLATE:-gomplate}"

# Инструкции установки для Ubuntu (показываются только для упавших инструментов).
declare -A INSTALL_HINTS
INSTALL_HINTS=(
	[kubectl]="sudo snap install kubectl --classic"
	[helm]="sudo snap install helm --classic"
	[helmfile]="# нет snap/apt; актуальную версию см. https://github.com/helmfile/helmfile/releases
VER=0.169.2
curl -Lo /usr/local/bin/helmfile \"https://github.com/helmfile/helmfile/releases/download/v\${VER}/helmfile_\${VER}_linux_amd64\"
chmod +x /usr/local/bin/helmfile"
	[yq]="sudo snap install yq   # mikefarah/yq v4
# или бинарь: https://github.com/mikefarah/yq/releases"
	[jq]="sudo apt-get install -y jq"
	[openssl]="sudo apt-get install -y openssl"
	[docker]="sudo snap install docker
# или: https://docs.docker.com/engine/install/ubuntu/"
	[bash]="sudo apt-get install --reinstall bash"
	[tar]="sudo apt-get install -y tar"
	[gzip]="sudo apt-get install -y gzip"
	[node]="sudo snap install node --classic --channel=lts
# или: https://nodejs.org/en/download/package-manager"
	[sops]="# актуальную версию см. https://github.com/getsops/sops/releases
VER=3.9.4
curl -Lo /usr/local/bin/sops \"https://github.com/getsops/sops/releases/download/v\${VER}/sops-v\${VER}.linux.amd64\"
chmod +x /usr/local/bin/sops"
	[age]="sudo apt-get install -y age   # Ubuntu 22.04+
# или бинарь: https://github.com/FiloSottile/age/releases"
	[gomplate]="# актуальную версию см. https://github.com/hairyhenderson/gomplate/releases
VER=4.3.0
curl -Lo /usr/local/bin/gomplate \"https://github.com/hairyhenderson/gomplate/releases/download/v\${VER}/gomplate_linux-amd64\"
chmod +x /usr/local/bin/gomplate"
)

FAILED_TOOLS=()

# tool, min_version, optional ("0"|"1"), how_to_check
# Минимумы выбраны под текущий код:
#   helmfile 0.165 — поддержка `set` и `--quiet` опций используемых в helmfile.yaml.gotmpl.
#   kubectl 1.28 — стабильный --field-selector + apply.
#   helm 3.14 — стабильный --output json и helm template.
#   yq 4.40 — strenv() стабилен; eval-all для apps-merge-config.
#   jq 1.6 — для k8s-port-expose-* и top-totals.
#   docker — любой (для images-* и kubectl run).
#   openssl — любой (для генерации паролей в make up).
#   bash 4 — ассоциативные массивы в env-restore.sh / k8s-port-expose-apply-config.sh diff.
#   tar/gzip — стандарт.
#
# (имя | минимальная версия | обязательность 0/1 | команда вывода версии)
TOOLS=(
	"kubectl|1.28.0|1|kubectl version --client --output=yaml"
	"helm|3.14.0|1|helm version --short"
	"helmfile|0.165.0|1|helmfile --version"
	"yq|4.40.0|1|$YQ_BIN --version"
	"jq|1.6|1|jq --version"
	"openssl|0|1|openssl version"
	"docker|0|0|docker --version"
	"bash|4.0|1|bash --version"
	"tar|0|0|tar --version"
	"gzip|0|0|gzip --version"
	"node|18.0|0|node --version"
	"sops|3.7|0|sops --version"
	"age|0|0|age --version"
	"gomplate|4.0|0|$GOMPLATE_BIN --version"
)

# Извлекает первое X.Y.Z из строки. Возвращает пустую строку, если не нашёл.
# `|| echo "0"` после `head -1` не сработал бы: head на пустом stdin завершается
# с 0, и `||` не триггерится. Empty-результат ловится в caller через
# `[ -z "$ver" ] && ver="?"`.
extract_version() {
	local s="$1"
	echo "$s" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

# Сравнение версий: "1.2.3" >= "1.2.0" → true (0). Использует sort -V.
ver_ge() {
	local a="$1" b="$2"
	# "0" значит «без минимума» — всегда true.
	[ "$b" = "0" ] && return 0
	if [ -z "$a" ] || [ "$a" = "0" ]; then return 1; fi
	# sort -V: первый — меньший. Если a == b — оба пройдут. Если a < b — first будет a.
	local first
	first=$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)
	[ "$first" = "$b" ]
}

color() {
	local mark="$1"
	case "$mark" in
		OK) printf '\033[0;32m%s\033[0m' "$mark" ;;
		'<') printf '\033[0;31m%s\033[0m' "$mark" ;;
		'—') printf '\033[0;90m%s\033[0m' "$mark" ;;
		*) printf '%s' "$mark" ;;
	esac
}

printf '%-12s  %-15s  %-10s  %s\n' "Tool" "Found" "Min" "Status"
printf '%-12s  %-15s  %-10s  %s\n' "----" "-----" "---" "------"

FAIL=0
for entry in "${TOOLS[@]}"; do
	IFS='|' read -r tool min req cmd <<<"$entry"
	# Поиск бинаря: учитываем YQ переменную (может быть путь, не "yq").
	bin="$tool"
	[ "$tool" = "yq" ] && bin="$YQ_BIN"
	[ "$tool" = "gomplate" ] && bin="$GOMPLATE_BIN"
	if ! command -v "$bin" >/dev/null 2>&1 && [ ! -x "$bin" ]; then
		mark="—"
		FAILED_TOOLS+=("$tool")
		[ "$req" = "1" ] && { mark="<"; FAIL=$((FAIL + 1)); }
		printf '%-12s  %-15s  %-10s  %s\n' "$tool" "(не найден)" "$min" "$(color "$mark") $([ "$req" = "1" ] && echo "(обязательно)" || echo "(опционально)")"
		continue
	fi
	# Получим версию (читаем больше строк — у kubectl gitVersion ниже первых трёх).
	# Разбиваем команду на массив и выполняем без eval/`bash -c` —
	# в TOOLS нет кавычек/пайпов/переменных, простой split по пробелам корректен.
	read -ra args <<<"$cmd"
	out=$("${args[@]}" 2>&1 | head -20 | tr '\n' ' ')
	ver=$(extract_version "$out")
	[ -z "$ver" ] && ver="?"
	if ver_ge "$ver" "$min"; then
		mark="OK"
	else
		mark="<"
		FAILED_TOOLS+=("$tool")
		[ "$req" = "1" ] && FAIL=$((FAIL + 1))
	fi
	printf '%-12s  %-15s  %-10s  %s\n' "$tool" "$ver" "${min:-—}" "$(color "$mark")"
done

echo ""
if [ "${#FAILED_TOOLS[@]}" -gt 0 ]; then
	echo "Как установить (Ubuntu):"
	for t in "${FAILED_TOOLS[@]}"; do
		hint="${INSTALL_HINTS[$t]:-# см. документацию проекта}"
		echo "  ${t}:"
		echo "$hint" | sed 's/^/    /'
	done
	echo ""
fi
if [ "$FAIL" -gt 0 ]; then
	echo "✗ Не хватает $FAIL обязательных инструмент(а/ов) — установите/обновите перед make up."
	exit 1
fi
echo "✓ Все обязательные инструменты ок."
exit 0
