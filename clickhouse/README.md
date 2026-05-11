# ClickHouse Chart для Kubernetes (Bitnami)

ClickHouse standalone (1 shard, 1 replica) на основе Bitnami chart.
ClickHouse Keeper отключён (`keeper.enabled: false`) — для standalone не нужен.
Образы — из локального registry microk8s (`localhost:32000/bitnami/*`).

## Требования

- Helm 3.x, kubectl, Docker.
- Аутентификация: SCRAM-style `sha256_password`. Пароль admin генерируется
  при первом `make install` через `openssl rand -hex 16`.

## Подготовка образов

```bash
microk8s enable registry
make images-sync                      # pull → tag → push в localhost:32000
```

Оффлайн:
```bash
make images-pull images-save          # tar в images/
make images-sync-from-files           # на целевой машине
```

## Деплой

```bash
# Из корня репозитория (рекомендуется)
make clickhouse-up ENV=local

# Или из clickhouse/
make install ENV=local
```

> `make install` (как и корневой `make up`) сам создаёт Secret
> `clickhouse/clickhouse` со случайным `admin-password` через `openssl rand
> -hex 16`, если его ещё нет. Прямой `helm install …` требует pre-existing
> Secret.

После деплоя:
```bash
kubectl exec -it -n clickhouse statefulset/clickhouse-shard0 -- \
  clickhouse-client --user admin \
  --password "$(kubectl get secret clickhouse -n clickhouse -o jsonpath='{.data.admin-password}' | base64 -d)"
```

## App accounts (изоляция по приложениям)

Базовый flow — пользователь ClickHouse с собственной БД, привязанный
к app-паролю из `apps/conf/<APP>/secrets.yaml` (через `apps-merge-config`).

```bash
# Из корня
make clickhouse-app-create APP=myapp ENV=local              # БД=myapp, user=app_myapp
make clickhouse-app-show-creds APP=myapp ENV=local
make clickhouse-app-verify    APP=myapp ENV=local           # smoke: SELECT 1
make clickhouse-app-drop      APP=myapp ENV=local           # DROP DATABASE + DROP USER + Secret

# Или из clickhouse/
make app-create APP=myapp ENV=local
```

### Параметры `make app-create`

| Параметр | Дефолт | Назначение |
|---|---|---|
| `APP` | (обязательный) | Имя приложения, используется в `<APP>-clickhouse` Secret |
| `APP_NS` | `<APP>` | Namespace для Secret приложения |
| `DB` | `<APP>` | Имя базы данных в ClickHouse |
| `APP_USER` | `app_<APP>` | Имя пользователя ClickHouse |
| `ADMIN_USER` | `admin` | Override admin user (нужно при кастомном `auth.username` в values) |

Пароль (`clickhouse.password`) **обязателен** в `apps/conf/<APP>/secrets.yaml`.
В отличие от postgres/redis, CLI-override `APP_PASSWORD=...` не предусмотрен.

Что попадает в Secret `<APP_NS>/<APP>-clickhouse`:
- `CLICKHOUSE_HOST` (`clickhouse.clickhouse.svc.cluster.local`)
- `CLICKHOUSE_PORT` (9000 — native), `CLICKHOUSE_HTTP_PORT` (8123)
- `CLICKHOUSE_DB` / `CLICKHOUSE_USER` / `CLICKHOUSE_PASSWORD`

### Идемпотентность

Повторный `make app-create APP=myapp` (например, после ротации пароля
в `apps/conf/`) корректно обновляет пароль через `CREATE USER IF NOT EXISTS`
+ `ALTER USER ... IDENTIFIED ...`. Пароль приложения SQL-эскейпится перед
подстановкой (одинарные кавычки → `''`, backslash → `\\`).

## Бэкапы и восстановление

`make backup` сохраняет **schemas + users + grants** для всех пользовательских
БД. **Данные таблиц не бэкапятся** (могут быть очень большими; для них
существуют `BACKUP TO Disk()`, `SELECT INTO OUTFILE`, snapshot PV — см. BACKUP.md).

```bash
make backup                ENV=local         # backups/local/clickhouse-backup-*.tar.gz
make list-backups
make restore               BACKUP_FILE=backups/local/clickhouse-backup-…tar.gz ENV=local
```

`restore` идемпотентен: schemas с `IF NOT EXISTS`, пользователи через
`DROP USER IF EXISTS` + `CREATE USER` (точные имена из `users.list`,
не парсинг SQL DDL).

⚠ После `restore` запустите `make apps-apply ENV=… ENABLED_SERVICES=clickhouse`
— SHA256-хэши паролей в архиве могут отличаться от текущих в
`apps/conf/<APP>/secrets.yaml`.

Полный disaster-recovery flow — см. **[BACKUP.md](BACKUP.md)**.

## Полезные команды

```bash
make help                   # сводка по всем командам
make status                 # helm + поды + svc + PVC
make logs                   # логи первого pod
make shell                  # shell в первый pod
make images-verify          # SRC-теги в bitnamilegacy
make check-registry         # localhost:32000
make check-updates          # доступные версии чарта в bitnami
make uninstall              # ⚠ удалит helm release; PVC и Secret останутся (с подтверждением)
```

## Используемые образы

Теги в `clickhouse/Makefile` (переопределяются через `CLICKHOUSE_TAG` /
`CLICKHOUSE_KEEPER_TAG` / `OS_SHELL_TAG`):

1. **bitnami/clickhouse** — основной образ ClickHouse (`25.7.5-debian-12-r0`)
2. **bitnami/clickhouse-keeper** — Keeper (`25.7.5-debian-12-r0`; в репо
   `keeper.enabled: false`, образ нужен только для consistency rendering)
3. **bitnami/os-shell** — init container для volumePermissions

Source-образы тянутся из `docker.io/bitnamilegacy/*` (теги совпадают с
локальными — `*_SRC_TAG ?= $(*_TAG)`), перетегируются в
`localhost:32000/bitnami/*`.

## Standalone vs cluster

`shards: 1`/`replicaCount: 1` зафиксированы в `values-{local,prod}.yaml`:
- На single-node microk8s cluster-mode (`shards: N`, `replicaCount: M`) не
  даёт выигрыша — все pod'ы на одной ноде.
- Standalone достаточен для текущей analytical нагрузки (см. Critical 2 в
  ревью — prod-профиль рассчитан на 16Gi PVC и 2GB heap).
- При переходе на multi-node кластер имеет смысл включить `keeper.enabled:
  true` и распределить shards/replicas через `podAntiAffinity`.

## Схема паролей

- **admin** — root user. Пароль в Secret `clickhouse/clickhouse` (ключ
  `admin-password`). Создаётся `make install` / `make up` через `openssl rand -hex 16`.
- **app_<APP>** — пользователь приложения. Пароль в `apps/conf/<APP>/secrets.yaml`
  (`clickhouse.password`). Применяется через `make app-create` /
  `make apps-apply`.
- **default** — встроенный пользователь чарта, доступ только из локальной
  сети pod'а.

## Дополнительно

- [BACKUP.md](BACKUP.md) — детально про backup и DR-сценарии (включая
  `BACKUP TO Disk()`, snapshot PV, ограничения Views/MaterializedViews).
- [Bitnami ClickHouse Chart](https://github.com/bitnami/charts/tree/main/bitnami/clickhouse).
- Корневой `CLAUDE.md` / `README.md` — общие соглашения.
