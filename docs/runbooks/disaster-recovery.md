# Disaster Recovery: восстановление окружения с нуля

Документ описывает **полное восстановление** окружения на новом сервере при условии, что у вас есть:

- Доступ к **git-репозиторию** этой инфраструктуры.
- **`env-backup`-архив** (`environments/backups/<env>/YYYYMMDD-HHMMSS.tar.gz`) — содержит платформенные Secrets, Secrets приложений, `apps/registry.yaml`, `apps/conf/<APP>/`. Создан через `make env-backup`.
- **Бэкапы данных** для сервисов, чьё состояние нужно восстановить (Postgres dump, Redis RDB, Kafka meta, MinIO meta, ClickHouse schemas, RabbitMQ definitions). См. `<service>/BACKUP.md`.
- (Опционально) **tar-файлы образов** (`<service>/images/*.tar`) — если `bitnamilegacy` к моменту восстановления может оказаться недоступен.

После прохождения runbook'а получите рабочий setup, идентичный исходному (с точностью до данных, которые есть в бэкапах).

## Префлайт: что нужно на стороне нового сервера

| Артефакт | Где взять | Есть в env-backup? |
|---|---|---|
| Git-клон репо (включая `helmfile.yaml.gotmpl`, чарты, скрипты) | `git clone …` | нет (внешнее) |
| `environments/<env>.mk` (SSH_HOST, SSH_KEY, REGISTRY) | от существующего админа (см. [onboarding-admin.md](../onboarding-admin.md)) | нет |
| `k8s/config/<env>` (kubeconfig) | `make kubeconfig-fetch` или передача от админа | нет |
| `apps/registry.yaml` | git **или** env-backup-архив | да |
| `apps/conf/<APP>/*.yaml` (пароли приложений) | env-backup-архив | да |
| Платформенные Secrets (`redis/redis`, `rabbitmq/rabbitmq`, `kafka/kafka-kraft`, `postgres-postgresql`, `minio/minio`, `clickhouse/clickhouse`) | env-backup-архив | да |
| Application Secrets (`<APP>-postgres`, `<APP>-redis`, ...) | env-backup-архив (после Этапа 3) | да |
| Бэкапы данных | `<service>/backups/<env>/*` или внешнее хранилище | нет |
| tar-файлы образов | `<service>/images/*.tar` | нет |

**Без env-backup и `apps/conf/`** восстановление возможно, но придётся заново сгенерировать пароли приложений и обновить кэширующих клиентов — стек поднимется с **новыми кредами**, а не идентичным.

---

## Шаг 0. Подготовить новый сервер

```bash
# 1. Клонировать репозиторий
git clone <git-url-of-this-repo> /opt/infra
cd /opt/infra

# 2. Проверить тулинг (kubectl, helm, helmfile, yq, jq, ...)
make tools-check
# Если что-то < минимума — установите через apt/snap/asdf.
```

**Получить от существующего админа** (по защищённому каналу — см. [onboarding-admin.md](../onboarding-admin.md)):
- `environments/<env>.mk` — переменные окружения (SSH_HOST, SSH_KEY, REGISTRY, KUBECONFIG).
- env-backup-архив (`environments/backups/<env>/YYYYMMDD-HHMMSS.tar.gz`).
- (Опционально) tar-образы и postgres-бэкапы, если они не поедут отдельно.

```bash
# Сохранить полученные файлы:
mkdir -p environments/backups/<env> k8s/config
cp /received/<env>.mk environments/<env>.mk
cp /received/YYYYMMDD-HHMMSS.tar.gz environments/backups/<env>/
```

---

## Шаг 1. Установить microk8s и аддоны

```bash
make microk8s-setup ENV=<env>
```

Цель идемпотентна: проверяет аддоны (`registry`, `dns`, `ingress`, `storage`, `metrics-server`), включает недостающие, ставит docker.

---

## Шаг 2. Получить kubeconfig

```bash
# Удалённый сервер (через SSH_HOST из environments/<env>.mk):
make kubeconfig-fetch ENV=<env>

# Локальный microk8s (без SSH):
make kubeconfig-microk8s-local ENV=<env>

# Проверить:
make kubeconfig-info ENV=<env>
```

---

## Шаг 3. Восстановить образы в локальный registry

Если **есть tar-файлы**:

```bash
make images-push ENV=<env>          # docker load + tag + push в localhost:32000
# или для удалённого сервера:
make images-push-remote ENV=<env>   # scp + load + push на удалённой ноде
```

Если **нет tar-файлов** (но `bitnamilegacy` ещё доступен):

```bash
make images-save ENV=<env>          # скачает с docker.io/bitnamilegacy
make images-push ENV=<env>
```

**⚠ Если `bitnamilegacy` уже закрыли** и tar-файлов нет — стек запустить нельзя. Нужен альтернативный источник (private mirror, форк чартов на public alternative).

---

## Шаг 4. Восстановить env-backup (Secrets + apps/conf)

```bash
make env-restore \
  BACKUP_FILE=environments/backups/<env>/YYYYMMDD-HHMMSS.tar.gz \
  ENV=<env> \
  CONFIRM=1
```

Что произойдёт:
- Распакуется архив, покажется pre-flight summary (namespaces, secrets/configmaps, новые vs существующие apps/conf).
- Создадутся namespaces (`postgres`, `redis`, ..., `<app1>`, `<app2>`).
- Применятся **Secrets и ConfigMaps** платформенных и приложенческих namespaces (с фильтрацией `creationTimestamp`/`resourceVersion`/`uid`/`managedFields`/`ownerReferences`).
- Скопируется `apps/conf/<APP>/` для приложений, отсутствующих локально.
- Если `apps/registry.yaml` отсутствует локально — скопируется; если отличается — печатается diff-предупреждение, **не перезаписывается**.

⚠️ **Это критичный шаг.** Без него `make up` для MinIO/ClickHouse/Postgres попытается **сгенерировать новые** Secret-ы (см. Этап 1) — пароли изменятся, и старые клиенты не смогут подключиться. Для KRaft Kafka это вообще катастрофа: новый `cluster-id` не совпадёт с `meta.properties` на восстановленном PV → брокер не стартует. Делайте `env-restore` **до** `make up`.

---

## Шаг 5. Поднять стек

```bash
make up ENV=<env>
```

Что происходит:
- Корневой Makefile (Этап 1) видит, что Secrets `redis/redis`, `rabbitmq/rabbitmq`, `postgres-postgresql`, `minio/minio`, `clickhouse/clickhouse` уже есть (из env-restore) — генерация **пропускается**, используются восстановленные.
- Если `kafka` в активных — вызывается `kafka secrets-init` (идемпотентен, не пересоздаёт `kafka-kraft`).
- `helmfile apply` развёртывает все 7 релизов, ссылающихся на existingSecret.
- После helmfile автоматически запускается `apps-apply`: для каждого `enabled: true` в `apps/registry.yaml` — `<svc>-app-create`. Эти команды **обновляют пароли** в Secret приложения из `apps/conf/<APP>/secrets.yaml`. Если бэкап `apps/conf/` свежее, чем env-backup секретов в Kubernetes, пароли в k8s Secret приведутся в актуальное состояние.

Проверьте, что поды запустились:
```bash
make status ENV=<env>
```

---

## Шаг 6. Восстановить данные

Данные сервисов (объёмные) **не входят** в env-backup. Восстанавливаются отдельно из `<service>/backups/<env>/`:

### PostgreSQL
```bash
make postgres-restore BACKUP_FILE=postgres/backups/<env>/postgres-backup-YYYYMMDD-HHMMSS.sql.gz ENV=<env>
```
См. [postgres/BACKUP.md](../../postgres/BACKUP.md).

### Redis
```bash
# ACL применятся автоматически:
make redis-restore-acl BACKUP_FILE=redis/backups/<env>/redis-backup-YYYYMMDD-HHMMSS.tar.gz ENV=<env>
# Данные RDB — отдельная процедура (scale 0 + замена в PVC):
# см. redis/BACKUP.md, раздел «Восстановление данных (RDB)».
```

### Kafka
```bash
# Топики:
make kafka-restore-meta-topics BACKUP_FILE=kafka/backups/<env>/kafka-meta-YYYYMMDD-HHMMSS.tar.gz ENV=<env>
# ACL и SCRAM-пользователи — через apps-apply:
make apps-apply ENV=<env> ENABLED_SERVICES=kafka
# Данные сообщений (если важно) — через MirrorMaker; см. kafka/BACKUP.md.
```
⚠️ Если `kafka-kraft` Secret НЕ восстановлен из env-backup — см. сценарии A/B/C/D в [kafka/BACKUP.md](../../kafka/BACKUP.md), раздел «KRaft cluster-id и восстановление PV».

### MinIO
```bash
# Policies + tracking secrets:
make minio-restore-meta BACKUP_FILE=minio/backups/<env>/minio-meta-YYYYMMDD-HHMMSS.tar.gz ENV=<env>
# IAM users — через apps-apply (secret_keys из apps/conf/):
make apps-apply ENV=<env> ENABLED_SERVICES=minio
# Содержимое бакетов — отдельно (mc mirror или snapshot PV); см. minio/BACKUP.md.
```

### ClickHouse
```bash
# Schemas + users:
make clickhouse-restore BACKUP_FILE=clickhouse/backups/<env>/clickhouse-backup-YYYYMMDD-HHMMSS.tar.gz ENV=<env>
# После — apps-apply пересоздаёт пользователей с актуальными паролями:
make apps-apply ENV=<env> ENABLED_SERVICES=clickhouse
# Данные таблиц — отдельная процедура; см. clickhouse/BACKUP.md.
```

### RabbitMQ
```bash
# Definitions (vhosts/users/queues/bindings):
make rabbitmq-restore-defs BACKUP_FILE=rabbitmq/backups/<env>/rabbitmq-defs-YYYYMMDD-HHMMSS.json.gz ENV=<env>
# Сообщения в очередях — не восстанавливаются (durable persistence + federation; см. rabbitmq/BACKUP.md).
```

---

## Шаг 7. Проверка работоспособности

```bash
make doctor ENV=<env>
```

5 шагов диагностики:
1. **tools-check** — версии тулинга.
2. **kubectl cluster-info** — кластер доступен.
3. **helm vs helmfile** — все релизы задеплоены, нет лишних.
4. **rollout-статусы** — все StatefulSet/Deployment в `<readyReplicas>/<replicas>`.
5. **per-app smoke** — для каждого `enabled: true` приложения вызывается `<svc>-app-verify`.

Если `doctor` возвращает `✓` — восстановление успешно.

При фейлах:
- Проверьте `make status ENV=<env>` (поды, helm releases).
- Логи: `make <svc>-logs ENV=<env>`.
- События ноды: `make monitoring-pod-events ENV=<env> POD=<pod>`.

---

## Сценарии восстановления

### А. Полный disaster recovery (новый сервер, всё с нуля)

Шаги 0-7 в порядке. Это base-case этого документа.

### Б. Частичный recovery (потерян один сервис, остальное работает)

Например, потеряли PVC postgres, остальное работает.

```bash
make postgres-down ENV=<env>                  # удалить release
make postgres-delete-pvcs ENV=<env>           # удалить PVC (⚠)
make up ENV=<env> ENABLED_SERVICES=postgres   # поднять заново
make postgres-restore BACKUP_FILE=... ENV=<env>
make apps-apply ENV=<env> ENABLED_SERVICES=postgres
make doctor ENV=<env>
```

Для других сервисов аналогично, см. их BACKUP.md.

### В. Recovery после потери `apps/conf/<APP>/`

Если `apps/conf/<APP>/secrets.yaml` потерян, а в env-backup его нет (бэкап старый):

1. Сгенерируйте новые пароли вручную, запишите в `apps/conf/<APP>/secrets.yaml`.
2. `make apps-apply ENV=<env> ENABLED_SERVICES=...` — обновит Secret приложения и SCRAM/ACL/User в сервисе.
3. **Все клиенты приложения** должны подхватить новый Secret (rolling restart pods приложения).

### Г. Перенос на другой сервер (миграция, не восстановление)

То же что А, плюс предварительно:
- Сделать свежий `make env-backup` на источнике.
- Сделать свежие `make <svc>-backup*` для всех stateful сервисов.
- `make postgres-backup ENV=<env>` отдельно.

### Д. Восстановление одного приложения из per-app бэкапов

Если потеряны данные одного приложения (`APP=myapp`) — например, разработчик случайно удалил БД или bucket'у — есть точечный путь через `apps/backups/<ENV>/<APP>/`:

```bash
# Условие: бэкап есть в apps/backups/<env>/<app>/<svc>/<app>-<scope>-<TS>.<ext>
ls apps/backups/<env>/myapp/

# 1. Если учётка приложения утеряна (Secret <APP>-<svc> в кластере), сначала пересоздать её:
make apps-apply ENV=<env>                            # либо точечно: make pg-app-create APP=myapp ENV=<env>

# 2. Восстановить per-сервис (можно по одному):
make pg-app-restore        APP=myapp ENV=<env> BACKUP_FILE=apps/backups/<env>/myapp/postgres/myapp-db-<TS>.sql.gz
make clickhouse-app-restore APP=myapp ENV=<env> BACKUP_FILE=apps/backups/<env>/myapp/clickhouse/myapp-db-<TS>.tar.gz
make minio-app-restore     APP=myapp ENV=<env> BACKUP_FILE=apps/backups/<env>/myapp/minio/myapp-bucket-<TS>.tar.gz
make kafka-app-restore     APP=myapp ENV=<env> BACKUP_FILE=apps/backups/<env>/myapp/kafka/myapp-topics-<TS>.tar.gz
make rabbitmq-app-restore  APP=myapp ENV=<env> BACKUP_FILE=apps/backups/<env>/myapp/rabbitmq/myapp-defs-<TS>.json.gz

# 3. Smoke-проверка:
make doctor ENV=<env>
```

Что важно:
- **pg-app-restore**: применяет dump `pg_dump -d <APP_DB>` в существующую БД через `psql -v ON_ERROR_STOP=1`. Без `--clean` в дампе — при конфликте имён таблиц упадёт. Чистая ситуация — пустая БД (или дроп вручную перед restore: `make pg-app-drop APP=… && make pg-app-create APP=…`).
- **clickhouse-app-restore — destructive**: `DROP DATABASE … SYNC` + пересоздание из dump (Native data таблиц). Существующие данные БД безвозвратно теряются.
- **minio-app-restore**: upsert через `mc mirror` (объекты с одинаковыми ключами перезаписываются, лишние не удаляются).
- **rabbitmq-app-restore**: idempotent merge через `rabbitmqctl import_definitions` (новое добавится, существующее не пересоздаётся).
- **Содержимое топиков Kafka не в бэкапе** — `kafka-app-restore` пересоздаёт только definitions (--if-not-exists).
- **Redis** в per-app не входит (нет per-app единицы данных).
- Регулярный workflow: `make app-backup APP=myapp ENV=<env>` создаёт бэкапы для всех сервисов APP сразу (на основе merged конфига).

---

## Чек-лист после восстановления

- [ ] `make doctor ENV=<env>` → `✓ doctor: всё ок`
- [ ] Каждое приложение из `apps/registry.yaml` (`enabled: true`) подключается (smoke в doctor).
- [ ] Свежие данные в Postgres (`make pg-app-psql APP=… ENV=<env>` + проверочный `SELECT`).
- [ ] Свежий env-backup на новом сервере (`make env-backup ENV=<env> CONFIRM=1`) — для следующей итерации.
- [ ] Бэкапы перенесены в безопасное хранилище (НЕ только на этом же сервере — иначе при его потере всё снова теряется).

---

## Регулярная верификация бэкапов

Этот runbook описывает восстановление **после инцидента**. Чтобы убедиться, что бэкапы действительно восстановимы **до** инцидента (а не «бэкап есть, но битый»), запускайте регулярную автоматическую проверку:

```bash
make backup-verify SRC_ENV=prod DST_ENV=local APP=<app> CLEAN=1
```

Это разворачивает свежий бэкап источника в чистый DST_ENV, прогоняет тот же восстановительный flow что описан в этом runbook'е, и сравнивает structural fingerprint источника и цели. Подробности, чек-лист первого запуска и troubleshooting — [`backup-verify.md`](backup-verify.md).

**Важно**: backup-verify покрывает только **structural** соответствие (схема, ACL, topics, bucket-configs, vhosts). Данные для Redis/Kafka/MinIO/ClickHouse/RabbitMQ **не входят** в `*-backup-meta`, поэтому DST после verify имеет правильные definitions, но пустые данные. PostgreSQL — единственный сервис с полным data-backup через `pg_dumpall`. См. disclaimer в [`backup-verify.md`](backup-verify.md), раздел «Что покрывает и чего НЕ покрывает».

---

## Связанные документы

- [onboarding-admin.md](../onboarding-admin.md) — как новый админ получает файлы вне git.
- [`backup-verify.md`](backup-verify.md) — **регулярная проверка** восстановимости бэкапов (а не реактивный disaster recovery).
- `<service>/BACKUP.md` — детали backup/restore по сервисам (postgres, redis, kafka, minio, clickhouse, rabbitmq).
- `usage-scenarios.md` (этот же каталог) — обычные сценарии эксплуатации.
