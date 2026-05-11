# Бэкапы и восстановление Redis

В этой инфраструктуре Redis работает в **standalone** с **AOF persistence** (RDB save отключён по умолчанию через `commonConfiguration: save ""` в `values-*.yaml`). Бэкап делается **поверх** persistence: создаётся согласованный RDB-снимок через replication-protocol (`redis-cli --rdb`), независимо от состояния AOF/RDB на диске.

## Что попадает в бэкап

`make backup` (или `make redis-backup` из корня) создаёт **`redis/backups/<ENV>/redis-backup-YYYYMMDD-HHMMSS.tar.gz`** с:

- **`dump.rdb`** — бинарный RDB-снимок всех логических БД (через `redis-cli --rdb`).
- **`users.acl`** — выгрузка `ACL LIST` (все пользователи, их права, хэши паролей).
- **`info.txt`** — `INFO server` (версия Redis, аптайм, uuid, для отладки восстановления).

Не попадает: AOF-файл, конфиг (`commonConfiguration` хранится в чарте/`values-*.yaml` и в git).

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

Bitnami Redis chart монтирует данные в `/data`. Чтобы заменить RDB:

1. **Остановить Redis** (scale to 0):
   ```bash
   kubectl scale -n redis statefulset/redis-master --replicas=0
   kubectl rollout status -n redis statefulset/redis-master --timeout=60s
   ```
2. **Скопировать `dump.rdb` в PVC через временный pod.** PVC называется `redis-data-redis-master-0` (по умолчанию).
   ```bash
   # Извлечь dump.rdb из бэкапа
   tar -xzf redis/backups/<env>/redis-backup-YYYYMMDD-HHMMSS.tar.gz -C /tmp dump.rdb

   # Запустить временный pod с тем же PVC
   kubectl -n redis run rdb-restore --image=busybox:1.36 --restart=Never \
     --overrides='{"spec":{"containers":[{"name":"rdb-restore","image":"busybox:1.36","command":["sh","-c","sleep 600"],"volumeMounts":[{"mountPath":"/data","name":"data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"redis-data-redis-master-0"}}]}}'
   kubectl -n redis wait pod/rdb-restore --for=condition=Ready --timeout=60s

   # Удалить старые AOF/RDB и положить новый dump.rdb
   kubectl -n redis exec rdb-restore -- sh -c 'rm -rf /data/appendonlydir /data/dump.rdb /data/appendonly.aof'
   kubectl -n redis cp /tmp/dump.rdb rdb-restore:/data/dump.rdb
   kubectl -n redis exec rdb-restore -- chown 1001:1001 /data/dump.rdb
   kubectl -n redis delete pod rdb-restore --ignore-not-found
   ```
3. **Поднять Redis обратно** (scale to 1):
   ```bash
   kubectl scale -n redis statefulset/redis-master --replicas=1
   kubectl rollout status -n redis statefulset/redis-master --timeout=120s
   ```
4. **Применить ACL из того же бэкапа**:
   ```bash
   make redis-restore-acl BACKUP_FILE=backups/local/redis-backup-YYYYMMDD-HHMMSS.tar.gz ENV=local
   ```

После запуска Redis при `appendonly yes` и непустом `dump.rdb` Redis сначала загрузит RDB, затем (если AOF включён) перепишет AOF из текущего состояния.

## Автоматизация (cron)

Для регулярных бэкапов на ноде с доступом к кластеру:

```cron
# /etc/cron.d/redis-backup — ежедневно в 03:30
30 3 * * * ubuntu cd /opt/infra && /usr/bin/make redis-backup ENV=prod >> /var/log/redis-backup.log 2>&1
```

Ротация — стандартная (`logrotate` для логов; для архивов — `find redis/backups/prod -name 'redis-backup-*.tar.gz' -mtime +14 -delete`).

## Что бэкап **не** покрывает

- **Логические БД через REDIS_DB** — отдельные `<APP>:` префиксы в одной physical database. Все они одновременно попадают в один RDB-снимок и восстанавливаются вместе.
- **Sentinel-конфиг** — в этой инфре `sentinel.enabled: false`.
- **Repl-state** — реплики не используются (`architecture: standalone`).
- **Конкретные клиентские connections / pub-sub каналы** — runtime state не персистится.
