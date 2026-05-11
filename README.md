# Инфраструктура: PostgreSQL + Redis + Kafka + RabbitMQ + MinIO + ClickHouse для Kubernetes

Проект для развертывания PostgreSQL, Redis, Kafka, RabbitMQ, MinIO и ClickHouse в Kubernetes (microk8s) с использованием локального registry для образов.

## Содержание

- [Зачем это нужно](#зачем-это-нужно)
- [Структура проекта](#структура-проекта)
- [Сценарии эксплуатации](#сценарии-эксплуатации)
- [Быстрый старт](#быстрый-старт)
- [Основные команды](#основные-команды)
- [Как это работает](#как-это-работает)
- [Учётки приложений](#учётки-приложений)
- [Мониторинг (Netdata)](#мониторинг-netdata)
- [Требования](#требования)
- [Рекомендации по железу](#рекомендации-по-железу)
- [Настройка microk8s](#настройка-microk8s)
- [Важные замечания](#важные-замечания)
- [Файлы, которые не коммитятся](#файлы-которые-не-коммитятся-gitignore)
- [Troubleshooting](#troubleshooting)

## Зачем это нужно

Bitnami закрыл доступ к старым тегам образов (остался только `latest`). Чтобы не зависеть от внешних репозиториев и иметь возможность работать офлайн, все образы:
1. **Скачиваются заранее** и сохраняются в tar-файлы
2. **Загружаются в локальный registry** microk8s (`localhost:32000`)
3. **Используются из локального registry** в чартах

## Структура проекта

```
infra/
├── postgres/, redis/, kafka/, rabbitmq/, minio/, clickhouse/
│       # На каждый сервис: Helm chart, images/*.tar, values-<ENV>.yaml, Makefile.
├── monitoring/netdata/   # Netdata (опционально через ENABLED_SERVICES).
├── apps/                 # registry.yaml + apps/conf/<app>/ (не в git); шаблоны registry.yaml.example и conf/_example/.
├── scripts/              # Merge/apply конфигов приложений + утилиты + TUI infra.
├── docs/                 # runbooks (DR, secrets, usage-scenarios), pg-app.md, onboarding-admin.md.
├── helmfile.yaml.gotmpl  # Развёртывание всего стека из корня.
├── environments/         # <ENV>.mk (локальные SSH/REGISTRY) + <ENV>.yaml (реестр сервисов).
└── Makefile              # Корневые команды (helmfile, образы, приложения).
```

Имя `ENV` совпадает с суффиксом `values-<ENV>.yaml`. Полный обзор runbooks — [docs/README.md](docs/README.md).

## Сценарии эксплуатации

Типичные потоки: разные наборы сервисов на local и prod, подключение приложений и учёток, изменение состава стека, ротация секретов, проверка здоровья кластера, работа через TUI `node scripts/infra.mjs` — см. **[docs/runbooks/usage-scenarios.md](docs/runbooks/usage-scenarios.md)**.

Расширенные сценарии:
- **[Учётки приложений](docs/pg-app.md)** — изоляция по `APP`: per-сервис цели `*-app-create` / `*-app-show-creds` / `*-app-drop` для PostgreSQL, Redis, Kafka, MinIO, ClickHouse, RabbitMQ; чеклисты по каждому движку.
- **[Disaster recovery](docs/runbooks/disaster-recovery.md)** — восстановление кластера на новом сервере из git + env-backup-архива + бэкапов данных.
- **[Онбординг администратора](docs/onboarding-admin.md)** — какие файлы вне git нужны новому админу, безопасные каналы передачи, чек-лист проверки доступа.
- **[Шифрование секретов через sops+age](docs/runbooks/secrets-management.md)** — опциональный workflow: `apps/conf/<APP>/secrets.enc.yaml` в git, расшифровка автоматически в `apps-merge-config.sh`. Краткая шпаргалка — [sops-quickstart.md](docs/runbooks/sops-quickstart.md).
- **[Netdata мониторинг](monitoring/netdata/README.md)** — single-node coverage, RBAC, кастомные алерты, уведомления.
- **[microk8s ingress TCP / hostPort](.claude/skills/k8s-port-expose-microk8s/SKILL.md)** — открытие/закрытие TCP-портов на ноде (MQTT и пр. за nginx ingress).
- **`<service>/BACKUP.md`** — backup/restore детали для каждого сервиса.

## Быстрый старт

Сценарий — свежий клон репозитория на машине с установленным `microk8s`. Для удалённого сервера см. [docs/runbooks/usage-scenarios.md](docs/runbooks/usage-scenarios.md) (сценарий 1 «Бутстрап нового окружения»).

### 1. Зависимости и аддоны microk8s

```bash
# Аддоны (registry для образов, dns/storage для подов, metrics-server для top-nodes)
microk8s enable registry dns hostpath-storage metrics-server

# Проверка минимальных версий тулинга (kubectl, helm, helmfile, yq, jq, ...)
make tools-check
```

### 2. Скелет окружения и kubeconfig

```bash
make env-new ENV=local                     # environments/local.{mk,yaml}, k8s/config/local, values-local.yaml у каждого сервиса
make kubeconfig-microk8s-local ENV=local   # kubeconfig в k8s/config/local (без SSH)
```

### 3. Образы

```bash
make images-save ENV=local      # docker pull из docker.io/bitnamilegacy/* + tar в */images/
make images-push ENV=local      # docker load + tag + push в localhost:32000
```

### 4. Развёртывание

```bash
make up ENV=local
```

Запускает helmfile + автоматически `apps-apply` (учётки приложений из `apps/registry.yaml` + `apps/conf/<app>/`). Чтобы пропустить `apps-apply`, задайте `SKIP_APPS_APPLY=1`. Отдельно: `make apps-apply ENV=…`.

Шорткаты на отдельные сервисы: `make postgres-up`, `make redis-up`, `make kafka-up`, `make rabbitmq-up`, `make clickhouse-up`, `make minio-up`, `make monitoring-up` — вызывают общий `make up` с `ENABLED_SERVICES=<svc>`.

### 5. Sanity

```bash
make doctor ENV=local                      # тулинг + кластер + helm vs helmfile + rollouts + per-app verify
make status ENV=local                      # ноды, поды, helm list -A
```

Альтернативно — интерактивное меню. Варианты запуска (любой):

```bash
make infra                # без подготовки
npm run infra             # после npm install
./scripts/infra.mjs       # shebang, один раз chmod +x уже сделан
npx infra                 # после npm link (см. ниже)
infra                     # глобально после npm link
```

Для глобального `infra` достаточно один раз выполнить в корне репо: `npm install && npm link`. Symlink ведёт на файл в репо, поэтому `git pull` подхватывается без переустановки. Отвязать: `npm unlink -g infra-control`.

## Основные команды

### Корневые команды (все сервисы сразу)

```bash
# Образы
make images-save ENV=local      # Скачать/сохранить образы всех сервисов
make images-push ENV=local      # Загрузить образы в registry
make images-push-remote ENV=local  # Загрузить tar-файлы на удалённый сервер и опубликовать в его registry

# Развертывание
make up ENV=local              # Развернуть все (local)
make diff ENV=local            # Показать изменения (local)
make down ENV=local            # Удалить все (local)

make up ENV=prod             # Развернуть все (prod)

# Указать только устанавливаемые сервисы
make up ENV=local ENABLED_SERVICES=postgres,redis    # Развернуть только postgres и redis
make up ENV=prod ENABLED_SERVICES=minio            # Развернуть только minio

# Исключить сервисы из развертывания (игнорируется если задан ENABLED_SERVICES)
make up ENV=local EXCLUDE_SERVICES=kafka,clickhouse  # Развернуть все кроме kafka и clickhouse
make up ENV=prod EXCLUDE_SERVICES=minio            # Развернуть все кроме minio
```

#### Окружения (local/prod/staging/…)

Все корневые команды принимают параметр `ENV=<name>`.

**Выбор сервисов для развертывания:**

Можно указать только устанавливаемые сервисы через `ENABLED_SERVICES` (приоритетнее, чем `EXCLUDE_SERVICES`):

```bash
make up ENV=local ENABLED_SERVICES=postgres,redis
```

Или исключить отдельные сервисы через `EXCLUDE_SERVICES`:

```bash
make up ENV=local EXCLUDE_SERVICES=kafka,clickhouse
```

Или задать в `environments/$(ENV).mk`:
```makefile
# Только указанные сервисы (приоритетнее)
ENABLED_SERVICES ?= postgres,redis

# Или исключить (игнорируется если задан ENABLED_SERVICES)
EXCLUDE_SERVICES ?= kafka,clickhouse
```

Доступные сервисы: `postgres`, `redis`, `kafka`, `rabbitmq`, `minio`, `clickhouse`, `netdata`

Создать “рыбу” окружения:

```bash
make env-new ENV=staging
```

Это создаст:
- `environments/staging.mk` (сюда пишете SSH_HOST/SSH_KEY/REGISTRY/KUBECONFIG)
- `environments/staging.yaml` (реестр сервисов/namespace для `make env-backup` и т.п.; при необходимости отредактируйте)
- `k8s/config/staging` (файл-плейсхолдер под kubeconfig)
- `*/values-staging.yaml` (копия values-local.yaml или values-prod.yaml)

Имя **`ENV` должно совпадать с суффиксом** `values-<ENV>.yaml`, который подставляет helmfile. Файл **`postgres/values-stage.yaml`** в репозитории соответствует **`ENV=stage`**, а не `ENV=staging`.

Скачать kubeconfig с удалённого microk8s по SSH:

```bash
make kubeconfig-fetch ENV=local SSH_HOST=1.2.3.4 SSH_KEY=~/.ssh/id_ed25519
```

### Команды для отдельного сервиса

Зайти в директорию сервиса (`postgres/`, `redis/`, `kafka/`, `rabbitmq/`, `minio/`, `clickhouse/`) и использовать:

```bash
# Образы
make images-pull            # Скачать образы (docker.io/bitnamilegacy)
make images-save            # Сохранить в tar
make images-load            # Загрузить из tar
make images-tag             # Перетегировать для registry
make images-push            # Загрузить в registry
make images-sync            # pull + tag + push
make images-sync-from-files # load + tag + push

# Helm в каталоге сервиса (напрямую helm, не helmfile)
make install                # установить / обновить релиз (часто то же, что make upgrade)
make upgrade
make uninstall              # удалить релиз (см. документацию чарта про PVC)
make status                 # статус релиза и ресурсов в namespace

# Весь стек и единый diff — из корня репозитория
# make up / make diff / make down ENV=... (helmfile.yaml.gotmpl)

# Проверка
make check-registry         # Проверить доступность registry
```

## Как это работает

### 1. Образы

Каждый сервис имеет свой набор образов (см. `*/Makefile`):

- **PostgreSQL**: `postgresql`, `os-shell`, `postgres-exporter`
- **Redis**: `redis`, `redis-sentinel`, `redis-exporter`, `os-shell`, `kubectl`
- **Kafka**: `kafka`, `os-shell`, `kubectl`, `jmx-exporter`
- **RabbitMQ**: `rabbitmq`, `os-shell`
- **MinIO**: `minio`, `minio-client`, `minio-object-browser`, `os-shell`
- **ClickHouse**: `clickhouse`, `clickhouse-keeper`, `os-shell`

Все образы:
- Скачиваются из `docker.io/bitnamilegacy/*` (фиксированные теги в `*/Makefile`)
- Сохраняются в `*/images/*.tar`
- Публикуются в `localhost:32000/bitnami/*` с фиксированными тегами

### 2. Values-файлы

Обычно у каждого сервиса есть как минимум:
- `values-local.yaml` — local
- `values-prod.yaml` — prod

Дополнительные окружения — отдельные файлы `values-<ENV>.yaml` (например в репозитории есть `postgres/values-stage.yaml` для `ENV=stage`; Netdata может иметь только local/prod).

В них (для схемы с локальным registry) как правило задано:
- `image.registry: localhost:32000`
- `global.security.allowInsecureImages: true`
- фиксированные теги образов

### 3. Helmfile

`helmfile.yaml.gotmpl` описывает **семь** релизов (включаемость — через `ENABLED_SERVICES` / `EXCLUDE_SERVICES`):
- Локальные чарты: `./postgres/postgresql`, `./redis/redis`, `./kafka/kafka`, `./rabbitmq/rabbitmq`, `./minio/minio`, `./clickhouse/clickhouse`, `./monitoring/netdata/netdata`
- Подставляет нужный values-файл в зависимости от окружения (`values-{{ $env }}.yaml`)

`make diff` / `make up` читают пароли Redis и RabbitMQ из Secret в кластере; для **первого** просмотра шаблонов без кластера используйте `helmfile template` (см. раздел «Helmfile не работает»). Для рендеринга без реальных секретов передайте заглушки: `REDIS_PASSWORD=…`, `RABBITMQ_PASSWORD=…`, `RABBITMQ_ERLANG_COOKIE=…`.

## Учётки приложений

Изоляция приложений: реестр в `apps/registry.yaml` (`enabled: true|false`, уникальные `name`) — **не в git**, шаблон [`apps/registry.yaml.example`](apps/registry.yaml.example); секреты — в `apps/conf/<APP>/*.yaml` (deep-merge с реестром, не в git; образец [`apps/conf/_example/`](apps/conf/_example/)). Зависимость — [yq mikefarah v4](https://github.com/mikefarah/yq) или `./.tools/yq-mikefarah`.

- **Применение учёток в кластер:** `make apps-apply ENV=…` (с фильтрами `ENABLED_SERVICES` / `EXCLUDE_SERVICES`; запускается автоматически после `make up`, если не задан `SKIP_APPS_APPLY=1`; продолжать после ошибки одного шага — `APPS_APPLY_CONTINUE_ON_ERROR=1`).
- **Dry-run перед apply:** `make apps-apply-diff ENV=…` — печатает дельту (would create / would update / would drop / drift), ничего не меняет в кластере. Используйте перед `apps-apply`, особенно после правок `apps/registry.yaml` или `apps/conf/`.
- **Просмотр merge:** `make apps-merge-print`.
- **Per-сервис цели** (создание/просмотр/удаление учётки, проверка подключения, особенности по сервису — Kafka SASL+ACL, MinIO профили бакетов, Redis ACL+REDIS_DB и т.д.) — **полная справка в [docs/pg-app.md](docs/pg-app.md)**. Per-service подробности (особенно MinIO: presigned URL, CORS, профили доступа) — в `<service>/README.md`.

Бэкап и восстановление stateful-сервисов — `<service>/BACKUP.md` (или `make backup-all ENV=…` разом). Регулярная **проверка** восстановимости бэкапов (разворачивает свежий бэкап источника на DST_ENV и сравнивает structural fingerprint) — `make backup-verify SRC_ENV=… DST_ENV=… APP=… CLEAN=1`, см. [docs/runbooks/backup-verify.md](docs/runbooks/backup-verify.md).

## Требования

- Kubernetes (microk8s)
- Helm 3.x
- Docker
- helmfile
- kubectl
- Файл kubeconfig по пути **`k8s/config/<ENV>`** (переменная **`KUBECONFIG`** в корневом `Makefile`; без файла команды с `kubectl` завершатся ошибкой). Плейсхолдер: **`make env-new ENV=<env>`**, загрузка с ноды: **`make kubeconfig-fetch ...`**
- Для учёток приложений (**`apps/registry.yaml`**, merge, `make apps-apply`) — [**yq** mikefarah v4](https://github.com/mikefarah/yq) или **`./.tools/yq-mikefarah`**
- Для **infra** TUI (`make infra` / `npm run infra` / `infra` после `npm link`) — Node.js **18+** и **`npm install`** в корне репозитория (зависимость `@clack/prompts`)

## Рекомендации по железу

Ориентиры по CPU/памяти основаны на текущих `values-*.yaml` и пресетах чартов. Реальные запросы смотрите в манифестах после `helmfile template` или в подах (`kubectl top pods -A`).

### Суммарно

| Окружение | Минимум (все сервисы + Netdata) | Рекомендуемый запас |
|-----------|---------------------------------|----------------------|
| **local** | 4 CPU, 8 Gi RAM                 | 4 CPU, 12 Gi RAM (запас для сборок, rollout) |
| **prod**  | 4 CPU, 12 Gi RAM                | 6+ CPU, 16 Gi RAM (пики, мониторинг, запас под Pending) |

- **Диск:** для каждого сервиса с `persistence.enabled: true` закладывайте объём из `persistence.size` в values (PostgreSQL, Kafka, MinIO, ClickHouse, RabbitMQ). Плюс место под образы и системные компоненты (registry, system pods).
- **Одна нода:** если все поды на одной ноде, учитывайте также потребление system pods и kubelet. При нехватке ресурсов поды остаются в Pending — смотрите `make monitoring-top-nodes` и события пода.

### По сервисам

| Сервис     | CPU (requests / limits) | Память (requests / limits) | Диск (persistence) | Примечание |
|------------|-------------------------|----------------------------|--------------------|------------|
| **PostgreSQL** | 250m / 500m         | 256Mi / 512Mi              | из `primary.persistence.size` | В values-local/prod заданы явно. |
| **Redis**     | по пресету (nano ≈ 50m / 256Mi) | —                  | при включённой persistence | В values ресурсы не переопределены. |
| **Kafka**    | по пресету (small ≈ 256m / 512Mi на broker/controller) | — | data + logs PVC из chart | 1 broker в local; при росте нагрузки увеличить replicas и ресурсы. |
| **MinIO**    | по пресету (micro ≈ 100m / 256Mi) | —                 | из `persistence.size` | Плюс консоль (console), если включена. |
| **ClickHouse** | по пресету (small ≈ 256m / 512Mi) | —               | 8Gi в values-local | Keeper выключен в local; при включении — отдельные запросы. |
| **RabbitMQ** | 250m / 1               | 512Mi / 1Gi                | из `persistence.size` | В values-prod заданы явно. |
| **Netdata**  | local: 100m/500m, prod: 200m/1 | local: 128Mi/512Mi, prod: 256Mi/1Gi | — | В values-local/prod заданы явно. |

- **Где смотреть точные значения:** `*/values-local.yaml`, `*/values-prod.yaml` (секции `resources`, `primary.resources`, `controller.resources`, `broker.resources` и т.п.). Если не задано — используются пресеты чарта (см. `resourcesPreset` в `*/chart/values.yaml`).
- **Проверка по кластеру:** `make monitoring-top-nodes ENV=prod` — загрузка нод; при Pending — `make monitoring-pod-events ENV=prod POD=<имя-пода>` или `make monitoring-describe-pod ENV=prod POD=<имя-пода>`.

## Настройка microk8s

**Удалённый сервер:** настройка microk8s и включение аддонов (registry, dns, ingress, storage, metrics-server) и docker выполняется командой (требуется `SSH_HOST` в `environments/$(ENV).mk`):

```bash
make microk8s-setup ENV=prod
```

**Локально** убедитесь, что включены необходимые аддоны:

```bash
microk8s enable registry
microk8s enable storage
microk8s enable dns
microk8s enable metrics-server
```

## Важные замечания

1. **Образы нужно скачивать заранее** - пока доступен `bitnamilegacy`, иначе потом не получится
2. **Все образы публикуются в `localhost:32000/bitnami/*`** - это важно для работы чартов
3. **Теги фиксированы** - см. `*/Makefile` для списка используемых тегов
4. **Values-файлы не редактируются через sed** - используются отдельные файлы для local/prod

## Файлы, которые не коммитятся (gitignore)

Чтобы новый пользователь мог “с нуля” развернуть инфраструктуру без потери важных конфигов, в игноре находятся **только локальные/генерируемые** файлы — и для каждого есть команда, которая их создаёт.

- **`apps/registry.yaml`**: локальный реестр приложений окружения (имена, namespaces, redis_db и т.п.). Создаётся копированием шаблона: `cp apps/registry.yaml.example apps/registry.yaml`, дальше правится под конкретное окружение. В git только `.example`.
- **`environments/<env>.mk`**: локальные секреты/переопределения окружения (SSH_HOST/SSH_KEY/KUBECONFIG/REGISTRY и т.п.). Создаётся: `make env-new ENV=<env>`.
- **`k8s/config/<env>`**: kubeconfig для окружения. Создаётся плейсхолдером: `make env-new ENV=<env>`, затем заполняется/скачивается: `make kubeconfig-fetch ENV=<env> ...` (см. `k8s/config/README.md`).
- **`<service>/images/*.tar`**: tar-файлы Docker образов для offline/registry. Создаются: `make images-save ENV=<env>` (или `make images-save ENV=<env> SERVICE=<service>`).
- **`environments/backups/`**: бэкапы Kubernetes secrets/configmaps сервисов. Создаются: `make env-backup ENV=<env> [CONFIRM=1]` (см. раздел "Бэкап конфигов/секретов").
- **`postgres/backups/`**: бэкапы PostgreSQL. Создаются `make postgres-backup ENV=...` или `make -C postgres backup ENV=...` (см. `postgres/README.md` и `postgres/BACKUP.md`).

Важно: **values-файлы, чарты и lock-файлы чартов (`Chart.lock`) коммитятся** — их намеренно не игнорируем, чтобы “чистый клон” работал одинаково у всех.

## Мониторинг (Netdata)

Netdata собирает метрики **CPU/память/диск/I/O/сеть/FD** ноды и сервисов (по namespaces). Включается через `ENABLED_SERVICES` / `EXCLUDE_SERVICES`.

- Деплой: `make monitoring-up ENV=…`. Доступ: ingress (`monitoring/netdata/values-<ENV>.yaml`) или `make monitoring-port-forward` (порт 19999).
- Работает **автономно** (без Netdata Cloud); алерты — локальные. UI: раздел **Alarms**, API `/api/v1/alarms?all`.
- **Полная справка** (вход без Sign-in, single-node coverage, RBAC, кастомные алерты, уведомления через ConfigMap) — [monitoring/netdata/README.md](monitoring/netdata/README.md).

## Troubleshooting

### Registry недоступен

```bash
# Проверить
make -C postgres check-registry

# Включить
microk8s enable registry
```

### Образы не найдены

```bash
# Проверить сохраненные образы
ls -lh postgres/images/
ls -lh redis/images/
ls -lh kafka/images/

# Если пусто - скачать заново
make images-save ENV=local
```

### Helmfile не работает

Окружение helmfile в репозитории — `default`; целевое окружение задаётся переменной `ENV` (см. `Makefile`).

```bash
# Проверить синтаксис (без кластера; заглушки нужны для чартов Redis/RabbitMQ)
ENV=local REDIS_PASSWORD=x RABBITMQ_PASSWORD=x RABBITMQ_ERLANG_COOKIE=x \
  helmfile -f helmfile.yaml.gotmpl -e default template

# Сравнение с кластером — после make up и появления Secret redis/redis и rabbitmq/rabbitmq
make diff ENV=local
```

## Repository topics (discoverability)

Рекомендуемые теги для настроек репозитория на GitHub (About → Topics):

`kubernetes` `helm` `infrastructure` `microservices` `docker` `postgresql` `kafka` `minio` `redis` `rabbitmq` `clickhouse` `netdata` `microk8s`
