# Инфраструктура данных в Kubernetes

PostgreSQL, Redis, Kafka, RabbitMQ, MinIO, ClickHouse, Netdata в `microk8s`. Локальные Helm-чарты, оркестрация через `helmfile` и корневой `Makefile`. Образы — из `docker.io/bitnamilegacy/*` в локальный registry `localhost:32000` (офлайн-сборка и независимость от закрытия старых тегов в Bitnami).

## Структура

```
infra/
├── postgres/ redis/ kafka/ rabbitmq/ minio/ clickhouse/   # на сервис: Helm chart, values-<ENV>.yaml, Makefile, images/*.tar
├── monitoring/netdata/        # опциональный мониторинг
├── apps/                      # registry.yaml + conf/<APP>/<ENV>/ (не в git); шаблоны *.example
├── scripts/                   # apps-apply, merge, reconcile (Redis ACL), TUI
├── docs/                      # runbooks (DR, secrets, usage-scenarios, app-interface)
├── helmfile.yaml.gotmpl       # развёртывание стека
├── environments/              # <ENV>.mk (локальные SSH/REGISTRY/KUBECONFIG) + <ENV>.yaml
└── Makefile                   # корневые команды
```

Имя `ENV` совпадает с суффиксом `values-<ENV>.yaml`. Полный обзор runbooks — [docs/README.md](docs/README.md).

## Быстрый старт

Свежий клон на машине с `microk8s`. Удалённый сервер — [docs/runbooks/usage-scenarios.md](docs/runbooks/usage-scenarios.md).

```bash
microk8s enable registry dns hostpath-storage metrics-server
make tools-check                                # минимальные версии kubectl/helm/helmfile/yq/jq/...
make env-new ENV=local                          # environments/local.{mk,yaml}, k8s/config/local, values-local.yaml
make kubeconfig-microk8s-local ENV=local        # kubeconfig в k8s/config/local
make images-save ENV=local                      # pull bitnamilegacy → tar в */images/
make images-push ENV=local                      # load + tag + push в localhost:32000
make up ENV=local                               # helmfile apply + apps-apply (учётки приложений)
make doctor ENV=local                           # тулинг + кластер + per-app verify
```

Интерактивное меню: `make infra` (или `npm run infra` / `./scripts/infra.mjs`; для глобального `infra` — `npm install && npm link`).

## Основные команды

```bash
# Стек
make up   ENV=local [ENABLED_SERVICES=postgres,redis] [EXCLUDE_SERVICES=kafka,clickhouse] [SKIP_APPS_APPLY=1]
make diff ENV=local
make down ENV=local
make <svc>-up ENV=local                # шорткат для make up ENABLED_SERVICES=<svc>

# Учётки приложений (создают Secret <APP>-<service> в namespace приложения)
make apps-apply       ENV=local                # из apps/registry.yaml + apps/conf/
make apps-apply-diff  ENV=local                # dry-run: would create / update / drop / drift
make <svc>-app-create APP=myapp ENV=local      # postgres/redis/kafka/rabbitmq/minio/clickhouse
make <svc>-app-show-creds APP=myapp ENV=local
make <svc>-app-drop   APP=myapp ENV=local [SKIP_CONFIRM=1]

# Lifecycle приложения через infra-interface (apps/src/<APP>/Makefile.infra)
make app-deploy / app-rollback / app-status / app-logs / app-migrate / app-seed / app-shell APP=myapp ENV=...

# Бэкапы (см. <service>/BACKUP.md, apps/backups/<ENV>/<APP>/<svc>/)
make backup-all  ENV=...
make app-backup  APP=myapp ENV=...

# Диагностика
make status ENV=...                            # ноды, поды, helm list -A
make top-totals ENV=...                        # CPU/память: занято/доступно
make <svc>-status|logs|shell ENV=...
```

Полная справка корневого Makefile — `make help`. Per-service — `make -C <svc> help`.

## Как работает

- **Каталог сервиса = модуль.** Свой Helm-чарт, `values-<ENV>.yaml`, `Makefile`, `images/*.tar`. Переопределения вне git — `<svc>/values-<ENV>.local.yaml` (overlay, gitignored).
- **`helmfile.yaml.gotmpl`** — единая точка деплоя, `ENABLED_SERVICES` / `EXCLUDE_SERVICES` фильтруют release-блоки.
- **Образы:** `docker.io/bitnamilegacy/*` → tar → `localhost:32000/bitnami/*`. В values задано `image.registry: localhost:32000` и `global.security.allowInsecureImages: true`.
- **Пароли admin** для Redis/RabbitMQ при `make diff/up` подтягиваются из Secret в кластере (Secret создаётся при первом `make up`).

### Учётки приложений (config-driven reconciliation)

Источник истины — `apps/registry.yaml` (имена/namespaces, `enabled: true|false`) + `apps/conf/<APP>/<ENV>/` (deep-merge с реестром; зашифрованные `*.enc.yaml` поддерживаются через sops+age). Оба — **не в git**, шаблоны `*.example`.

`make apps-apply ENV=...` идемпотентно приводит состояние сервисов к merged конфигу:
- Per-service `*-app-create` обновляет per-app данные (Secret в namespace приложения, запись в `apps/conf`).
- Для **multi-tenant ACL** (Redis) — один агрегированный `redis-acl-reconcile` после прохода всех приложений: патчит ConfigMap `redis-configuration` (поле `users.acl`) + `ACL LOAD`. Состояние переживает рестарт пода (aclfile подтягивается из ConfigMap).
- Postgres/Kafka/RabbitMQ/MinIO/ClickHouse — состояние в PVC; per-app create идемпотентен и обновляет пароли (`ALTER ROLE`, `kafka-configs --alter`, `change_password`, `mc admin user info → remove → add`).
- Drift (учётка приложения, ушедшего из `enabled: true`) — печатается `⚠ drift`; явное удаление — `APPS_APPLY_DROP_DISABLED=1` или `make <svc>-app-drop APP=... SKIP_CONFIRM=1`.

Полная справка по учёткам — [docs/pg-app.md](docs/pg-app.md). Контракт `infra-interface` для lifecycle приложений — [docs/runbooks/app-interface.md](docs/runbooks/app-interface.md).

## Файлы вне git

Только локальные/генерируемые — у каждого есть команда, которая их создаёт:

| Файл/каталог | Создаётся командой |
|---|---|
| `apps/registry.yaml` | `cp apps/registry.yaml.example apps/registry.yaml` |
| `apps/conf/<APP>/<ENV>/` | `make apps-conf-template APP=... ENV=...` (или `apps/conf/_example/`) |
| `apps/src/` | `make apps-src-clone APP=...` (git clone по `repo_url` из registry) |
| `apps/.tmp/`, `apps/images/` | автогенерация при `app-deploy` / `app-image-save` |
| `environments/<env>.mk`, `k8s/config/<env>` | `make env-new ENV=<env>`, далее `make kubeconfig-fetch ...` |
| `<service>/images/*.tar` | `make images-save ENV=<env>` |
| `<service>/backups/<env>/`, `apps/backups/<env>/<app>/<svc>/`, `environments/backups/<env>/` | `make <svc>-backup` / `make app-backup` / `make env-backup` |
| `<svc>/values-<env>.local.yaml` | вручную (overlay для приватных hostname/email, поверх values-<env>.yaml) |

Helm-чарты, `Chart.lock`, `values-<ENV>.yaml`, шаблоны `*.example` — **в git**: чистый клон должен работать.

## Сценарии и runbooks

- [usage-scenarios.md](docs/runbooks/usage-scenarios.md) — типичные потоки (bootstrap, ENABLED/EXCLUDE, ротация секретов, health-check, TUI).
- [disaster-recovery.md](docs/runbooks/disaster-recovery.md) — восстановление кластера на новом сервере.
- [onboarding-admin.md](docs/onboarding-admin.md) — что вне git нужно новому админу.
- [secrets-management.md](docs/runbooks/secrets-management.md) / [sops-quickstart.md](docs/runbooks/sops-quickstart.md) — шифрование `apps/conf/<APP>/<ENV>/secrets.enc.yaml`.
- [backup-verify.md](docs/runbooks/backup-verify.md) — регулярная проверка восстановимости бэкапов (`make backup-verify SRC_ENV=... DST_ENV=... APP=...`).
- [app-interface.md](docs/runbooks/app-interface.md) — контракт `infra-deploy / status / logs / migrate / seed / shell / rollback` через `Makefile.infra` в репо приложения.
- [network-policy.md](docs/runbooks/network-policy.md), [kafka-listener-security.md](docs/runbooks/kafka-listener-security.md), [storage-class.md](docs/runbooks/storage-class.md), [backups-encryption.md](docs/runbooks/backups-encryption.md) — целевые состояния по безопасности.
- [k8s-port-expose-microk8s](.claude/skills/k8s-port-expose-microk8s/SKILL.md) — открытие TCP-портов через nginx ingress (MQTT и пр.).
- `<service>/BACKUP.md`, `monitoring/netdata/README.md` — per-service детали.

## Окружения

- Имя `ENV` совпадает с суффиксом values: `ENV=stage` → `values-stage.yaml` (не `values-staging.yaml`).
- Скелет нового: `make env-new ENV=staging` (рыба `.mk`, `.yaml`, плейсхолдер `k8s/config/staging`, копия `values-local.yaml`).
- Удалённый kubeconfig: `make kubeconfig-fetch ENV=prod SSH_HOST=... SSH_KEY=...`.
- Настройка ноды с нуля: `make microk8s-setup ENV=prod` (microk8s + аддоны + docker по SSH).

## Требования

- `microk8s` (или совместимый Kubernetes), Helm 3, `helmfile`, `kubectl`, Docker, `jq`.
- [`yq` mikefarah v4](https://github.com/mikefarah/yq) (или `./.tools/yq-mikefarah`) — для merge `apps/registry.yaml` + `apps/conf/`.
- `gomplate` 4+ — опционально, для приложений с `deploy/helm/values.yaml.gotmpl`.
- Node.js 18+ + `npm install` — для `make infra` TUI.
- `make tools-check` подсказывает установку отсутствующих.

## Железо (ориентир)

| Окружение | Минимум | Запас |
|---|---|---|
| **local** | 4 CPU, 8 Gi | +4 Gi (сборки, rollout) |
| **prod**  | 4 CPU, 12 Gi | 6+ CPU, 16 Gi (пики, Pending) |

Диск — сумма `persistence.size` всех сервисов + место под образы и system pods. Точные resources — в `*/values-<ENV>.yaml` (секции `resources`, `primary.resources`, и т.п.); если не задано — chart preset (`resourcesPreset`). При нехватке на одной ноде — поды Pending, смотреть `make monitoring-top-nodes ENV=...` + события пода.

## Важно

1. **Образы скачивать заранее** — пока доступен `bitnamilegacy`.
2. **`image.registry: localhost:32000`** обязателен в values.
3. **Теги фиксированы** — см. `*/Makefile`.
4. **values-файлы не правим mass-sed-ом** — отдельные файлы per-env, осмысленные правки.

## Troubleshooting

```bash
# Registry недоступен
make -C postgres check-registry
microk8s enable registry

# Образы не найдены
ls -lh */images/ && make images-save ENV=local

# Helmfile без кластера (для проверки шаблонов)
ENV=local REDIS_PASSWORD=x RABBITMQ_PASSWORD=x RABBITMQ_ERLANG_COOKIE=x \
  helmfile -f helmfile.yaml.gotmpl -e default template
```

Окружение helmfile в репо — `default`; целевое выбирается через `ENV`.

## GitHub topics

`kubernetes` `helm` `infrastructure` `microservices` `docker` `postgresql` `kafka` `minio` `redis` `rabbitmq` `clickhouse` `netdata` `microk8s`
