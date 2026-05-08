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
	INGRESS_NS="$("${YQBIN}" '.ingressNamespace // strenv(E)' --arg E "${INGRESS_NS}" "${CFG}")"
	INGRESS_DS="$("${YQBIN}" '.daemonSet // strenv(E)' --arg E "${INGRESS_DS}" "${CFG}")"
	INGRESS_TCP_CM="$("${YQBIN}" '.tcpConfigMap // strenv(E)' --arg E "${INGRESS_TCP_CM}" "${CFG}")"
	INGRESS_CONTAINER="$("${YQBIN}" '.containerName // strenv(E)' --arg E "${INGRESS_CONTAINER}" "${CFG}")"
}

merge_ingress_from_yaml

n="$("${YQBIN}" '(.exposes // []) | length' "${CFG}")"
if [[ -z "${n}" ]] || [[ "${n}" == "null" ]]; then
	echo "✗ не удалось прочитать exposes из ${CFG}" >&2
	exit 1
fi
if ! [[ "${n}" =~ ^[0-9]+$ ]] || (( n < 1 )); then
	echo "✗ в ${CFG} массив exposes пустой — нечего применять" >&2
	exit 1
fi

DRY_RUN="${DRY_RUN:-}"
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
