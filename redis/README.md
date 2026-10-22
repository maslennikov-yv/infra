# Redis-сервис = Valkey (официальный чарт valkey-io/valkey-helm)

Сервис `redis` этого репо — **Valkey** (чарт `valkey-io/valkey-helm`, vendored в `redis/valkey/`,
release `valkey`, namespace `redis`). Bitnami Redis заморожен в `bitnamilegacy` без патчей — переход
описан в [docs/runbooks/redis-to-valkey.md](../docs/runbooks/redis-to-valkey.md).

- standalone (Deployment, `deploymentStrategy: Recreate` — PVC RWO), AOF persistence, PVC `valkey`
  (`keepPvc: true` — переживает `helm uninstall`);
- образ `valkey/valkey-bundle` (Valkey + `valkey-json`/`valkey-search` — замена ReJSON/RediSearch:
  `JSON.*` и `FT.*`, включая TEXT/NUMERIC/TAG-индексы), зеркало в `localhost:32000/valkey/*`;
- ACL (`auth.enabled: true`): пароль `default` — из Secret `redis/redis` (ключ `redis-password`),
  пользователи приложений — `auth.aclConfig` из overlay (см. ниже);
- логические БД (`databases 128`) распределяются между приложениями через `REDIS_DB`, изоляция — ACL по
  префиксу ключей/каналов `<APP>:*`;
- `redis-compat` (`redis/compat/`) — Service `redis-master` → поды Valkey, чтобы приложения, заведённые
  при Bitnami (`REDIS_HOST=redis-master.redis.svc…`), работали до своего рестарта/передеплоя.

Клиенты (phpredis, go-redis, ioredis, Laravel/Horizon) работают без изменений: протокол RESP и команды
совместимы, `redis-cli` в образе — симлинк на `valkey-cli`.

## Образы

```bash
make images-sync         # pull → tag → push в localhost:32000 (valkey-bundle, redis_exporter)
make images-pull images-save   # tar для оффлайн-стенда; на целевой машине: make images-sync-from-files
make images-verify       # проверить теги в docker.io/valkey и ghcr.io/oliver006
```

Теги — `VALKEY_TAG` / `REDIS_EXPORTER_TAG` в `redis/Makefile` и в `values-<ENV>.yaml`.

## Деплой

```bash
make redis-up ENV=local          # из корня: helmfile (valkey + redis-compat) + apps-apply
make install ENV=local           # из redis/: только helm upgrade --install valkey
```

`make up`/`make install` создают Secret `redis/redis` со случайным паролем, если его нет.

## App accounts

```bash
make redis-app-create     APP=myapp ENV=local              # REDIS_DB подберётся из apps/registry.yaml
make redis-app-create     APP=myapp REDIS_DB=5 ENV=local
make redis-app-show-creds APP=myapp ENV=local
make redis-app-verify     APP=myapp ENV=local              # smoke: PING + DBSIZE под APP-кредами
make redis-app-drop       APP=myapp ENV=local              # ⚠ y/N; SKIP_CONFIRM=1
```

Secret `<APP_NS>/<APP>-redis`: `REDIS_HOST` (`valkey.redis.svc.cluster.local`), `REDIS_PORT`,
`REDIS_USERNAME` (`app_<APP>`), `REDIS_PASSWORD`, `REDIS_KEY_PREFIX` (`<APP>:` — префиксовать ключи
обязательно), `REDIS_DB` (0..127).

ACL приложения: `~<APP>:* &<APP>:* +@all -ACL -CONFIG -SHUTDOWN -MODULE -DEBUG -COMMAND -KEYS -FLUSHALL
-FLUSHDB -LATENCY -MEMORY -MONITOR -SAVE -BGSAVE -BGREWRITEAOF -REPLCONF -REPLICAOF -SLAVEOF -SYNC -PSYNC`.

### Как ACL переживает рестарт пода

Источник истины — `apps/registry.yaml` + `apps/conf/<APP>/<ENV>/`, два пути применения:

1. **helm-render.** `scripts/redis-build-acl-overlay.sh` пересобирает `redis/values-<ENV>.acl.yaml`
   (gitignored) с `auth.aclConfig` — готовыми строками aclfile с sha256 паролей. helmfile подключает
   overlay к release `valkey`, чарт кладёт его в Secret `valkey-auth`, init-контейнер при каждом старте
   пода собирает `/etc/valkey/users.acl` = `user default …` + aclConfig. `make up`/`make diff` вызывают
   скрипт перед helmfile.
2. **runtime** (`scripts/redis-acl-reconcile.sh`, из `apps-apply` один раз после всех приложений):
   overlay → патч Secret `valkey-auth` → перезапись `/etc/valkey/users.acl` в поде → `ACL LOAD`.

Строки в обоих путях одинаковы, поэтому `helmfile diff` после reconcile нулевой. Ручная починка drift —
`make redis-acl-reconcile ENV=...`.

## Бэкапы

```bash
make backup ENV=local       # RDB-снимок Valkey + ACL LIST + INFO → backups/local/redis-backup-*.tar.gz
make list-backups
make restore-acl BACKUP_FILE=... ENV=local
```

RDB Valkey и RDB Redis 8 взаимно несовместимы — бэкапы, снятые до перехода, в Valkey не восстановить
(только логическое копирование, `scripts/redis-copy-keys.py`). Подробно — [BACKUP.md](BACKUP.md).

## Полезные команды

```bash
make status | logs | shell     # статус, логи, shell в поде valkey
make check-updates             # новая версия чарта valkey/valkey и где смотреть теги образа
make uninstall                 # ⚠ удалит release (PVC valkey останется)
```
