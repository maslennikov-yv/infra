# Бэкапы и восстановление ClickHouse

В этой инфраструктуре `make backup` бэкапит **только schemas + users + grants** для всех пользовательских БД. **Данные таблиц не копируются** — они могут быть очень большими, и для них существуют отдельные механизмы (`BACKUP TO Disk()`, `SELECT INTO OUTFILE`, snapshot PV).

## Что попадает в schema-бэкап

`make clickhouse-backup ENV=...` (или `make backup` из `clickhouse/`) создаёт **`clickhouse/backups/clickhouse-backup-YYYYMMDD-HHMMSS.tar.gz`** с:

- **`databases.list`** — список пользовательских БД (исключая `system`, `INFORMATION_SCHEMA`, `default`).
- **`schemas/<db>.sql`** — `CREATE DATABASE IF NOT EXISTS` + `CREATE TABLE IF NOT EXISTS` для всех таблиц БД (Views/MaterializedViews пропускаются — они зависят от source-таблиц и пересоздаются вручную).
- **`users.sql`** — `CREATE USER` + `GRANT` для каждого non-system пользователя (исключая `default` и `admin`).
- **`info.txt`** — версия ClickHouse, timestamp.

## Что **не** попадает в schema-бэкап

- **Данные таблиц** — для disaster recovery нужен отдельный механизм (см. ниже).
- **`SHA256` хэши паролей пользователей** — не используются, т.к. восстановление идёт через `apps-apply` с plaintext-паролями из `apps/conf/<APP>/secrets.yaml`. (`SHOW CREATE USER` отдаёт `IDENTIFIED WITH ... BY '<sha256_hash>'`, но при `apps-apply` этот пользователь будет полностью пересоздан с правильным паролем.)
- **Views и MaterializedViews** — пропускаются в `backup`, потому что `SHOW CREATE` для MV в зависимости от движка может вернуть DDL, не работающий на пустой БД. Восстанавливайте их вручную после применения schemas.

## Создание бэкапа

```bash
# Из корня репозитория
make clickhouse-backup ENV=local

# Или из clickhouse/
make backup ENV=local
```

Список существующих:
```bash
make list-backups        # из clickhouse/
```

## Восстановление schemas + users

`make restore`:
1. Применяет каждый `schemas/<db>.sql` через `clickhouse-client --multiquery` (используются `IF NOT EXISTS`, поэтому не пересоздаёт существующие).
2. Перед каждым `CREATE USER` добавляет `DROP USER IF EXISTS`, затем создаёт заново — поэтому restore идемпотентен и для пользователей.

```bash
make clickhouse-restore BACKUP_FILE=clickhouse/backups/clickhouse-backup-20260508-143022.tar.gz ENV=local

# Без интерактивного подтверждения
make clickhouse-restore BACKUP_FILE=... SKIP_CONFIRM=1 ENV=local
```

⚠️ **`apps-apply` после restore.** Хэши паролей в `users.sql` восстанавливают пользователей с **прежними** хэшами; но Secret `<APP>-clickhouse` в namespace приложения может содержать **новый** пароль (если бэкап старее, чем `apps/conf/<APP>/`). После restore запустите `make apps-apply ENV=... ENABLED_SERVICES=clickhouse`, чтобы пересоздать пользователей с актуальными паролями из `apps/conf/`.

## Восстановление данных таблиц

⚠️ Это отдельная процедура. Варианты:

### Вариант A: `BACKUP TO Disk()` (нативно для ClickHouse 22.5+)

Требует настроенного backup disk в `config.xml`. Не используется по умолчанию в этой инфре. Если включить:

```sql
-- В config.xml добавить:
-- <backups>
--   <allowed_disk>backups</allowed_disk>
--   <allowed_path>/var/lib/clickhouse/backups/</allowed_path>
-- </backups>

BACKUP DATABASE my_db TO Disk('backups', 'my_db_2026_05_08.zip');
RESTORE DATABASE my_db FROM Disk('backups', 'my_db_2026_05_08.zip');
```

После этого скопировать архив на хост через `kubectl cp`.

### Вариант B: `SELECT INTO OUTFILE` + `INSERT INTO ... FROM INFILE`

Для отдельных таблиц:

```bash
kubectl exec -n clickhouse statefulset/clickhouse-shard0 -- \
  clickhouse-client -u admin --password $ADMIN_PW \
  --query "SELECT * FROM my_db.events INTO OUTFILE '/tmp/events.native' FORMAT Native"

kubectl cp clickhouse/clickhouse-shard0-0:/tmp/events.native /var/backups/events.native
```

Восстановление:
```bash
kubectl cp /var/backups/events.native clickhouse/clickhouse-shard0-0:/tmp/events.native
kubectl exec -n clickhouse statefulset/clickhouse-shard0 -- \
  clickhouse-client -u admin --password $ADMIN_PW \
  --query "INSERT INTO my_db.events FROM INFILE '/tmp/events.native' FORMAT Native"
```

⚠️ **Native** формат меняется между мажорными версиями ClickHouse. Для долгосрочного хранения используйте `JSONEachRow` или `Parquet`.

### Вариант C: snapshot PV (rsync-style)

Для microk8s со `storage` addon и hostpath-provisioner:

```bash
ssh <node> 'sudo systemctl stop snap.microk8s.daemon-kubelet'  # ⚠ остановит весь microk8s; для prod не подходит
ssh <node> 'sudo tar -czf /tmp/clickhouse-pvc.tar.gz -C /var/snap/microk8s/common/default-storage <pvc-dir>'
ssh <node> 'sudo systemctl start snap.microk8s.daemon-kubelet'
```

Это **не consistent** (если идут активные записи). Для consistency перед snapshot:
```sql
-- Внутри clickhouse pod:
SYSTEM SYNC REPLICA <table>;
SYSTEM STOP MERGES;  -- временно приостановить merges
-- сделать snapshot
SYSTEM START MERGES;
```

## Disaster recovery (новый сервер с нуля)

1. `make up ENV=<env>` — поднимает чистый ClickHouse (Secret `clickhouse/clickhouse` создаётся автогенерацией в корневом `make up` с Этапа 1).
2. `make clickhouse-restore BACKUP_FILE=...` — восстанавливает schemas + users.
3. `make apps-apply ENV=<env> ENABLED_SERVICES=clickhouse` — пересоздаёт пользователей приложений с правильными паролями.
4. (Опционально) Восстановить данные таблиц одним из вариантов выше.

## Автоматизация (cron)

```cron
# /etc/cron.d/clickhouse-backup — ежедневно в 03:45
45 3 * * * ubuntu cd /opt/infra && /usr/bin/make clickhouse-backup ENV=prod >> /var/log/clickhouse-backup.log 2>&1
```

Ротация:
```bash
find clickhouse/backups -name 'clickhouse-backup-*.tar.gz' -mtime +14 -delete
```

## Известные ограничения

- **Distributed-таблицы и shard topology** — для standalone (1 shard, 1 replica) не актуально, но при переходе на cluster mode потребуется отдельный бэкап системных таблиц replication.
- **Dictionaries** — `CREATE DICTIONARY` пропускается; восстанавливайте вручную.
- **`SHOW CREATE TABLE` с TTL/CODEC/PARTITION** — ClickHouse корректно сериализует, но проверьте после restore через `SHOW CREATE TABLE` повторно.
- **External tables (URL/S3/HDFS engines)** — DDL ссылается на внешние URLs/credentials; убедитесь, что они доступны в новом окружении.
