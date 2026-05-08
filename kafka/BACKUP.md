# Бэкапы и восстановление Kafka

В этой инфраструктуре Kafka работает в **KRaft** (без ZooKeeper) с **SASL/SCRAM-SHA-256 + ACL** и развёрнута на bitnami chart. **`make backup-meta` бэкапит только definitions** — topics, configs, ACL, список SCRAM-пользователей. **Содержимое топиков (сообщения) не бэкапится**: для этого используется отдельный механизм (MirrorMaker, репликация на второй кластер) — он не входит в скоуп репозитория.

## Что попадает в meta-бэкап

`make kafka-backup-meta ENV=...` (или `make backup-meta` из `kafka/`) создаёт **`kafka/backups/kafka-meta-YYYYMMDD-HHMMSS.tar.gz`** с:

- **`topics.list`** — список всех топиков (включая internal, с префиксом `__`).
- **`topics-describe.txt`** — `kafka-topics.sh --describe` для всех топиков (partitions, replication factor, configs, replicas, ISR).
- **`topics-configs.txt`** — `kafka-configs.sh --describe --entity-type topics` (явные overrides, отдельно от дефолтов брокера).
- **`acls.txt`** — `kafka-acls.sh --list` для всех ресурсов.
- **`scram-users.txt`** — `kafka-configs.sh --describe --entity-type users` (только список пользователей, **хэши паролей не подходят для восстановления** — SCRAM-хэши не reversible).
- **`recreate-topics.sh`** — **готовый скрипт** для пересоздания топиков (генерируется при backup на основе `topics-describe.txt`, пропускает internal-топики `__*` и `_*`).

## Что **не** попадает в meta-бэкап

- **Сообщения в топиках** — для disaster recovery нужен отдельный механизм (MirrorMaker 2, второй cluster).
- **Consumer offsets** — хранятся в internal-топике `__consumer_offsets`, не восстанавливаются (потребители стартуют с `auto.offset.reset`).
- **KRaft cluster-id и controller-{0,1,2}-id** — критичные значения, хранятся в Secret `kafka/kafka-kraft`. Бэкапятся через `make env-backup` (платформенные Secrets), **не** через `backup-meta`. См. раздел «KRaft cluster-id».
- **SCRAM-пароли пользователей** — хэши экспортируются для аудита, но восстановление через них невозможно. Plaintext-пароли живут в `apps/conf/<APP>/secrets.yaml` и применяются заново через `apps-apply`.

## Создание бэкапа

```bash
# Из корня репозитория
make kafka-backup-meta ENV=local

# Или из kafka/
make backup-meta ENV=local
```

Список существующих бэкапов:
```bash
make list-backups        # из kafka/
```

## Восстановление топиков

`make restore-meta-topics` запускает helper-pod с kafka-image и выполняет `recreate-topics.sh`. Каждая команда — `kafka-topics.sh --create --if-not-exists`, поэтому существующие топики не пересоздаются и сохраняют свои данные.

```bash
make kafka-restore-meta-topics BACKUP_FILE=kafka/backups/kafka-meta-20260508-143022.tar.gz ENV=local

# Без интерактивного подтверждения
make kafka-restore-meta-topics BACKUP_FILE=... SKIP_CONFIRM=1 ENV=local
```

## Восстановление SCRAM-пользователей и ACL

⚠️ **Не из бэкапа.** Восстанавливаются через **`make apps-apply`**, который для каждого `enabled: true` приложения в `apps/registry.yaml` создаёт SCRAM-user и ACL заново (с paролем из `apps/conf/<APP>/secrets.yaml`). Это **обязательный** шаг при disaster recovery.

```bash
make apps-apply ENV=local ENABLED_SERVICES=kafka
```

Если пароль приложения сменился (потерян `apps/conf/<APP>/`), нужно сгенерировать новый и обновить кэширующие приложения.

## KRaft cluster-id и восстановление PV

Bitnami Kafka в KRaft-режиме хранит идентичность кластера в Secret **`kafka/kafka-kraft`** (ключи `cluster-id`, `controller-{0,1,2}-id`). На диске PV (`data-kafka-controller-N`) при первом запуске брокера записывается тот же `cluster-id` в `meta.properties`. **Если cluster-id в Secret не совпадает с meta.properties на PV — брокер не стартует.**

### Сценарии восстановления

**A. Полный disaster recovery (новый кластер, пустые PV).**
1. Восстановить Secret `kafka/kafka-kraft` из бэкапа `make env-backup` **до** `make up`:
   ```bash
   kubectl apply -f environments/backups/<env>-YYYYMMDD/kafka-secrets.yaml
   ```
2. `make up ENV=<env>` — кластер стартует с восстановленным cluster-id, ZP создадут meta.properties с этим же id.
3. `make kafka-restore-meta-topics BACKUP_FILE=...` — пересоздать топики.
4. `make apps-apply ENV=<env> ENABLED_SERVICES=kafka` — пересоздать SCRAM-users + ACL.

**B. Частичный disaster recovery (PV сохранились, Secret потерян).**
- Невозможен без вмешательства: cluster-id и controller-IDs в `meta.properties` PV не извлекаются обратным алгоритмом.
- Workaround: прочитать `meta.properties` из живого PV (`kubectl exec` в running pod, `cat /bitnami/kafka/data/meta.properties`) **до** того, как PV будет удалён, и из этого восстановить `cluster.id` в Secret.

**C. Частичный disaster recovery (Secret сохранился, PV потерян).**
- Поскольку PV пустой — Kafka запишет в новый `meta.properties` тот cluster-id, который в Secret. Стартует чисто. Но **данные топиков потеряны** (offsets, messages); требуется `restore-meta-topics` для recreate definitions.

**D. Несовпадение Secret и PV (после неаккуратного восстановления).**
- Pod не стартует, в логах: `The Cluster ID ... doesn't match stored clusterId ... in meta.properties`.
- Решение: либо поднять Secret из правильного бэкапа, либо `make kafka-reset` (⚠ **полная потеря данных** — удаляет PVC + Secret, заводит чистый кластер). После reset — `make apps-apply` для воссоздания учёток приложений.

## Бэкап содержимого топиков (опционально)

Не входит в `backup-meta`, но рекомендуемые подходы для важных данных:

- **MirrorMaker 2** — реплицировать топики в отдельный Kafka cluster (cold-standby).
- **`kafka-console-consumer.sh --from-beginning`** — выгрузить топик в файл (не подходит для больших объёмов и compacted-топиков).
- **`kafka-dump-log.sh`** — низкоуровневый дамп log-сегментов (для аудита, не для restore).

## Автоматизация (cron)

```cron
# /etc/cron.d/kafka-backup-meta — ежедневно в 03:35
35 3 * * * ubuntu cd /opt/infra && /usr/bin/make kafka-backup-meta ENV=prod >> /var/log/kafka-backup-meta.log 2>&1
```

Ротация:
```bash
find kafka/backups -name 'kafka-meta-*.tar.gz' -mtime +14 -delete
```

## Известные ограничения

- **Internal-топики** (`__consumer_offsets`, `__transaction_state`) пропускаются в `recreate-topics.sh` — они создаются Kafka автоматически.
- **Configs со значениями, содержащими запятую** (например, redash style — редкость) могут некорректно разобраться. После `restore-meta-topics` сверяйтесь с `topics-configs.txt` через `make topic-describe TOPIC=<name>`.
- **Recreate не применяет non-default configs** к **существующим** топикам. Если топик уже есть, но его конфиги дрейфнули, используйте `make topic-alter TOPIC=... CONFIGS=...`.
