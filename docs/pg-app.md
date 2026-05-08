# Учётки приложений в кластере

Документ описывает **изоляцию учёток приложений** по переменной `APP`: отдельные Secret’ы в namespace приложения, доступ к общим сервисам данных в Kubernetes. Первый раздел — PostgreSQL; ниже — Redis, Kafka, MinIO, ClickHouse, RabbitMQ.

Корневые цели `make <service>-up`, `make *-app-create` и соседние команды используют тот же **`ENV`** и путь к kubeconfig (`k8s/config/$(ENV)` по умолчанию), что и в примерах ниже.

Цели **`make *-app-drop`** запрашивают подтверждение (`y/N`) перед удалением учётных данных и связанных Secret’ов. Для неинтерактивного запуска (CI, скрипты) задайте **`SKIP_CONFIRM=1`**. Для **MinIO** при **`MINIO_REMOVE_BUCKETS=1`** дополнительно спрашивается удаление bucket с данными (если не задан `SKIP_CONFIRM=1`); для удаления bucket на хосте нужен **`jq`** (разбор `buckets.json` из tracking Secret).

## Оглавление

- [Окружение и доступ](#окружение-и-доступ-к-кластеру)
- [PostgreSQL](#postgresql)
- [Redis](#redis)
- [Kafka](#kafka)
- [MinIO](#minio)
- [ClickHouse](#clickhouse)
- [RabbitMQ](#rabbitmq)

## Окружение и доступ к кластеру

**SSH и kubeconfig:** хост SSH, пользователь, ключ и путь kubeconfig задаются в `environments/$(ENV).mk` (создаётся `make env-new ENV=<env>`) или переменными в командной строке; см. корневой [README.md](../README.md). Файл kubeconfig по умолчанию: `k8s/config/$(ENV)`.

### Доступ к узлу кластера (SSH)

После того как в `environments/<env>.mk` заданы `SSH_HOST` и при необходимости `SSH_USER`, `SSH_KEY`, `SSH_PORT`:

```bash
make ssh ENV=<env>
```

Либо обычный `ssh` к тому же хосту, что указан в `SSH_HOST`.

### Окружения

| Что | Где задаётся |
|-----|----------------|
| Параметры SSH и registry | `environments/<env>.mk` |
| Kubeconfig для `kubectl` / `make` | `k8s/config/<env>` (часто заполняется `make kubeconfig-fetch ENV=<env>`) |

Конкретные имена окружений (`local`, `stage`, `prod`, …) — ваши; в примерах ниже для краткости используется `ENV=stage`.

### Переменная APP

`APP` — короткое имя приложения (латиница, как в поле **`name`** в [apps/registry.yaml](../apps/registry.yaml)). Среди записей с **`enabled: true`** имена **`name`** должны быть **уникальны** (проверяется при merge). Для большинства целей по умолчанию `APP_NS` совпадает с `APP` (можно переопределить `APP_NS=...`).

### Получить kubeconfig

Требуется непустой `SSH_HOST` (из `environments/<env>.mk` или `SSH_HOST=...` в командной строке):

```bash
make kubeconfig-fetch ENV=stage
```

---

## PostgreSQL

Кластерный PostgreSQL: развёртывание и создание отдельной БД и роли для приложения через цели `pg-app-*` (см. [postgres/Makefile](../postgres/Makefile)).

### Имена по умолчанию

| Сущность | Значение по умолчанию | Переопределение |
|----------|----------------------|-----------------|
| Namespace | `APP` | `APP_NS=...` |
| Secret | `<APP>-postgres` | `APP_SECRET_NAME=...` |
| База и роль | `app_<APP>` | `APP_DB=...`, `APP_USER=...` |

### Быстрые команды

```bash
# Проверить поды
make postgres-status ENV=stage

# Развернуть PostgreSQL
make postgres-up ENV=stage
```

### Создать БД и пользователя для приложения

Пример для приложения `myapp`:

```bash
make pg-app-create APP=myapp ENV=stage
```

При несовпадении пароля postgres в Secret и в БД:

```bash
make pg-app-create APP=myapp ENV=prod POSTGRES_ADMIN_PASSWORD='фактический_пароль_postgres'
```

После создания Secret `<APP>-postgres` в namespace `APP_NS` (по умолчанию совпадает с `APP`):

- `make pg-app-show-creds APP=myapp ENV=stage` — показать креды
- `make pg-app-verify APP=myapp ENV=stage` — проверить подключение
- `make pg-app-drop APP=myapp ENV=stage` — удалить БД, роль и Secret (подтверждение; `SKIP_CONFIRM=1` без запроса)

### Параметры подключения

Ниже — пример для `APP=myapp` (БД и пользователь `app_myapp`, Secret `myapp-postgres` в namespace `myapp`).

**Внутри кластера (из пода в Kubernetes)**

```
Host: postgres-postgresql.postgres.svc.cluster.local
Port: 5432
Database: app_myapp
User: app_myapp
Password: (из Secret myapp/myapp-postgres, ключ PGPASSWORD)
```

Connection string (с `sslmode=disable`):

```
postgresql://app_myapp:<password>@postgres-postgresql.postgres.svc.cluster.local:5432/app_myapp?sslmode=disable
```

Общий вид: `postgresql://app_<APP>:<password>@postgres-postgresql.postgres.svc.cluster.local:5432/app_<APP>?sslmode=disable`

**С локальной машины (port-forward)**

```bash
kubectl port-forward -n postgres svc/postgres-postgresql 5432:5432
```

Затем: `Host: localhost`, `Port: 5432`, те же БД/пользователь, пароль из Secret.

### Получение пароля из Secret

```bash
kubectl get secret myapp-postgres -n myapp -o jsonpath='{.data.PGPASSWORD}' | base64 -d
```

Или все креды одной командой:

```bash
make pg-app-show-creds APP=myapp ENV=stage
```

Полный connection string:

```bash
kubectl get secret myapp-postgres -n myapp -o jsonpath='{.data.DATABASE_URL}' | base64 -d
```

Для произвольного `APP` и namespace: `kubectl get secret <APP>-postgres -n <APP_NS> ...`

### Чеклист: PostgreSQL

1. Настроить `environments/<env>.mk` (`SSH_HOST`, при необходимости `SSH_USER`, `SSH_KEY`, …).
2. `make kubeconfig-fetch ENV=<env>`
3. `make images-save ENV=<env> SERVICE=postgres` (если образы ещё не на сервере)
4. `make images-push-remote ENV=<env> SERVICE=postgres`
5. `make postgres-up ENV=<env>`
6. `make pg-app-create APP=myapp ENV=<env>` (подставьте своё `APP` и `<env>`)

---

## Redis

**PostgreSQL** для приложений: отдельная БД и роль (`make pg-app-create`, см. выше). **Redis** — один инстанс на окружение: отдельной «БД» в смысле Postgres нет; изоляция — **ACL** на шаблон ключей и обязательный префикс `REDIS_KEY_PREFIX`. Дополнительно в Secret задаётся **логический номер БД** Redis (`REDIS_DB`, `SELECT n`): это не отдельный сервер и слабее изоляции Postgres (общий AOF, `FLUSHALL` затрагивает все логические БД). Основная гарантия по-прежнему **ACL + префикс ключей**.

Отдельный ACL-пользователь и ключи с префиксом `APP:`; см. [redis/Makefile](../redis/Makefile).

### Имена по умолчанию

| Сущность | Значение по умолчанию | Переопределение |
|----------|----------------------|-----------------|
| Namespace приложения | `APP` | `APP_NS=...` |
| Secret | `<APP>-redis` | `APP_SECRET_NAME=...` |
| Пользователь Redis | `app_<APP>` | `APP_USER=...` |
| Логический номер БД Redis | следующий свободный **1..127** по реестру или фолбэк **0** | при наличии **`apps/registry.yaml`** и **yq**: если **`redis_db`** у приложения не задан — назначается минимальный свободный в **1..127** (см. [`scripts/redis-next-db.sh`](../scripts/redis-next-db.sh)); если **`redis_db`** задан — используется он; **`REDIS_DB=...`** в CLI имеет приоритет; без реестра/yq — **`0`** |

### Команды

```bash
make redis-up ENV=stage
make redis-app-create APP=myapp ENV=stage
make redis-app-create APP=myapp ENV=stage REDIS_DB=3   # явное переопределение логической БД
make redis-app-show-creds APP=myapp ENV=stage
make redis-app-drop APP=myapp ENV=stage   # ACL-пользователь + Secret; ключи по префиксу не удаляются
```

Хост master-сервиса подставляется автоматически (точное имя — в Secret). Типичный вид: `redis-master.redis.svc.cluster.local`, порт `6379`. Приложение должно подключаться с `db`/параметром, соответствующим `REDIS_KEY_PREFIX` и `REDIS_DB` из Secret (если не `0` — выполнить `SELECT` или указать номер БД в клиенте).

### Ключи Secret

- `REDIS_HOST`, `REDIS_PORT`, `REDIS_USERNAME`, `REDIS_PASSWORD`
- `REDIS_KEY_PREFIX` — префикс ключей (`<APP>:`); изоляция через ACL.
- `REDIS_DB` — неотрицательное целое, логический номер БД Redis (если не задано в CLI — **следующий свободный 1..127** по реестру или явный **`redis_db`** в YAML, иначе фолбэк **`0`** без yq). Поле **`redis_db`** в реестре можно не указывать — тогда номер выделяется автоматически.

В [`redis/values-local.yaml`](../redis/values-local.yaml) и [`redis/values-prod.yaml`](../redis/values-prod.yaml) в `commonConfiguration` задано `databases 128` (вместо типичных **16** по умолчанию). При смене лимита или путей модулей синхронизируйте блок с `redis/redis/values.yaml` и пересоберите релиз Redis; не назначайте `REDIS_DB` выше `databases - 1`.

### Чеклист: Redis

1. `make kubeconfig-fetch ENV=<env>` (если ещё не сделано).
2. `make images-save ENV=<env> SERVICE=redis` и `make images-push-remote ENV=<env> SERVICE=redis` при необходимости.
3. `make redis-up ENV=<env>`
4. Запись для приложения в `apps/registry.yaml` с секретами в `apps/conf/<APP>/` (образец — [`apps/conf/_example/`](../apps/conf/_example/)); **`redis_db`** можно опустить — подставится следующий свободный номер.
5. `make redis-app-create APP=myapp ENV=<env>` (при необходимости `REDIS_DB=...` или `APPS_REGISTRY=...`)

---

## Kafka

Пользователь SCRAM и ACL по префиксам топиков и групп `$(APP).`; см. [kafka/Makefile](../kafka/Makefile).

### Имена по умолчанию

| Сущность | Значение по умолчанию | Переопределение |
|----------|----------------------|-----------------|
| Namespace приложения | `APP` | `APP_NS=...` |
| Secret | `<APP>-kafka` | `APP_SECRET_NAME=...` |
| Пользователь | `app_<APP>` | `APP_USER=...` |
| Префиксы топика и consumer group | `$(APP).` | задаются при создании Secret |

### Команды

```bash
make kafka-up ENV=stage
make kafka-app-create APP=myapp
make kafka-app-drop APP=myapp   # SCRAM, ACL, Secret; топики не удаляются
```

Bootstrap по умолчанию в кластере: `kafka.kafka.svc.cluster.local:9092` (см. `KAFKA_BOOTSTRAP_SERVER` в [kafka/Makefile](../kafka/Makefile)).

Создать топик под префикс приложения:

```bash
make kafka-topic-create APP=myapp TOPIC_SUFFIX=events PARTITIONS=3
```

Шаблон переменных окружения **без пароля** (имена топиков/групп):

```bash
make -C kafka app-print-env APP=myapp
```

Примеры клиентов: [examples/kafka/](../examples/kafka/).

### Ключи Secret

- `KAFKA_BOOTSTRAP_SERVER`, `KAFKA_SECURITY_PROTOCOL` (обычно `SASL_PLAINTEXT`), `KAFKA_SASL_MECHANISM` (`SCRAM-SHA-256`)
- `KAFKA_USERNAME`, `KAFKA_PASSWORD`
- `KAFKA_TOPIC_PREFIX`, `KAFKA_GROUP_PREFIX` — оба вида `myapp.` для `APP=myapp`

Примеры имён: топик `myapp.events`, группа `myapp.worker`.

### Чеклист: Kafka

1. `make kubeconfig-fetch ENV=<env>` при необходимости.
2. `make images-save ENV=<env> SERVICE=kafka` и `make images-push-remote ENV=<env> SERVICE=kafka` при необходимости.
3. `make kafka-up ENV=<env>`
4. `make kafka-app-create APP=myapp`
5. При необходимости `make kafka-topic-create APP=myapp TOPIC_SUFFIX=...`

---

## MinIO

Отдельный S3-пользователь, bucket и политика для приложения; см. [minio/Makefile](../minio/Makefile).

### Имена по умолчанию

| Сущность | Значение по умолчанию | Переопределение |
|----------|----------------------|-----------------|
| Namespace приложения | `APP` | `APP_NS=...` |
| Secret приложения | `<APP>-minio` | `APP_SECRET_NAME=...` |
| Bucket | `APP` | `BUCKET=...` |
| Ключи доступа | `ACCESS_KEY` по умолчанию `app_<APP>` | `ACCESS_KEY=...`, `SECRET_KEY=...` |

### Команды

```bash
make minio-up ENV=stage
make minio-app-create APP=myapp ENV=stage
make minio-app-drop APP=myapp ENV=stage
# с удалением bucket (второй запрос y/N): MINIO_REMOVE_BUCKETS=1 make minio-app-drop APP=myapp ENV=stage
```

Частые опции первого создания: `BUCKET=`, `PREFIX=`, `ACCESS_MODE=private_rw|private_ro|private_wo`, `PUBLIC_READ=true|false`, `PUBLIC_LIST=true|false`, `MINIO_SCHEME=http|https`, `APP_PUBLIC_ENDPOINT=https://files.example.com` (если снаружи другой URL, чем внутренний endpoint).

Добавить ещё один bucket/prefix к той же учётке (после `minio-app-create`):

```bash
make minio-app-append APP=myapp BUCKET=b2 PREFIX=data/
```

### Подключение

Внутренний endpoint попадает в Secret, например `http://minio.minio.svc.cluster.local:9000` (схема задаётся `MINIO_SCHEME`). В приложении обычно используют ключи, совместимые с AWS SDK: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `S3_BUCKET`, опционально `S3_PREFIX`, `AWS_REGION` (в Secret задаётся как `us-east-1`), плюс `MINIO_ENDPOINT` / `MINIO_PUBLIC_ENDPOINT` для presigned URL и браузера.

### Чеклист: MinIO

1. `make kubeconfig-fetch ENV=<env>` при необходимости.
2. `make images-save ENV=<env> SERVICE=minio` и `make images-push-remote ENV=<env> SERVICE=minio` при необходимости.
3. `make minio-up ENV=<env>`
4. `make minio-app-create APP=myapp ENV=<env>` (и при необходимости `minio-app-append`)

---

## ClickHouse

Отдельная БД и пользователь с паролем SHA256; см. [clickhouse/Makefile](../clickhouse/Makefile).

### Имена по умолчанию

| Сущность | Значение по умолчанию | Переопределение |
|----------|----------------------|-----------------|
| Namespace приложения | `APP` | `APP_NS=...` |
| Secret | `<APP>-clickhouse` | `APP_SECRET_NAME=...` |
| База | `APP` | `DB=...` |
| Пользователь | `app_<APP>` | `APP_USER=...` |

### Команды

```bash
make clickhouse-up ENV=stage
make clickhouse-app-create APP=myapp ENV=stage
make clickhouse-app-drop APP=myapp ENV=stage   # DROP DATABASE / USER + Secret
```

Опционально: `DB=...`, `APP_USER=...`, `APP_PASSWORD=...`, `ADMIN_USER=...` (по умолчанию админ из чарта — `admin`).

### Параметры подключения

Хост по умолчанию: `clickhouse.clickhouse.svc.cluster.local`.

- Native: порт `9000` — `CLICKHOUSE_PORT`
- HTTP: порт `8123` — `CLICKHOUSE_HTTP_PORT`

Ключи Secret: `CLICKHOUSE_HOST`, `CLICKHOUSE_PORT`, `CLICKHOUSE_HTTP_PORT`, `CLICKHOUSE_DB`, `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`.

### Чеклист: ClickHouse

1. `make kubeconfig-fetch ENV=<env>` при необходимости.
2. `make images-save ENV=<env> SERVICE=clickhouse` и `make images-push-remote ENV=<env> SERVICE=clickhouse` при необходимости.
3. `make clickhouse-up ENV=<env>`
4. `make clickhouse-app-create APP=myapp ENV=<env>`

---

## RabbitMQ

Отдельный vhost и пользователь; см. [rabbitmq/Makefile](../rabbitmq/Makefile).

### Имена по умолчанию

| Сущность | Значение по умолчанию | Переопределение |
|----------|----------------------|-----------------|
| Namespace приложения | `APP` | `APP_NS=...` |
| Secret | `<APP>-rabbitmq` | `APP_SECRET_NAME=...` |
| Vhost | `APP` | `APP_VHOST=...` |
| Пользователь | `app_<APP>` | `APP_USER=...` |

### Команды

```bash
make rabbitmq-up ENV=stage
make rabbitmq-app-create APP=myapp ENV=stage
make rabbitmq-app-drop APP=myapp ENV=stage   # vhost, пользователь, Secret (шаблон — один пользователь на приложение)
```

### Параметры подключения

Хост по умолчанию: `rabbitmq.rabbitmq.svc.cluster.local`, порт AMQP `5672`, management `15672`.

Ключи Secret: `RABBITMQ_HOST`, `RABBITMQ_PORT`, `RABBITMQ_MANAGEMENT_PORT`, `RABBITMQ_VHOST`, `RABBITMQ_USERNAME`, `RABBITMQ_PASSWORD`, `RABBITMQ_AMQP_URL` (полная строка `amqp://...`).

### Чеклист: RabbitMQ

1. `make kubeconfig-fetch ENV=<env>` при необходимости.
2. `make images-save ENV=<env> SERVICE=rabbitmq` и `make images-push-remote ENV=<env> SERVICE=rabbitmq` при необходимости.
3. `make rabbitmq-up ENV=<env>`
4. `make rabbitmq-app-create APP=myapp ENV=<env>`

---

## Сводка

Для каждого нужного сервиса выполните шаги из соответствующего чеклиста выше (`kubeconfig` → образы при необходимости → `*-up` → `*-app-create` и дополнительные команды сервиса).
