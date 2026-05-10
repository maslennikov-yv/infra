#!/usr/bin/env bash
# Применить локальный YAML с пробросами TCP (microk8s ingress): hostPort + TCP ConfigMap.
# Вызывается из k8s-port-expose/Makefile (apply-config). Нужны kubectl, jq, mikefarah yq v4.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:?задайте REPO_ROOT}"
ENV="${ENV:-local}"
PORT_EXPOSE_CONFIG="${PORT_EXPOSE_CONFIG:-}"
YQBIN="${YQ:-yq}"

if [[ -z "${PORT_EXPOSE_CONFIG}" ]]; then
	PORT_EXPOSE_CONFIG="${REPO_ROOT}/k8s-port-expose/ports-${ENV}.yaml"
fi

if [[ ! -f "${PORT_EXPOSE_CONFIG}" ]]; then
	echo "✗ файл конфигурации не найден: ${PORT_EXPOSE_CONFIG}" >&2
	exit 1
fi

CFG="${PORT_EXPOSE_CONFIG}"

if ! command -v kubectl >/dev/null 2>&1; then
	echo "✗ kubectl не найден" >&2
	exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
	echo "✗ jq не найден" >&2
	exit 1
fi
if ! command -v "${YQBIN}" >/dev/null 2>&1 && [[ ! -x "${YQBIN}" ]]; then
	echo "✗ yq не найден (ожидается mikefarah/yq v4; переменная YQ)" >&2
	exit 1
fi

INGRESS_NS="${INGRESS_NS:-ingress}"
INGRESS_DS="${INGRESS_DS:-nginx-ingress-microk8s-controller}"
INGRESS_TCP_CM="${INGRESS_TCP_CM:-nginx-ingress-tcp-microk8s-conf}"
INGRESS_CONTAINER="${INGRESS_CONTAINER:-nginx-ingress-microk8s}"

merge_ingress_from_yaml() {
	# Передаём fallback через env-var: mikefarah/yq НЕ поддерживает --arg (это синтаксис jq);
	# strenv(E) обращается к environment, а не к yq-переменной — раньше было два бага:
	# 1) yq падал с `unknown flag: --arg`; 2) даже если бы --arg работал, strenv(E)
	# всё равно смотрел бы в env, а не в yq-scope. Теперь правильно: E=... yq '... // strenv(E)'.
	INGRESS_NS="$(E="${INGRESS_NS}" "${YQBIN}" '.ingressNamespace // strenv(E)' "${CFG}")"
	INGRESS_DS="$(E="${INGRESS_DS}" "${YQBIN}" '.daemonSet // strenv(E)' "${CFG}")"
	INGRESS_TCP_CM="$(E="${INGRESS_TCP_CM}" "${YQBIN}" '.tcpConfigMap // strenv(E)' "${CFG}")"
	INGRESS_CONTAINER="$(E="${INGRESS_CONTAINER}" "${YQBIN}" '.containerName // strenv(E)' "${CFG}")"
}

merge_ingress_from_yaml

# `(.exposes // []) | length` всегда возвращает число (0 если ключ отсутствует),
# поэтому `[[ -z "$n" ]] || [[ "$n" == "null" ]]` — недостижимая ветка.
# Отдельно ругаемся на «ключ отсутствует» vs «массив пустой» — оператору яснее.
has_exposes="$("${YQBIN}" 'has("exposes")' "${CFG}")"
n="$("${YQBIN}" '(.exposes // []) | length' "${CFG}")"
if [[ "${has_exposes}" != "true" ]]; then
	echo "✗ в ${CFG} нет ключа exposes — нечего применять" >&2
	exit 1
fi
if (( n < 1 )); then
	echo "✗ в ${CFG} массив exposes пустой — нечего применять" >&2
	exit 1
fi

DRY_RUN="${DRY_RUN:-}"
MODE="${MODE:-apply}"

if [[ "$MODE" != "apply" && "$MODE" != "diff" ]]; then
	echo "✗ MODE должен быть apply или diff (сейчас: $MODE)" >&2
	exit 1
fi

if [[ "$MODE" == "diff" ]]; then
	echo "=== k8s-port-expose diff: ${CFG} vs live (${INGRESS_NS}/${INGRESS_DS}) ==="

	# Прочитаем желаемое состояние из YAML в ассоциативные массивы.
	declare -A WANT_BACKEND  # hp -> backend
	for ((i = 0; i < n; i++)); do
		hp_w="$("${YQBIN}" ".exposes[${i}].hostPort" "${CFG}")"
		be_w="$("${YQBIN}" ".exposes[${i}].backend" "${CFG}")"
		[[ "$hp_w" == "null" || -z "${hp_w// }" ]] && continue
		[[ "$be_w" == "null" || -z "${be_w// }" ]] && continue
		WANT_BACKEND["$hp_w"]="$be_w"
	done

	# Live состояние.
	if ! DS_JSON_DIFF=$(kubectl get daemonset "${INGRESS_DS}" -n "${INGRESS_NS}" -o json 2>/dev/null); then
		echo "✗ DaemonSet ${INGRESS_NS}/${INGRESS_DS} недоступен" >&2
		exit 1
	fi
	if ! CM_JSON_DIFF=$(kubectl get configmap "${INGRESS_TCP_CM}" -n "${INGRESS_NS}" -o json 2>/dev/null); then
		CM_JSON_DIFF='{"data":{}}'
	fi

	CI_DIFF=$(echo "$DS_JSON_DIFF" | jq -r --arg cn "${INGRESS_CONTAINER}" '(.spec.template.spec.containers | map(.name) | index($cn)) // empty')
	if [[ -z "$CI_DIFF" ]]; then
		echo "✗ контейнер \"${INGRESS_CONTAINER}\" не найден в DaemonSet/${INGRESS_DS}" >&2
		exit 1
	fi

	# Live hostPorts (только TCP/UDP/SCTP-порты, но контейнер может иметь и другие сервисные).
	mapfile -t LIVE_HP < <(echo "$DS_JSON_DIFF" | jq -r --argjson ci "$CI_DIFF" '.spec.template.spec.containers[$ci].ports[]? | select(.hostPort != null) | (.hostPort|tostring)')

	# Live ConfigMap mappings: "<port>=<backend>"
	mapfile -t LIVE_CM_KV < <(echo "$CM_JSON_DIFF" | jq -r '(.data // {}) | to_entries[] | "\(.key)=\(.value)"')

	declare -A LIVE_HP_SET=()
	for hp_l in "${LIVE_HP[@]}"; do LIVE_HP_SET["$hp_l"]=1; done
	declare -A LIVE_CM_MAP=()
	for kv in "${LIVE_CM_KV[@]}"; do
		[[ -z "$kv" ]] && continue
		LIVE_CM_MAP["${kv%%=*}"]="${kv#*=}"
	done

	echo ""
	echo "== DaemonSet hostPorts =="
	# Желаемые порты (sort по числу для предсказуемого вывода).
	for hp_w in $(printf "%s\n" "${!WANT_BACKEND[@]}" | sort -n); do
		if [[ -n "${LIVE_HP_SET[$hp_w]:-}" ]]; then
			echo "  = hostPort $hp_w"
		else
			echo "  + hostPort $hp_w (отсутствует у контейнера ${INGRESS_CONTAINER})"
		fi
	done
	# Live порты, не описанные в YAML.
	for hp_l in $(printf "%s\n" "${!LIVE_HP_SET[@]}" | sort -n); do
		if [[ -z "${WANT_BACKEND[$hp_l]:-}" ]]; then
			echo "  - hostPort $hp_l (есть в DaemonSet, нет в YAML; apply-config не удаляет — действуйте через make k8s-port-expose-patch LAYER=hostport OP=rm)"
		fi
	done

	echo ""
	echo "== TCP ConfigMap (${INGRESS_TCP_CM}) =="
	for hp_w in $(printf "%s\n" "${!WANT_BACKEND[@]}" | sort -n); do
		want_be="${WANT_BACKEND[$hp_w]}"
		live_be="${LIVE_CM_MAP[$hp_w]:-}"
		if [[ -z "$live_be" ]]; then
			echo "  + ${hp_w} → ${want_be} (отсутствует в ConfigMap)"
		elif [[ "$live_be" != "$want_be" ]]; then
			echo "  ~ ${hp_w}: ${live_be} → ${want_be}"
		else
			echo "  = ${hp_w} → ${want_be}"
		fi
	done
	for hp_l in $(printf "%s\n" "${!LIVE_CM_MAP[@]}" | sort -n); do
		if [[ -z "${WANT_BACKEND[$hp_l]:-}" ]]; then
			echo "  - ${hp_l} → ${LIVE_CM_MAP[$hp_l]} (есть в ConfigMap, нет в YAML; apply-config не удаляет — make k8s-port-expose-patch LAYER=tcp HOST_PORT=$hp_l RM=1)"
		fi
	done

	echo ""
	echo "✓ diff готов"
	exit 0
fi

if [[ -n "${DRY_RUN}" ]]; then
	printf '%b\n' "\033[0;33m↳ dry-run=${DRY_RUN}\033[0m"
fi

mk_patch_hostport() {
	make -C "${REPO_ROOT}/k8s-port-expose" patch-hostport \
		INGRESS_NS="${INGRESS_NS}" \
		INGRESS_DS="${INGRESS_DS}" \
		INGRESS_TCP_CM="${INGRESS_TCP_CM}" \
		INGRESS_CONTAINER="${INGRESS_CONTAINER}" \
		DRY_RUN="${DRY_RUN}" \
		"$@"
}

mk_patch_tcp() {
	make -C "${REPO_ROOT}/k8s-port-expose" patch-tcp \
		INGRESS_NS="${INGRESS_NS}" \
		INGRESS_DS="${INGRESS_DS}" \
		INGRESS_TCP_CM="${INGRESS_TCP_CM}" \
		INGRESS_CONTAINER="${INGRESS_CONTAINER}" \
		DRY_RUN="${DRY_RUN}" \
		"$@"
}

hostport_already_present() {
	local hp="$1"
	local DS_JSON CI NHP
	DS_JSON="$(kubectl get daemonset "${INGRESS_DS}" -n "${INGRESS_NS}" -o json)"
	CI="$(echo "${DS_JSON}" | jq -r --arg cn "${INGRESS_CONTAINER}" '(.spec.template.spec.containers | map(.name) | index($cn)) // empty')"
	if [[ -z "${CI}" ]]; then
		echo "✗ контейнер \"${INGRESS_CONTAINER}\" не найден в DaemonSet/${INGRESS_DS}" >&2
		exit 1
	fi
	NHP="$(echo "${DS_JSON}" | jq --argjson ci "${CI}" --argjson hp "${hp}" '[.spec.template.spec.containers[$ci].ports[]? | select(.hostPort == $hp)] | length')"
	[[ "${NHP}" != "0" ]]
}

echo "=== k8s-port-expose apply-config: ${CFG} (${INGRESS_NS}/${INGRESS_DS}) ==="

for ((i = 0; i < n; i++)); do
	hp="$("${YQBIN}" ".exposes[${i}].hostPort" "${CFG}")"
	be="$("${YQBIN}" ".exposes[${i}].backend" "${CFG}")"
	cp="$("${YQBIN}" ".exposes[${i}].containerPort" "${CFG}")"
	pn="$("${YQBIN}" ".exposes[${i}].portName" "${CFG}")"
	proto="$("${YQBIN}" ".exposes[${i}].proto // \"TCP\"" "${CFG}")"

	if [[ "${hp}" == "null" || -z "${hp// }" ]]; then
		echo "✗ exposes[${i}].hostPort обязателен" >&2
		exit 1
	fi
	if [[ "${be}" == "null" || -z "${be// }" ]]; then
		echo "✗ exposes[${i}].backend обязателен (формат ns/svc:port)" >&2
		exit 1
	fi
	if [[ "${cp}" == "null" || -z "${cp// }" ]]; then
		cp="${hp}"
	fi
	if [[ "${pn}" == "null" || -z "${pn// }" ]]; then
		pn="tcp-${hp}"
	fi

	echo "--- [${i}] hostPort=${hp} backend=${be} ---"
	if hostport_already_present "${hp}"; then
		echo "    пропуск hostPort=${hp} (уже есть у контейнера)"
	else
		mk_patch_hostport OP=add HOST_PORT="${hp}" CONTAINER_PORT="${cp}" PORT_NAME="${pn}" PROTO="${proto}"
	fi
done

for ((i = 0; i < n; i++)); do
	hp="$("${YQBIN}" ".exposes[${i}].hostPort" "${CFG}")"
	be="$("${YQBIN}" ".exposes[${i}].backend" "${CFG}")"
	echo "--- [${i}] tcp ConfigMap ← ${be} (узловой порт ${hp}) ---"
	mk_patch_tcp HOST_PORT="${hp}" BACKEND="${be}"
done

echo "✓ готово"
