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
│   ├── values-dev.yaml
│   ├── values-prod.yaml
│   ├── values-stage.yaml
│   └── Makefile
├── redis/             # Redis (standalone)
│   ├── redis/         # Helm chart
│   ├── images/
│   ├── values-dev.yaml
│   ├── values-prod.yaml
│   └── Makefile
├── kafka/             # Kafka
│   ├── kafka/         # Helm chart
│   ├── images/
│   ├── values-dev.yaml
│   ├── values-prod.yaml
│   └── Makefile
├── rabbitmq/          # RabbitMQ
│   ├── rabbitmq/      # Helm chart
│   ├── images/
│   ├── values-dev.yaml
│   ├── values-prod.yaml
│   └── Makefile
├── clickhouse/        # ClickHouse (standalone)
│   ├── clickhouse/    # Helm chart
│   ├── images/
│   ├── values-dev.yaml
│   ├── values-prod.yaml
│   └── Makefile
├── minio/             # MinIO (S3)
│   ├── minio/         # Helm chart
│   ├── images/
│   ├── values-dev.yaml
│   ├── values-prod.yaml
│   └── Makefile
├── helmfile.yaml.gotmpl  # Развертывание всех сервисов
├── environments/      # Настройки окружений (dev/prod)
└── Makefile          # Корневые команды
```

## Быстрый старт

### 1. Подготовка образов (один раз)

Скачать и сохранить все образы в tar-файлы:

```bash
make images-save ENV=dev
```

Эта команда:
- Скачает образы из `bitnamilegacy` (или `bitnami` как fallback)
- Сохранит их в `*/images/*.tar`

### 2. Загрузка образов в microk8s registry

```bash
make images-push ENV=dev
```

Эта команда:
- Загрузит tar-файлы в Docker
- Перетегирует для `localhost:32000/bitnami/*`
- Загрузит в microk8s registry

### 3. Развертывание всех сервисов

```bash
make up ENV=dev
```

Или развернуть по отдельности:

```bash
# PostgreSQL
make postgres-up ENV=dev

# Redis
make redis-up ENV=dev

# Kafka
make kafka-up ENV=dev

# RabbitMQ
make rabbitmq-up ENV=dev

# ClickHouse
make clickhouse-up ENV=dev

# MinIO
make minio-up ENV=dev
```

## Основные команды

### Корневые команды (все сервисы сразу)

```bash
# Образы
make images-save ENV=dev      # Скачать/сохранить образы всех сервисов
make images-push ENV=dev      # Загрузить образы в registry
make images-push-remote ENV=dev  # Загрузить tar-файлы на удалённый сервер и опубликовать в его registry

# Развертывание
make up ENV=dev              # Развернуть все (dev)
make diff ENV=dev            # Показать изменения (dev)
make down ENV=dev            # Удалить все (dev)

make up ENV=prod             # Развернуть все (prod)

# Указать только устанавливаемые сервисы
make up ENV=dev ENABLED_SERVICES=postgres,redis    # Развернуть только postgres и redis
make up ENV=prod ENABLED_SERVICES=minio            # Развернуть только minio

# Исключить сервисы из развертывания (игнорируется если задан ENABLED_SERVICES)
make up ENV=dev EXCLUDE_SERVICES=kafka,clickhouse  # Развернуть все кроме kafka и clickhouse
make up ENV=prod EXCLUDE_SERVICES=minio            # Развернуть все кроме minio
```

#### Окружения (dev/prod/staging/…)

Все корневые команды принимают параметр `ENV=<name>`.

**Выбор сервисов для развертывания:**

Можно указать только устанавливаемые сервисы через `ENABLED_SERVICES` (приоритетнее, чем `EXCLUDE_SERVICES`):

```bash
make up ENV=dev ENABLED_SERVICES=postgres,redis
```

Или исключить отдельные сервисы через `EXCLUDE_SERVICES`:

```bash
make up ENV=dev EXCLUDE_SERVICES=kafka,clickhouse
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
- `k8s/config/staging` (файл-плейсхолдер под kubeconfig)
- `*/values-stage.yaml`, `*/values-staging.yaml` (копия values-dev.yaml или values-prod.yaml)

Скачать kubeconfig с удалённого microk8s по SSH:

```bash
make kubeconfig-fetch ENV=dev SSH_HOST=1.2.3.4 SSH_KEY=~/.ssh/id_ed25519
```

### Команды для отдельного сервиса

Зайти в директорию сервиса (`postgres/`, `redis/`, `kafka/`, `minio/`, `clickhouse/`) и использовать:

```bash
# Образы
make images-pull            # Скачать образы
make images-save            # Сохранить в tar
make images-load            # Загрузить из tar
make images-tag             # Перетегировать для registry
make images-push            # Загрузить в registry
make images-sync            # pull + tag + push
make images-sync-from-files # load + tag + push

# Helm (через helmfile)
make up                     # Развернуть/обновить
make diff                   # Показать изменения
make down                   # Удалить
make status                 # Статус

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
- Скачиваются из `bitnamilegacy` (fallback на `bitnami`)
- Сохраняются в `*/images/*.tar`
- Публикуются в `localhost:32000/bitnami/*` с фиксированными тегами

### 2. Values-файлы

Каждый сервис имеет два values-файла:
- `values-dev.yaml` - для dev окружения
- `values-prod.yaml` - для prod окружения
- `values-stage.yaml` - для stage окружения (если есть)

В них указано:
- `image.registry: localhost:32000` - использовать локальный registry
- `global.security.allowInsecureImages: true` - разрешить локальные образы
- Фиксированные теги образов

### 3. Helmfile

`helmfile.yaml.gotmpl` описывает все 5 релизов:
- Использует локальные чарты (`./postgres/postgresql`, `./redis/redis`, `./kafka/kafka`, `./minio/minio`, `./clickhouse/clickhouse`)
- Подставляет нужный values-файл в зависимости от окружения (`values-{{ $env }}.yaml`)

## Примеры использования

### Первая установка (с нуля)

```bash
# 1. Скачать образы
make images-save ENV=dev

# 2. Загрузить в registry
make images-push ENV=dev

# 3. Развернуть
make up ENV=dev
```

### Обновление после изменений

```bash
# Посмотреть что изменится
make diff ENV=dev

# Применить изменения
make up ENV=dev
```

### Работа с одним сервисом

```bash
cd postgres

# Скачать образы только для PostgreSQL
make images-save

# Загрузить в registry
make images-sync-from-files

# Развернуть
make up ENV=dev
```

## PostgreSQL: для приложений

Создание отдельной БД и роли для приложения, Secret с кредами:

```bash
make pg-app-create APP=myapp ENV=stage
make pg-app-show-creds APP=myapp ENV=stage   # показать креды
make pg-app-drop APP=myapp ENV=stage         # удалить БД, роль и Secret
make pg-app-verify APP=myapp ENV=stage       # проверить подключение
```

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

## Рекомендации по железу

Ориентиры по CPU/памяти основаны на текущих `values-*.yaml` и пресетах чартов. Реальные запросы смотрите в манифестах после `helmfile template` или в подах (`kubectl top pods -A`).

### Суммарно

| Окружение | Минимум (все сервисы + Netdata) | Рекомендуемый запас |
|-----------|---------------------------------|----------------------|
| **dev**   | 4 CPU, 8 Gi RAM                 | 4 CPU, 12 Gi RAM (запас для сборок, rollout) |
| **prod**  | 4 CPU, 12 Gi RAM                | 6+ CPU, 16 Gi RAM (пики, мониторинг, запас под Pending) |

- **Диск:** для каждого сервиса с `persistence.enabled: true` закладывайте объём из `persistence.size` в values (PostgreSQL, Kafka, MinIO, ClickHouse, RabbitMQ). Плюс место под образы и системные компоненты (registry, system pods).
- **Одна нода:** если все поды на одной ноде, учитывайте также потребление system pods и kubelet. При нехватке ресурсов поды остаются в Pending — смотрите `make monitoring-top-nodes` и события пода.

### По сервисам

| Сервис     | CPU (requests / limits) | Память (requests / limits) | Диск (persistence) | Примечание |
|------------|-------------------------|----------------------------|--------------------|------------|
| **PostgreSQL** | 250m / 500m         | 256Mi / 512Mi              | из `primary.persistence.size` | В values-dev/prod заданы явно. |
| **Redis**     | по пресету (nano ≈ 50m / 256Mi) | —                  | при включённой persistence | В values ресурсы не переопределены. |
| **Kafka**    | по пресету (small ≈ 256m / 512Mi на broker/controller) | — | data + logs PVC из chart | 1 broker в dev; при росте нагрузки увеличить replicas и ресурсы. |
| **MinIO**    | по пресету (micro ≈ 100m / 256Mi) | —                 | из `persistence.size` | Плюс консоль (console), если включена. |
| **ClickHouse** | по пресету (small ≈ 256m / 512Mi) | —               | 8Gi в values-dev | Keeper выключен в dev; при включении — отдельные запросы. |
| **RabbitMQ** | 250m / 1               | 512Mi / 1Gi                | из `persistence.size` | В values-prod заданы явно. |
| **Netdata**  | dev: 100m/500m, prod: 200m/1 | dev: 128Mi/512Mi, prod: 256Mi/1Gi | — | В values-dev/prod заданы явно. |

- **Где смотреть точные значения:** `*/values-dev.yaml`, `*/values-prod.yaml` (секции `resources`, `primary.resources`, `controller.resources`, `broker.resources` и т.п.). Если не задано — используются пресеты чарта (см. `resourcesPreset` в `*/chart/values.yaml`).
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
4. **Values-файлы не редактируются через sed** - используются отдельные файлы для dev/prod

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
   - `netdata.dev.local` / `netdata.prod.local` — замените на свои домены.
2. Установите:
```bash
make monitoring-up ENV=dev
```

### Доступ к UI

- Через ingress: `http(s)://<ваш-домен>`
- Или временно через port-forward:
```bash
make monitoring-port-forward ENV=dev
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
make images-save ENV=dev
```

### Helmfile не работает

```bash
# Проверить синтаксис
helmfile -f helmfile.yaml.gotmpl -e dev template

# Посмотреть что будет развернуто
helmfile -f helmfile.yaml.gotmpl -e dev diff
```

## Repository topics (discoverability)

Рекомендуемые теги для настроек репозитория на GitHub (About → Topics):

`kubernetes` `helm` `infrastructure` `microservices` `docker` `postgresql` `kafka` `minio` `redis` `rabbitmq` `clickhouse` `netdata` `microk8s`
