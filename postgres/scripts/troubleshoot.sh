#!/bin/bash
# Скрипт для автоматической диагностики проблем PostgreSQL

NAMESPACE="${1:-postgres}"
RELEASE_NAME="${2:-postgres}"

# Предусловия: без них дальнейшие kubectl-команды напечатают пустые/безмолвные
# секции, и оператор может ошибочно решить, что «всё ок».
if ! command -v kubectl >/dev/null 2>&1; then
    echo "✗ kubectl не найден в PATH" >&2
    exit 1
fi
if [ -n "${KUBECONFIG:-}" ] && [ ! -r "$KUBECONFIG" ]; then
    echo "✗ KUBECONFIG=$KUBECONFIG задан, но файл не читается" >&2
    exit 1
fi
if ! kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
    echo "✗ Кластер недоступен через kubectl (KUBECONFIG=${KUBECONFIG:-<unset>})" >&2
    echo "  Проверьте: kubectl config current-context, k8s/config/<env>, network/SSH-туннель." >&2
    exit 1
fi
HAS_HELM=1
command -v helm >/dev/null 2>&1 || HAS_HELM=0
HAS_JQ=1
command -v jq >/dev/null 2>&1 || HAS_JQ=0

echo "========================================="
echo "PostgreSQL Troubleshooting Diagnostic"
echo "Namespace: $NAMESPACE"
echo "Release: $RELEASE_NAME"
echo "Context: $(kubectl config current-context 2>/dev/null || echo '<unknown>')"
echo "========================================="
echo ""

echo "1. Проверка статуса ресурсов..."
echo "-----------------------------------"
kubectl get pods,statefulset,svc,pvc -n $NAMESPACE
echo ""

echo "2. Статус подов..."
echo "-----------------------------------"
kubectl get pods -n $NAMESPACE -o wide
echo ""

echo "3. Последние события (последние 10)..."
echo "-----------------------------------"
kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp' | tail -10
echo ""

echo "4. Использование ресурсов..."
echo "-----------------------------------"
kubectl top pods -n $NAMESPACE 2>/dev/null || echo "Метрики недоступны (нужен metrics-server)"
echo ""

echo "5. Проверка PVC..."
echo "-----------------------------------"
kubectl get pvc -n $NAMESPACE
echo ""

echo "6. Проверка секретов..."
echo "-----------------------------------"
kubectl get secrets -n $NAMESPACE | grep postgres
echo ""

echo "7. Проверка эндпоинтов сервисов..."
echo "-----------------------------------"
kubectl get endpoints -n $NAMESPACE | grep postgres
echo ""

echo "8. Проверка Helm релиза..."
echo "-----------------------------------"
if [ "$HAS_HELM" = 1 ]; then
    helm list -n $NAMESPACE | grep $RELEASE_NAME || echo "Helm релиз не найден"
else
    echo "helm не установлен — шаг пропущен"
fi
echo ""

# Проверка проблемных состояний
echo "9. Обнаружение проблем..."
echo "-----------------------------------"

# Проверка ImagePullBackOff
if kubectl get pods -n $NAMESPACE 2>/dev/null | grep -q "ImagePullBackOff\|ErrImagePull"; then
    echo "⚠️  ОБНАРУЖЕНА ПРОБЛЕМА: ImagePullBackOff/ErrImagePull"
    echo "   Решение: make load-containerd"
fi

# Проверка CrashLoopBackOff
if kubectl get pods -n $NAMESPACE 2>/dev/null | grep -q "CrashLoopBackOff"; then
    echo "⚠️  ОБНАРУЖЕНА ПРОБЛЕМА: CrashLoopBackOff"
    echo "   Проверьте логи: kubectl logs <pod-name> -n $NAMESPACE"
fi

# Проверка Pending
if kubectl get pods -n $NAMESPACE 2>/dev/null | grep -q "Pending"; then
    echo "⚠️  ОБНАРУЖЕНА ПРОБЛЕМА: Pod в статусе Pending"
    echo "   Проверьте: kubectl describe pod <pod-name> -n $NAMESPACE"
fi

# Проверка неготовых подов
if [ "$HAS_JQ" = 1 ]; then
    NOT_READY=$(kubectl get pods -n $NAMESPACE -o json 2>/dev/null | \
        jq -r '.items[] | select(.status.phase != "Running" or ([.status.containerStatuses[]? | select(.ready == false)] | length > 0)) | .metadata.name')

    if [ ! -z "$NOT_READY" ]; then
        echo "⚠️  Под(ы) не готовы:"
        echo "$NOT_READY" | while read pod; do
            if [ ! -z "$pod" ]; then
                echo "   - $pod"
                STATUS=$(kubectl get pod $pod -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null)
                echo "     Статус: $STATUS"
            fi
        done
    fi
else
    echo "ℹ jq не установлен — детальная проверка готовности подов пропущена"
fi

echo ""
echo "========================================="
echo "Диагностика завершена"
echo ""
echo "Полезные команды:"
echo "  kubectl logs <pod-name> -n $NAMESPACE -f"
echo "  kubectl describe pod <pod-name> -n $NAMESPACE"
echo "  kubectl exec -it <pod-name> -n $NAMESPACE -- bash"
echo "========================================="

