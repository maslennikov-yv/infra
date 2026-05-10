# Netdata Monitoring (custom chart)

Лёгкий host-monitoring через Netdata: метрики ноды (CPU, memory, network,
disk, /proc, /sys, cgroups) собираются с **той ноды**, на которой запущен
pod, и отдаются на `:19999`. **Stateless**: история в RAM на 1 час, при
рестарте pod'а теряется.

В отличие от других сервисов в репо, это **custom chart** (не Bitnami),
написанный в `monitoring/netdata/netdata/`.

## Single-node coverage by design

Netdata-pod собирает метрики **только своей ноды** (через `hostPID`,
`hostNetwork`, hostPath `/proc /sys /cgroup`). Этот chart использует
**`Deployment` с `replicaCount: 1`** — оператор видит метрики **одной
случайной ноды** кластера.

- На single-node microk8s — это полный coverage, всё работает.
- На multi-node — это ограничение by design. Для полного coverage
  потребуется переписать template на `DaemonSet` (по pod на ноду);
  текущая инфраструктура не требует этого.
- **НЕ повышайте `replicaCount` > 1** — два pod'а либо дадут идентичную
  картину (если на одной ноде), либо ClusterIP-балансировщик будет
  случайно отдавать одну из двух картин разных нод.

## Требования

- Helm 3.x, kubectl, Docker.
- microk8s registry (`microk8s enable registry`) — образ публикуется
  в `localhost:32000/netdata/netdata:vX.Y.Z`.
- `metrics-server` (для `make top-nodes` диагностики Pending pods).

## Подготовка образов

```bash
microk8s enable registry
make images-sync                      # pull → tag → push в localhost:32000
```

Оффлайн:
```bash
make images-pull images-save          # tar в images/
make images-sync-from-files           # на целевой машине
```

## Деплой

```bash
# Из корня репозитория (рекомендуется)
make monitoring-up ENV=local

# Или из monitoring/netdata/
make install ENV=local
```

После деплоя:
```bash
make port-forward                # http://localhost:19999
# или (если ingress настроен)
# http://netdata.local
```

## Конфигурация

Pin версии:
- `image.tag: v2.10.3` — immutable. Заменён `stable` (moving target)
  на конкретную версию для reproducibility (см. `CLAUDE.md`).
- `Chart.yaml: appVersion: "v2.10.3"` синхронизирован.

Resources:
- `values-local.yaml`: 100m-500m / 128Mi-512Mi.
- `values-prod.yaml`: 200m-1000m / 256Mi-1024Mi.

Netdata config (в `netdata/values.yaml`):
- `updateEvery: 2` — сбор метрик каждые 2 секунды.
- `memoryMode: ram` — история в RAM (1 час). При рестарте теряется.
  Для долговременного хранения — отдельный Prometheus + Grafana.
- `history: 3600` — длина истории в секундах.

## Полезные команды

```bash
make help                   # сводка по всем командам
make status                 # helm status + поды
make logs                   # логи (deploy/$(RELEASE) -f)
make port-forward           # http://localhost:19999

# Диагностика (Pending / ресурсы)
make top-nodes              # CPU/память на нодах (с подсказкой по metrics-server)
make events                 # последние события в namespace monitoring
make pod-events             # события по поду netdata
make describe-pod           # describe pod (условия, volumes, secrets)

make uninstall              # ⚠ + warning про ClusterRole/Binding
```

## Используемые образы

`monitoring/netdata/Makefile`:
- **netdata/netdata** — `v2.10.3` (`NETDATA_TAG`).

Source-образ тянется из `docker.io/netdata/netdata:v2.10.3`,
перетегируется в `localhost:32000/netdata/netdata:v2.10.3`.

В отличие от других сервисов (`docker.io/bitnamilegacy/...`),
netdata публикуется upstream через сам netdata-проект, а не через Bitnami.

## RBAC и privileged

Netdata требует:
- `hostPID: true` + `hostNetwork: true` + `dnsPolicy: ClusterFirstWithHostNet` —
  чтобы видеть процессы и сетевую активность ноды.
- `securityContext.privileged: true` — для доступа к `/proc /sys /cgroup`
  через hostPath.
- `ClusterRole` с правами `get/list/watch` на pods/nodes/namespaces/services/
  endpoints/configmaps/deployments/statefulsets/daemonsets/replicasets — для
  Kubernetes-плагинов.

⚠ Это значимая security surface. Не публикуйте Netdata UI наружу без
auth-proxy (basic-auth ingress, OAuth2 proxy). По умолчанию
`ingress.enabled: true` в local/prod, но без TLS и без auth — только для
внутренней сети / dev.

## Ограничения

- **Single-node coverage** — см. раздел выше.
- **RAM-only история** — рестарт pod'а = потеря метрик. Для долгосрочного
  мониторинга — Prometheus.
- **Нет persistence PVC** — `cache/lib` через emptyDir.
- **Нет backup** — нечего бэкапить.

## Дополнительно

- [Netdata docs](https://learn.netdata.cloud/) — полная конфигурация netdata.conf.
- Корневой `CLAUDE.md` / `README.md` — общие соглашения (envs, helmfile).
