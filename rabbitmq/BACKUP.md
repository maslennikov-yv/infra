# Бэкапы и восстановление RabbitMQ

В этой инфраструктуре RabbitMQ работает **standalone** с persistence (durable queues + classic mirrored нет — single node). `make backup-defs` нативно экспортирует все definitions через `rabbitmqctl export_definitions`. **Сообщения в очередях не бэкапятся**: для durability нужен persistent queue + регулярный consumer; для disaster recovery сообщений — отдельный механизм (federation, shovel, replication).

## Что попадает в бэкап definitions

`make rabbitmq-backup-defs ENV=...` (или `make backup-defs` из `rabbitmq/`) создаёт **`rabbitmq/backups/rabbitmq-defs-YYYYMMDD-HHMMSS.json.gz`** — gzip-сжатый JSON с:

- **`vhosts`** — все virtual hosts.
- **`users`** — пользователи + хэши паролей (формат `rabbit_password_hashing_sha256`).
- **`permissions`** — права (`configure / write / read` regex) для каждой связки vhost+user.
- **`exchanges`** — все exchanges (direct/fanout/topic/headers/x-*) кроме default `""`.
- **`queues`** — все очереди (durable/transient, arguments).
- **`bindings`** — все bindings exchange→queue/exchange.
- **`parameters`** + **`policies`** + **`global_parameters`** — runtime параметры (например, `ha-mode`, federation upstreams).
- **`topic_permissions`** — права на topic exchange (если используются).

## Что **не** попадает

- **Сообщения и состояние очередей** — ack/unack offset, in-flight messages.
- **Erlang cluster cookie** — хранится в Secret `rabbitmq/rabbitmq` (ключ `rabbitmq-erlang-cookie`); бэкапится через `make env-backup`.
- **Plugins-state** — конфиги enabled плагинов в `rabbitmq.conf` / `enabled_plugins`; задаются в `rabbitmq/values-*.yaml` через `extraConfiguration` / `plugins`.

## Создание бэкапа

```bash
# Из корня репозитория
make rabbitmq-backup-defs ENV=local

# Или из rabbitmq/
make backup-defs ENV=local
```

Список существующих:
```bash
make list-backups        # из rabbitmq/
```

## Восстановление definitions

`make restore-defs` использует `rabbitmqctl import_definitions`, который выполняет **idempotent merge**:
- новые vhosts / users / queues / exchanges / bindings — добавляются;
- существующие — **не пересоздаются** (т.е. queue с тем же именем не будет очищена);
- хэши паролей пользователей применяются как есть из бэкапа.

```bash
make rabbitmq-restore-defs BACKUP_FILE=rabbitmq/backups/rabbitmq-defs-20260508-143022.json.gz ENV=local

# Без подтверждения
make rabbitmq-restore-defs BACKUP_FILE=... SKIP_CONFIRM=1 ENV=local
```

⚠️ **`apps-apply` после restore.** Если бэкап старее, чем `apps/conf/<APP>/`, в нём могут быть устаревшие хэши паролей. Чтобы привести пользователей приложений в актуальное состояние:

```bash
make apps-apply ENV=local ENABLED_SERVICES=rabbitmq
```

`apps-apply` для каждого `enabled: true` приложения вызывает `rabbitmq app-create`, который перепишет пароль пользователя на актуальный из `apps/conf/<APP>/secrets.yaml`.

## Восстановление сообщений в очередях

⚠️ Это отдельная процедура — сообщения не входят в `export_definitions`.

### Вариант A: durable queues + регулярный consumer (preventive)

Все важные очереди должны быть `durable: true`, и сообщения — `persistent: true` (delivery_mode=2). Тогда при restart pod'а с persistence PV сообщения сохраняются. Это **не disaster recovery** на новый сервер, но защищает от обычных рестартов.

### Вариант B: shovel / federation на резервный кластер

Настроить `rabbitmq_shovel` plugin для копирования сообщений из критичных очередей в резервный RabbitMQ. Требует второго cluster и не входит в скоуп этой инфры.

### Вариант C: dump-out через consumer

Для оффлайн-дампа очереди:

```bash
# Через rabbitmqadmin (CLI инструмент):
kubectl exec -n rabbitmq rabbitmq-0 -- rabbitmqadmin -u admin -p $ADMIN_PW \
  get queue=my_queue ackmode=ack_requeue_false count=1000 > /tmp/dump.json
```

Восстановление:
```bash
kubectl exec -i -n rabbitmq rabbitmq-0 -- rabbitmqadmin -u admin -p $ADMIN_PW \
  publish exchange="" routing_key=my_queue payload="..."
```

Для serious data — используйте Variant B.

## Disaster recovery (новый сервер с нуля)

1. Восстановить Secret `rabbitmq/rabbitmq` (содержит admin password + erlang-cookie) из `make env-backup` **до** `make up`. Без правильного erlang-cookie новый кластер не сможет прочитать существующий PV (mnesia).
   ```bash
   kubectl apply -f environments/backups/<env>-YYYYMMDD/rabbitmq-secrets.yaml
   ```
2. `make up ENV=<env>` — поднимает RabbitMQ с восстановленным Secret.
3. `make rabbitmq-restore-defs BACKUP_FILE=...` — восстановить vhosts, users, queues, bindings.
4. `make apps-apply ENV=<env> ENABLED_SERVICES=rabbitmq` — обновить пароли пользователей приложений.

## Автоматизация (cron)

```cron
# /etc/cron.d/rabbitmq-backup-defs — ежедневно в 03:50
50 3 * * * ubuntu cd /opt/infra && /usr/bin/make rabbitmq-backup-defs ENV=prod >> /var/log/rabbitmq-backup-defs.log 2>&1
```

Ротация:
```bash
find rabbitmq/backups -name 'rabbitmq-defs-*.json.gz' -mtime +14 -delete
```

## Известные ограничения

- **Erlang cookie несовпадение** — приведёт к failed bootstrap при старте на существующем PV. Симптом: `Connection failed: cookie mismatch`. Решение: восстановить Secret `rabbitmq/rabbitmq` из `env-backup` до `make up`, или сделать `make rabbitmq-down` + `kubectl delete pvc -n rabbitmq --all` (⚠ потеря всех данных) и запустить с нуля.
- **Quorum queues** — при single-node имеют те же гарантии, что classic durable. При переходе на cluster mode нужны минимум 3 узла для quorum.
- **Streams** — `import_definitions` не восстанавливает stream offsets; consumer стартует с начала.
- **Plugins** — если бэкап содержит policies/parameters, использующие плагины (например, `x-message-ttl` или `federation-upstream`), убедитесь что плагин включён в `values-*.yaml` через `plugins:`.
