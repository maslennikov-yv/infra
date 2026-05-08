# Инфраструктура: PostgreSQL + Redis + Kafka + RabbitMQ + MinIO + ClickHouse для Kubernetes

Проект для развертывания PostgreSQL, Redis, Kafka, RabbitMQ, MinIO и ClickHouse в Kubernetes (microk8s) с использованием локального registry для образов.

## Зачем это нужно

Bitnami закрыл доступ к старым тегам образов (остался только `latest`). Чтобы не зависеть от внешних репозиториев и иметь возможность работать офлайн, все образы:
1. **Скачиваются заранее** и сохраняются в tar-файлы
2. **Загружаются в локальный registry** microk8s (`localhost:32000`)
3. **Используются из локального registry** в чартах

## Структура проекта

```
infra/
├── postgres/          # PostgreSQL
│   ├── postgresql/    # Helm chart
│   ├── images/        # tar-файлы образов
│   ├── values-local.yaml
│   ├── values-prod.yaml
│   ├── values-stage.yaml   # пример: ENV=stage → helmfile подключает values-stage.yaml
│   └── Makefile
├── redis/             # Redis (standalone)
│   ├── redis/         # Helm chart
│   ├── images/
│   ├── values-local.yaml
│   ├── values-prod.yaml
│   └── Makefile
├── kafka/             # Kafka
│   ├── kafka/         # Helm chart
│   ├── images/
│   ├── values-local.yaml
│   ├── values-prod.yaml
│   └── Makefile
├── rabbitmq/          # RabbitMQ
│   ├── rabbitmq/      # Helm chart
│   ├── images/
│   ├── values-local.yaml
│   ├── values-prod.yaml
│   └── Makefile
├── clickhouse/        # ClickHouse (standalone)
│   ├── clickhouse/    # Helm chart
│   ├── images/
│   ├── values-local.yaml
│   ├── values-prod.yaml
│   └── Makefile
├── minio/             # MinIO (S3)
│   ├── minio/         # Helm chart
│   ├── images/
│   ├── values-local.yaml
│   ├── values-prod.yaml
│   └── Makefile
├── monitoring/netdata/  # Netdata (опционально через ENABLED_SERVICES)
├── apps/                # registry.yaml; секреты в apps/conf/<app>/ (не в git)
├── scripts/             # merge/apply конфигов приложений и утилиты
├── helmfile.yaml.gotmpl # Развертывание всего стека из корня
├── environments/        # mk + yaml (список релизов для env-backup и т.п.)
└── Makefile             # Корневые команды (helmfile, образы, приложения)
```

## Сценарии эксплуатации

Типичные потоки: разные наборы сервисов на local и prod, подключение приложений и учёток, изменение состава стека, ротация секретов, проверка здоровья кластера, работа через TUI [`node scripts/infra-lab.mjs`](docs/infra-control/README.md) — см. **[docs/runbooks/usage-scenarios.md](docs/runbooks/usage-scenarios.md)**.

## Быстрый старт

### 1. Подготовка образов (один раз)

Скачать и сохранить все образы в tar-файлы:

```bash
make images-save ENV=local
```

Эта команда:
- Скачает образы из `docker.io/bitnamilegacy/*`
- Сохранит их в `*/images/*.tar`

### 2. Загрузка образов в microk8s registry

```bash
make images-push ENV=local
```

Эта команда:
- Загрузит tar-файлы в Docker
- Перетегирует для `localhost:32000/bitnami/*`
- Загрузит в microk8s registry

### 3. Развертывание всех сервисов

```bash
make up ENV=local
```

Или развернуть по отдельности:

```bash
# PostgreSQL
make postgres-up ENV=local

# Redis
make redis-up ENV=local

# Kafka
make kafka-up ENV=local

# RabbitMQ
make rabbitmq-up ENV=local

# ClickHouse
make clickhouse-up ENV=local

# MinIO
make minio-up ENV=local
```

Цели **`make postgres-up`** / **`redis-up`** и т.д. вызывают общий **`make up`** с **`ENABLED_SERVICES=...`**, поэтому после Helm выполняется и **`apps-apply`** (те же правила, что и при полном **`make up`**). Чтобы применить только чарты без учёток приложений, задайте **`SKIP_APPS_APPLY=1`**. Отдельный запуск: **`make apps-apply ENV=...`** (при необходимости **`ENABLED_SERVICES=...`**).

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

## Примеры использования

### Первая установка (с нуля)

```bash
# 1. Скачать образы
make images-save ENV=local

# 2. Загрузить в registry
make images-push ENV=local

# 3. Развернуть
make up ENV=local
```

### Обновление после изменений

```bash
# Посмотреть что изменится
make diff ENV=local

# Применить изменения
make up ENV=local
```

### Работа с одним сервисом

```bash
cd postgres

# Скачать образы только для PostgreSQL
make images-save ENV=local

# Загрузить в registry
make images-sync-from-files ENV=local

# Развернуть только этот сервис (helm в каталоге; не helmfile)
make install ENV=local
```

## PostgreSQL: для приложений

Создание **отдельной БД и роли в Postgres** и **учётки Redis** (ACL + префикс ключей; опционально логический номер БД `REDIS_DB` в Secret — не то же самое, что отдельная БД Postgres, см. `docs/pg-app.md`) — по одному приложению:

В **`apps/registry.yaml`** перечисляйте приложения (у каждой записи обязательно **`enabled: true|false`**; среди **`enabled: true`** поля **`name`** не должны повторяться — проверяется при merge). Секреты — в **`apps/conf/<APP>/*.yaml`** (deep-merge с реестром; образец **`apps/conf/_example/`**). Нужен [**yq** mikefarah v4](https://github.com/mikefarah/yq): переменная **`YQ=…`** или бинарь **`./.tools/yq-mikefarah`** (см. корневой `Makefile`). **`make apps-merge-print`** — собранный merge в stdout; **`make apps-apply`** идемпотентно создаёт учётки там, где в merge есть пароли/ключи (**`ENABLED_SERVICES`** / **`EXCLUDE_SERVICES`** как у helmfile); по умолчанию процесс прерывается на **первой** ошибке `make`, для попытки остальных шагов подряд используйте **`APPS_APPLY_CONTINUE_ON_ERROR=1`** (код выхода всё равно будет ненулевым, если хоть один шаг упал); после **`make up`** автоматически вызывается **`apps-apply`**, если не задан **`SKIP_APPS_APPLY=1`**.

Поле **`redis_db`** в реестре необязательно: если не указано, `make redis-app-create` без `REDIS_DB=…` назначает **следующий свободный** номер **1..127** ([`scripts/redis-next-db.sh`](scripts/redis-next-db.sh); нужен **yq** mikefarah v4). Явный **`redis_db`** фиксирует номер. Переопределение: **`REDIS_DB=…`** в CLI.

```bash
make pg-app-create APP=myapp ENV=stage
make redis-app-create APP=myapp ENV=stage              # ACL + Secret; следующий свободный redis_db из merged
make redis-app-create APP=myapp ENV=stage REDIS_DB=3   # явно задать логический номер БД Redis
make pg-app-show-creds APP=myapp ENV=stage   # показать креды
make redis-app-show-creds APP=myapp ENV=stage   # креды Redis (Secret app-redis, префикс и REDIS_DB)
make pg-app-drop APP=myapp ENV=stage         # удалить БД, роль и Secret (y/N; SKIP_CONFIRM=1)
make pg-app-verify APP=myapp ENV=stage       # проверить подключение
```

Секреты в namespace приложения: `APP-postgres`, `APP-redis`.

Бэкап и восстановление:
```bash
make postgres-backup ENV=stage
make postgres-restore BACKUP_FILE=backups/postgres-backup-YYYYMMDD-HHMMSS.sql.gz ENV=stage
```

Пересоздание с новым размером PVC: `make postgres-recreate-prep ENV=stage` (см. `postgres/TROUBLESHOOTING.md`).

## Kafka: для приложений

В этой инфраструктуре Kafka настроена для **in-cluster** использования приложениями с **SASL/SCRAM (SCRAM-SHA-256) + ACL**.

### Создать учётку приложения (user + ACL + Secret)

```bash
make kafka-app-create APP=appA
```

Это создаст Secret `appA-kafka` в namespace `appA` со следующими ключами:
- `KAFKA_BOOTSTRAP_SERVER` (по умолчанию `kafka.kafka.svc.cluster.local:9092`)
- `KAFKA_SECURITY_PROTOCOL=SASL_PLAINTEXT`
- `KAFKA_SASL_MECHANISM=SCRAM-SHA-256`
- `KAFKA_USERNAME` / `KAFKA_PASSWORD`
- `KAFKA_TOPIC_PREFIX=appA.`
- `KAFKA_GROUP_PREFIX=appA.`

Изоляция реализована через ACL на ресурсы **prefixed**:
- разрешены топики с префиксом `appA.`
- разрешены consumer groups с префиксом `appA.`

### Примеры для приложений

- Go (sarama): `examples/kafka/go-sarama/`
- Laravel (php-rdkafka): `examples/kafka/laravel-rdkafka/`

### Управление топиками (partitions/retention/cleanup/max.message.bytes/compression)

Создать топик для приложения (автоматически `appA.events`):

```bash
make kafka-topic-create APP=appA TOPIC_SUFFIX=events PARTITIONS=6 REPLICATION_FACTOR=1 \
  CONFIGS='retention.ms=604800000,cleanup.policy=delete,compression.type=producer'
```

Увеличить partitions:

```bash
make kafka-topic-alter TOPIC=appA.events PARTITIONS=12
```

Изменить конфиги (retention/max.message.bytes/и т.п.):

```bash
make kafka-topic-alter TOPIC=appA.events CONFIGS='retention.ms=86400000,max.message.bytes=1048576'
```

Показать описание и текущие configs:

```bash
make kafka-topic-describe TOPIC=appA.events
```

Список топиков по префиксу:

```bash
make kafka-topic-list PREFIX=appA.
```

## RabbitMQ: для приложений

RabbitMQ разворачивается в **standalone** режиме и доступен **только внутри кластера** (ClusterIP). Management UI включён (порт 15672), ingress настраивается в `rabbitmq/values-$(ENV).yaml`.

### Создать учётку приложения (vhost + user + permissions + Secret)

```bash
make rabbitmq-app-create APP=appA
```

Это создаст Secret `appA-rabbitmq` в namespace `appA` со следующими ключами:
- `RABBITMQ_HOST` (по умолчанию `rabbitmq.rabbitmq.svc.cluster.local`)
- `RABBITMQ_PORT` (AMQP, 5672)
- `RABBITMQ_MANAGEMENT_PORT` (HTTP, 15672)
- `RABBITMQ_VHOST`
- `RABBITMQ_USERNAME`
- `RABBITMQ_PASSWORD`
- `RABBITMQ_AMQP_URL`

## ClickHouse: для приложений

ClickHouse разворачивается в **standalone** режиме и доступен **только внутри кластера** (ClusterIP).

### Создать учётку приложения (DB + USER + Secret)

```bash
make clickhouse-app-create APP=appA
```

Это создаст Secret `appA-clickhouse` в namespace `appA` со следующими ключами:
- `CLICKHOUSE_HOST` (по умолчанию `clickhouse.clickhouse.svc.cluster.local`)
- `CLICKHOUSE_PORT` (TCP, 9000)
- `CLICKHOUSE_HTTP_PORT` (HTTP, 8123)
- `CLICKHOUSE_DB`
- `CLICKHOUSE_USER`
- `CLICKHOUSE_PASSWORD`

## MinIO: профили бакетов (S3)

Все команды создают bucket/user/policy и Secret в namespace приложения.

### Примеры для приложений

- Go (minio-go/v7): `examples/minio/go-minio/`
- Laravel (S3 Storage): `examples/minio/laravel-s3/`

### Публичный доступ из интернета (nginx ingress, path-style, домены приложений)

Рекомендуемая схема для веб‑приложений:
- Пользователи **не получают** постоянные S3 ключи
- Ваш backend после проверки JWT/session выдаёт **presigned URL** (GET/PUT/POST)
- Снаружи используется **path-style**:
  - `https://files.appA.com/<bucket>/<key>`
  - `https://files.appB.com/<bucket>/<key>`

Ingress для MinIO API настраивается в `minio/values-$(ENV).yaml` (см. блок `ingress:`). По умолчанию `console.ingress` выключен и не должен публиковаться в интернет.

Чтобы presigned URL подписывались на “внешний” домен приложения, при создании app account передайте `APP_PUBLIC_ENDPOINT`:

```bash
make minio-app-create APP=appA BUCKET=appA APP_PUBLIC_ENDPOINT=https://files.appA.com
```

В Secret приложения появится:
- `MINIO_PUBLIC_ENDPOINT` — **используйте в приложениях для presign/доступа**
- `MINIO_ENDPOINT` — internal endpoint (используется для админских операций внутри кластера)

### CORS (если браузер будет ходить по presigned URL напрямую)

Настраивается на bucket через `mc cors set` (XML). Минимальный пример (разрешить фронту `https://appA.com` GET/HEAD/PUT/POST):

```xml
<CORSConfiguration>
  <CORSRule>
    <AllowedOrigin>https://appA.com</AllowedOrigin>
    <AllowedMethod>GET</AllowedMethod>
    <AllowedMethod>HEAD</AllowedMethod>
    <AllowedMethod>PUT</AllowedMethod>
    <AllowedMethod>POST</AllowedMethod>
    <AllowedHeader>*</AllowedHeader>
    <ExposeHeader>ETag</ExposeHeader>
    <MaxAgeSeconds>3600</MaxAgeSeconds>
  </CORSRule>
</CORSConfiguration>
```

### Private RW (полный доступ приложению на свой bucket)

```bash
make minio-app-create APP=appA
```

### Private RO (только чтение)

```bash
make minio-app-create APP=reports ACCESS_MODE=private_ro
```

### Private WO (только запись)

```bash
make minio-app-create APP=ingest ACCESS_MODE=private_wo
```

### Prefix-scoped (только `data/` внутри bucket)

```bash
make minio-app-create APP=appA PREFIX=data/
```

### Public read на prefix (анонимный GET, запись только приложению)

```bash
make minio-app-create APP=cdn PREFIX=public/ PUBLIC_READ=true
```

### Public list (анонимный LIST — делает содержимое “обнаруживаемым”)

```bash
make minio-app-create APP=publicbucket PUBLIC_LIST=true
```

### Features: quota + versioning + tags

```bash
make minio-app-create APP=logs QUOTA=50Gi VERSIONING=enable TAGS=env=prod,team=core
```

### Append: добавить второй бакет к тому же аккаунту

```bash
# создаёт user/policy и первый бакет
make minio-app-create APP=appA BUCKET=appA

# добавляет второй бакет (policy пересобирается по tracking secret в namespace minio)
make minio-app-append APP=appA BUCKET=appA-archive ACCESS_MODE=private_ro
```

## Требования

- Kubernetes (microk8s)
- Helm 3.x
- Docker
- helmfile
- kubectl
- Файл kubeconfig по пути **`k8s/config/<ENV>`** (переменная **`KUBECONFIG`** в корневом `Makefile`; без файла команды с `kubectl` завершатся ошибкой). Плейсхолдер: **`make env-new ENV=<env>`**, загрузка с ноды: **`make kubeconfig-fetch ...`**
- Для учёток приложений (**`apps/registry.yaml`**, merge, `make apps-apply`) — [**yq** mikefarah v4](https://github.com/mikefarah/yq) или **`./.tools/yq-mikefarah`**
- Для **infra-lab** (`node scripts/infra-lab.mjs`) — Node.js **18+** и **`npm install`** в корне репозитория (зависимость `@clack/prompts`)

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

- **`environments/<env>.mk`**: локальные секреты/переопределения окружения (SSH_HOST/SSH_KEY/KUBECONFIG/REGISTRY и т.п.). Создаётся: `make env-new ENV=<env>`.
- **`k8s/config/<env>`**: kubeconfig для окружения. Создаётся плейсхолдером: `make env-new ENV=<env>`, затем заполняется/скачивается: `make kubeconfig-fetch ENV=<env> ...` (см. `k8s/config/README.md`).
- **`<service>/images/*.tar`**: tar-файлы Docker образов для offline/registry. Создаются: `make images-save ENV=<env>` (или `make images-save ENV=<env> SERVICE=<service>`).
- **`environments/backups/`**: бэкапы Kubernetes secrets/configmaps сервисов. Создаются: `make env-backup ENV=<env> [CONFIRM=1]` (см. раздел "Бэкап конфигов/секретов").
- **`postgres/backups/`**: бэкапы PostgreSQL. Создаются `make postgres-backup ENV=...` или `make -C postgres backup ENV=...` (см. `postgres/README.md` и `postgres/BACKUP.md`).

Важно: **values-файлы, чарты и lock-файлы чартов (`Chart.lock`) коммитятся** — их намеренно не игнорируем, чтобы “чистый клон” работал одинаково у всех.

## Мониторинг (Netdata)

Netdata даёт наглядные метрики **CPU/память/диск/I/O/сеть/FD** как для ноды, так и для отдельных сервисов (по namespaces).
Сервис `netdata` управляется через `ENABLED_SERVICES` / `EXCLUDE_SERVICES`.

### Netdata без облака

В этой конфигурации Netdata работает **полностью автономно**, без Netdata Cloud:

- **UI и дашборды** — доступны по ingress или `make monitoring-port-forward` (порт 19999).
- **Метрики и алерты** — собираются и оцениваются локально в поде; алерты видны в разделе **Alarms** в UI.
- **Уведомления** — без облака можно настроить локально: exec-скрипты, webhooks, SMTP (см. ConfigMap `health_alarm_notify.conf` в разделе «Алертинг в Netdata»).

Netdata Cloud не подключается: в чарте нет claim-token и streaming. Для централизованных дашбордов и уведомлений через Slack/PagerDuty можно позже подключить облако по желанию.

### Установка

1. Проверьте hostname для ingress в `monitoring/netdata/values-$(ENV).yaml`:
   - `netdata.local.local` / `netdata.prod.local` — замените на свои домены.
2. Установите:
```bash
make monitoring-up ENV=local
```

### Доступ к UI

- Через ingress: `http(s)://<ваш-домен>`
- Или временно через port-forward:
```bash
make monitoring-port-forward ENV=local
```
Откройте: `http://localhost:19999`

**Вход без облака.** При первом открытии Netdata показывает экран «Welcome to Netdata» с предложением войти (Sign-in). Чтобы пользоваться дашбордом без регистрации и без Netdata Cloud, нажмите ссылку **Skip and use the dashboard anonymously** под кнопкой Sign-in — откроется полный дашборд с метриками и алертами, все данные остаются локально.

### Где смотреть метрики по сервисам

- Раздел **Kubernetes** → фильтры по namespace (`postgres`, `redis`, `kafka`, `rabbitmq`, `minio`, `clickhouse`).
- Раздел **Containers/Apps** → метрики конкретных pod’ов.

### Алертинг в Netdata

Netdata имеет **встроенную систему алертинга**.

#### Как это работает

Netdata автоматически отслеживает метрики и создаёт алерты при превышении пороговых значений. Алерты отображаются в UI Netdata в разделе **Alarms**.

#### Настройка алертов

Алерты настраиваются через конфигурационные файлы в директории `/etc/netdata/health.d/`. В текущей конфигурации используется базовый ConfigMap, но можно добавить кастомные правила алертинга.

**Пример добавления кастомных алертов** (через ConfigMap):

1. Расширьте `monitoring/netdata/netdata/templates/configmap.yaml`:

```yaml
data:
  netdata.conf: |
    [global]
      update every = {{ .Values.config.updateEvery }}
      memory mode = {{ .Values.config.memoryMode }}
      history = {{ .Values.config.history }}
  
  # Кастомные алерты
  custom-alerts.conf: |
    # Алерт на высокое использование CPU
    alarm: cpu_usage
      on: system.cpu
      lookup: average -10m percentage of user,system,softirq,irq
      every: 1m
      warn: $this > 80
      crit: $this > 95
      info: CPU usage is above threshold
    
    # Алерт на нехватку памяти
    alarm: memory_usage
      on: system.ram
      lookup: average -5m percentage of used
      every: 1m
      warn: $this > 85
      crit: $this > 95
      info: Memory usage is above threshold
```

2. Добавьте volume mount в deployment для кастомных конфигов (если нужно).

#### Уведомления

Netdata поддерживает отправку уведомлений через:
- **Netdata Cloud** (требует подписки) — централизованное управление алертами и уведомлениями через Slack, PagerDuty, email и др.
- **Локальные уведомления** — через exec скрипты, webhooks, email (SMTP)

**Настройка уведомлений через ConfigMap:**

```yaml
data:
  health_alarm_notify.conf: |
    # Email уведомления
    SEND_EMAIL="YES"
    DEFAULT_RECIPIENT_EMAIL="admin@example.com"
    
    # Slack webhook
    SLACK_WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
    
    # Custom exec script
    exec_alarm_notify_cmd="/path/to/script.sh"
```

#### Просмотр алертов

- В UI Netdata: раздел **Alarms** показывает активные алерты
- Через API: `http://<netdata-host>/api/v1/alarms?all`
- В логах: алерты логируются в `/var/log/netdata/error.log`

#### Отключение стандартных алертов

Если нужно отключить стандартные алерты Netdata, добавьте в ConfigMap:

```yaml
data:
  netdata.conf: |
    [health]
      enabled = yes
      # Отключить все стандартные алерты
      # health/conf.d/*.conf = DISABLED
```

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
