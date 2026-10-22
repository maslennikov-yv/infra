# Бэкапы и восстановление Redis (Valkey)

Сервис `redis` — **Valkey** standalone с **AOF persistence** (RDB save отключён через `valkeyConfig: save ""` в `values-*.yaml`). Бэкап делается **поверх** persistence: согласованный RDB-снимок через replication-protocol (`redis-cli --rdb -` в stdout — корень контейнера read-only), независимо от состояния AOF/RDB на диске.

> ⚠ **Формат RDB.** Снимки Valkey (RDB v11) и Bitnami Redis 8 (RDB v12) взаимно несовместимы: Valkey отвечает `Can't handle RDB format version 12`. Бэкапы, снятые до перехода на Valkey (`docs/runbooks/redis-to-valkey.md`), в Valkey не восстановить — только логическим копированием из поднятого Redis 8 (`scripts/redis-copy-keys.py`).

## Что попадает в бэкап

`make backup` (или `make redis-backup` из корня) создаёт **`redis/backups/<ENV>/redis-backup-YYYYMMDD-HHMMSS.tar.gz`** с:

- **`dump.rdb`** — бинарный RDB-снимок всех логических БД (через `redis-cli --rdb`).
- **`users.acl`** — выгрузка `ACL LIST` (все пользователи, их права, хэши паролей).
- **`info.txt`** — `INFO server` (версия Valkey, аптайм, uuid, для отладки восстановления).

Не попадает: AOF-файл, конфиг (`valkeyConfig` хранится в `values-*.yaml` и в git).

## Создание бэкапа

```bash
# Из корня репозитория
make redis-backup ENV=local

# Или из redis/
make backup ENV=local
```

```bash
# Кастомная директория
BACKUP_DIR=/var/backups/redis make backup ENV=local
```

Список существующих бэкапов:
```bash
make list-backups        # из redis/
```

## Восстановление ACL

`make restore-acl` парсит `users.acl` из архива и применяет каждую запись через `ACL SETUSER` в живом Redis. Пользователь `default` не трогается (его пароль приходит из Secret `redis/redis`, который восстанавливается отдельно через `env-restore`).

```bash
make restore-acl BACKUP_FILE=backups/local/redis-backup-20260508-143022.tar.gz ENV=local

# Без интерактивного подтверждения
make restore-acl BACKUP_FILE=... SKIP_CONFIRM=1 ENV=local
```

Это идемпотентно: повторный запуск не создаёт дублей, а обновляет правила существующих пользователей.

## Восстановление данных (RDB)

⚠️ Восстановление RDB **перезаписывает все ключи**. Делайте только при disaster recovery (новый кластер) или после согласия владельца данных.

```bash
make redis-restore-rdb ENV=local BACKUP_FILE=backups/local/redis-backup-YYYYMMDD-HHMMSS.tar.gz   # из корня
make restore-rdb      ENV=local BACKUP_FILE=backups/local/redis-backup-YYYYMMDD-HHMMSS.tar.gz   # из redis/
```

Что делает цель (вручную так же):

1. Проверяет заголовок снимка: `REDIS0012`+ (Redis 7.4+/8) — отказ, Valkey его не читает.
2. `scale 0` deployment `valkey`.
3. Временный под `rdb-restore` с **тем же образом** и PVC `valkey` (uid 1000): удаляет `appendonlydir`,
   кладёт `dump.rdb`, запускает `valkey-server --appendonly no` на этом файле, затем
   `CONFIG SET appendonly yes` — Valkey сам пишет корректный AOF (`appendonlydir/…base.rdb` + manifest),
   после чего останавливается.
4. `scale 1`. ACL восстанавливать не нужно: init-контейнер собирает aclfile из Secret `redis/redis` и
   `valkey-auth` при старте пода.

Почему не «просто положить `dump.rdb`»: при `appendonly yes` и отсутствии AOF Valkey (как и Redis 7+)
**игнорирует `dump.rdb` и стартует пустым** — молча. А снимок `--rdb` не годится базой multi-part AOF
(`Bad file format reading the append only file`). Проверено на valkey-bundle 9.1.3.

## Автоматизация (cron)

Для регулярных бэкапов на ноде с доступом к кластеру:

```cron
# /etc/cron.d/redis-backup — ежедневно в 03:30
30 3 * * * ubuntu cd /opt/infra && /usr/bin/make redis-backup ENV=prod >> /var/log/redis-backup.log 2>&1
```

Ротация — стандартная (`logrotate` для логов; для архивов — `find redis/backups/prod -name 'redis-backup-*.tar.gz' -mtime +14 -delete`).

## Что бэкап **не** покрывает

- **Логические БД через REDIS_DB** — отдельные `<APP>:` префиксы в одной physical database. Все они одновременно попадают в один RDB-снимок и восстанавливаются вместе.
- **Sentinel** — не используется (standalone).
- **Repl-state** — реплики не используются (`replica.enabled: false`).
- **Конкретные клиентские connections / pub-sub каналы** — runtime state не персистится.
