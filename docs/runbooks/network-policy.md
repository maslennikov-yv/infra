# NetworkPolicy: текущее состояние и план жёсткой сегментации

## TL;DR

В каждом `<svc>/values-prod.yaml` сейчас задано:

```yaml
networkPolicy:
  enabled: true
  allowExternal: true        # ← делает policy функционально noop
  allowExternalEgress: true
```

NetworkPolicy-ресурсы создаются Bitnami-chart'ами, но `allowExternal: true`
пропускает любые in-cluster соединения с правильным destination port
(дефолт Bitnami). Это **документирует намерение**, но не изолирует
сервисы. Реальная сегментация — пункт 1 ниже.

CNI кластера — **Calico** (microk8s addon), NetworkPolicy полностью
поддерживается.

## Когда переключать на жёсткую сегментацию

Имеет смысл если:

- В кластере живут приложения за пределами `apps/registry.yaml` (другие
  команды, чужой namespace), доступ которых к Postgres/Redis/Kafka надо
  ограничить.
- В compliance-аудите ожидают east-west изоляцию.
- В кластере появился злоумышленник внутри pod'а одного из приложений —
  без NP у него прямой доступ ко всем сервисам по in-cluster DNS.

Если кластер «маленький, доверенный, для одной команды» — текущий
`allowExternal: true` устраивает.

## План перехода на `allowExternal: false`

Жёсткая сегментация требует трёх параллельных правок. Делать **в одной
сессии** и желательно в maintenance-окне (доступ к сервисам прерывается на
~10 секунд между apply NP и labelling namespaces, если порядок шагов
нарушен).

### Шаг 1. Label на namespaces клиентов

Все namespace, из которых разрешён доступ к инфра-сервисам, должны иметь
label `infra-client=true`. Это:

- `monitoring` (Netdata собирает metrics со всех сервисов);
- `<app_ns>` каждого `enabled: true` приложения из `apps/registry.yaml`;
- любой namespace, откуда вы хотите разрешить доступ.

#### 1a. Обновить `apps-apply` flow

В `scripts/apps-apply.sh` (или в каждой `<svc>-app-create` цели) после
`kubectl create namespace <ns>` добавить:

```bash
kubectl label namespace "$ns" infra-client=true --overwrite
```

#### 1b. Прометить существующие namespace вручную

```bash
# monitoring
kubectl label namespace monitoring infra-client=true --overwrite

# каждый enabled app
for ns in $(yq -r '.apps[] | select(.enabled == true) | (.app_ns // .name)' apps/registry.yaml); do
  kubectl label namespace "$ns" infra-client=true --overwrite
done
```

### Шаг 2. Переключить values-prod.yaml каждого сервиса

В каждом `<svc>/values-prod.yaml` заменить:

```yaml
networkPolicy:
  enabled: true
  allowExternal: true
  allowExternalEgress: true
```

на:

```yaml
networkPolicy:
  enabled: true
  allowExternal: false           # требует label на pod ИЛИ соответствие ingressNSMatchLabels
  allowExternalEgress: true      # egress оставляем свободным
  ingressNSMatchLabels:
    infra-client: "true"
```

Для **postgres** — внутри `primary:` блока (`primary.networkPolicy.*`).

Если в каком-то сервисе требуется доступ из конкретного pod'а внешнего
namespace без label — добавьте `extraIngress` правило с `from:
namespaceSelector + podSelector`.

### Шаг 3. Apply

```bash
make diff ENV=prod   # проверьте, что меняются только NetworkPolicy ресурсы
make up   ENV=prod
```

## Smoke-тест после apply

```bash
# Из app pod'а должен открываться TCP-коннект к Postgres
kubectl run -it --rm -n <app_ns> netcheck --image=alpine --restart=Never -- \
  sh -c 'apk add -q netcat-openbsd && nc -zv postgres-postgresql.postgres 5432'

# Из default namespace (без label) — НЕ должен открываться
kubectl run -it --rm -n default netcheck --image=alpine --restart=Never -- \
  sh -c 'apk add -q netcat-openbsd && nc -zv postgres-postgresql.postgres 5432 -w 5'
# ожидание: timed out / connection refused
```

Аналогично для Redis (6379), Kafka (9092), MinIO (9000), RabbitMQ (5672),
ClickHouse (8123 / 9000).

## Откат

Если приложение потеряло доступ к сервису:

1. **Быстрый rollback** — вернуть `allowExternal: true` в соответствующем
   `values-prod.yaml`, `make up ENV=prod`. NP станет noop, доступ
   восстановится за секунды.
2. **Точечная правка** — добавить `extraIngress` с `from:
   namespaceSelector` для конкретного namespace, если он не должен иметь
   общий label `infra-client`.

## Riski

- **Третьи namespace без label** теряют доступ к инфра-сервисам после
  apply. Перед apply — `kubectl get ns --show-labels` и проверка, что все
  legitimate-клиенты помечены.
- **Egress NetworkPolicy** в этом плане не настраивается
  (`allowExternalEgress: true`). Если нужно ограничить, куда могут
  ходить pod-ы инфра-сервисов (например, запретить интернет для Postgres),
  настраивайте отдельно через `extraEgress`.
- **Kube DNS** должен быть доступен. По умолчанию Bitnami chart разрешает
  egress на kube-system DNS port 53. Если ваш cluster использует другой DNS
  layout — проверьте.
- **Probes / metrics-scraping** работают только из помеченных namespace.
  Netdata в `monitoring` должен иметь label.
