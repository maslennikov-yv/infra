# Redis Chart для Kubernetes (Bitnami)

Redis на основе Bitnami chart: `architecture: standalone`, AOF persistence,
ACL (`auth.acl.enabled: true`), фиксированные теги образов из локального
registry microk8s (`localhost:32000/bitnami/*`). Логические БД (`databases 128`)
распределяются между приложениями через `REDIS_DB` в `<APP>-redis` Secret —
изоляция дополняется ACL-префиксом по ключам (`<APP>:*`).

## Требования

- Helm 3.x
- Kubernetes (microk8s)
- Docker
- microk8s registry (или fallback через containerd, см. ниже)

## Подготовка образов для offline использования

### Способ 1: через microk8s registry (рекомендуется)

```bash
microk8s enable registry
make images-sync         # pull → tag → push в localhost:32000
```

Полный набор tar-файлов для оффлайн-стенда:
```bash
make images-pull images-save           # положит tar в images/
# на целевой машине:
make images-sync-from-files            # load → tag → push
```

### Способ 2: containerd напрямую (fallback)

`make images-pull` + `docker save | microk8s ctr image import -` под теги,
указанные в `values-<ENV>.yaml` (`localhost:32000/bitnami/*`). Это нужно
только если registry по какой-то причине недоступен.

## Деплой

```bash
# Из корня репозитория (рекомендуется)
make redis-up ENV=local

# Или из redis/
make install ENV=local
```

> `make install` (как и корневой `make up`) сам создаёт Secret `redis/redis`
> со случайным паролем admin'а через `openssl rand -hex 16`, если его ещё
> нет, и передаёт `global.redis.password` в чарт через `--set` (нужен для
> рендера `users.acl` при `auth.acl.enabled: true`). Прямой `helm install
> redis ./redis -f values-local.yaml` потребует pre-existing Secret и
> `--set global.redis.password=...` вручную.

Просмотр созданных ресурсов:
```bash
make status ENV=local
```

## App accounts (изоляция по приложениям)

Создание ACL-пользователя + Secret с кредами для приложения:
```bash
# Из корня
make redis-app-create APP=myapp ENV=local              # REDIS_DB подберётся из apps/registry.yaml
make redis-app-create APP=myapp REDIS_DB=5 ENV=local   # фикс. номер БД
make redis-app-show-creds APP=myapp ENV=local
make redis-app-verify    APP=myapp ENV=local           # smoke: PING + DBSIZE
make redis-app-drop      APP=myapp ENV=local           # ACL DELUSER + Secret (⚠ y/N; SKIP_CONFIRM=1)

# Или из redis/
make app-create APP=myapp ENV=local
```

Что попадёт в `<APP_NS>/<APP>-redis`:
- `REDIS_HOST` / `REDIS_PORT` — `*-master` сервис в namespace `redis`
- `REDIS_USERNAME` (`app_<APP>`) / `REDIS_PASSWORD`
- `REDIS_KEY_PREFIX` (`<APP>:`) — приложению **обязательно** префиксовать ключи
  (ACL `~<APP>:*` запрещает доступ к чужим)
- `REDIS_DB` — логический номер БД (0..127); опциональный, дефолт `0`

ACL-правила: `+@all -ACL -CONFIG -SHUTDOWN -MODULE -DEBUG -COMMAND -KEYS -FLUSHALL
-FLUSHDB -LATENCY -MEMORY -MONITOR -SAVE -BGSAVE -BGREWRITEAOF -REPLCONF
-REPLICAOF -SLAVEOF -SYNC -PSYNC`. Повторный `make app-create` идемпотентен
(используется `ACL SETUSER ... RESET ...`).

## Бэкапы и восстановление

```bash
make backup       ENV=local            # RDB-снимок + ACL + INFO в backups/redis-backup-*.tar.gz
make list-backups
make restore-acl  BACKUP_FILE=backups/redis-backup-YYYYMMDD-HHMMSS.tar.gz ENV=local
```

Восстановление RDB-данных — ручная процедура (scale 0 → замена в PVC),
см. **[BACKUP.md](BACKUP.md)** для пошагового сценария.

## Полезные команды

```bash
make help                   # сводка по всем командам
make status                 # helm status + поды + svc + PVC
make logs                   # логи master pod
make shell                  # interactive shell в master pod
make images-verify          # проверить SRC-теги bitnamilegacy
make check-updates          # доступные версии чарта в bitnami
make uninstall              # ⚠ удалит helm release (PVC останутся)
```

## Используемые образы

Теги фиксируются в `redis/Makefile`, при необходимости переопределяются
через `REDIS_TAG` / `REDIS_SENTINEL_TAG` / `REDIS_EXPORTER_TAG` /
`OS_SHELL_TAG` / `KUBECTL_TAG`:

1. **bitnami/redis** — основной образ Redis (по умолчанию `8.4.0`)
2. **bitnami/redis-sentinel** — Sentinel (по умолчанию `8.4.0`; в репо
   `sentinel.enabled: false`, образ нужен только для consistency rendering)
3. **bitnami/redis-exporter** — Prometheus exporter (по умолчанию `1.80.1`)
4. **bitnami/os-shell** — init container для volumePermissions (по умолчанию
   `12-debian-12-r51`; в репо `volumePermissions.enabled: false`)
5. **bitnami/kubectl** — для chart hooks (по умолчанию `1.35.0`)

Source-образы тянутся из `docker.io/bitnamilegacy/*` по immutable `sha256-*`
тегам (см. `*_SRC_TAG` в `Makefile`), затем перетегируются в
`localhost:32000/bitnami/*` под перечисленные выше теги.

## Дополнительно

- [BACKUP.md](BACKUP.md) — детально про backup/restore и DR-сценарии.
- [Bitnami Redis Chart](https://github.com/bitnami/charts/tree/main/bitnami/redis) — апстрим документация.
- Корневой `CLAUDE.md` / `README.md` — общие соглашения (envs, helmfile, apps-merge).
