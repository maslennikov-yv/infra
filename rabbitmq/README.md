# RabbitMQ Chart для Kubernetes (Bitnami)

RabbitMQ standalone (`replicaCount: 1`, chart-default) на основе Bitnami chart.
Auth через `rabbitmqctl`, persistence для durable queues. Образы — из локального
registry microk8s (`localhost:32000/bitnami/*`).

## Требования

- Helm 3.x, kubectl, Docker.
- Secret `rabbitmq/rabbitmq` с двумя ключами:
  - `rabbitmq-password` (admin password, генерируется `make install`/`make up`);
  - `rabbitmq-erlang-cookie` (Erlang cluster cookie — критично для совместимости
    с PV mnesia при reinstall, см. BACKUP.md).

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
make rabbitmq-up ENV=local

# Или из rabbitmq/
make install ENV=local
```

> `make install` (как и корневой `make up`) сам создаёт Secret
> `rabbitmq/rabbitmq` со случайным `rabbitmq-password` (`openssl rand -hex 16`)
> и `rabbitmq-erlang-cookie` (`openssl rand -hex 32`), если ещё нет, плюс
> передаёт оба значения в чарт через `--set auth.password=...
> --set auth.erlangCookie=...` (Bitnami chart требует их для рендеринга).
> Прямой `helm install` потребует pre-existing Secret и явные `--set`.

После деплоя:
```bash
# Логи
make logs

# Shell в pod
make shell

# Management UI (port-forward)
kubectl port-forward -n rabbitmq svc/rabbitmq 15672:15672
# http://localhost:15672 (admin / <rabbitmq-password>)
```

## App accounts (изоляция по приложениям)

Каждому приложению — свой **vhost**, **user**, **permissions**. Пароль из
`apps/conf/<APP>/secrets.yaml` (`rabbitmq.password`).

```bash
# Из корня
make rabbitmq-app-create APP=myapp ENV=local              # vhost=myapp, user=app_myapp
make rabbitmq-app-show-creds APP=myapp ENV=local
make rabbitmq-app-verify    APP=myapp ENV=local           # smoke: authenticate_user + permissions
make rabbitmq-app-drop      APP=myapp ENV=local           # delete_vhost + delete_user + Secret

# Или из rabbitmq/
make app-create APP=myapp ENV=local
```

### Параметры `make app-create`

| Параметр | Дефолт | Назначение |
|---|---|---|
| `APP` | (обязательный) | Имя приложения |
| `APP_NS` | `<APP>` | Namespace для Secret |
| `APP_VHOST` | `<APP>` | Имя vhost в RabbitMQ |
| `APP_USER` | `app_<APP>` | Имя пользователя |

Пароль (`rabbitmq.password`) **обязателен** в `apps/conf/<APP>/secrets.yaml`.
Permissions — `.*` для configure/write/read внутри vhost (приложение полностью
изолировано в своём vhost).

Что попадает в Secret `<APP_NS>/<APP>-rabbitmq`:
- `RABBITMQ_HOST` (`rabbitmq.rabbitmq.svc.cluster.local`)
- `RABBITMQ_PORT` (5672), `RABBITMQ_MANAGEMENT_PORT` (15672)
- `RABBITMQ_VHOST` / `RABBITMQ_USERNAME` / `RABBITMQ_PASSWORD`
- `RABBITMQ_AMQP_URL` (`amqp://user:pass@host:5672/vhost`) — готовая URI

### Идемпотентность

Повторный `make app-create APP=myapp` корректно обновляет пароль (через
`rabbitmqctl change_password` если user уже есть, иначе `add_user`).
Vhost создаётся только если его нет (`list_vhosts | grep -Fx ... || add_vhost`).

Пароль передаётся в pod через positional argv (`bash -c '...' bash $vhost
$user $password`), не через shell-string interp — пароли с `'`/`"`/`\`/`$`
обрабатываются без проблем.

## Бэкапы и восстановление

`make backup-defs` экспортирует **definitions** (vhosts + users + permissions
+ exchanges + queues + bindings + policies + parameters) через нативную
`rabbitmqctl export_definitions` в gzipped JSON. **Сообщения не бэкапятся**
— для durability нужен persistent queue + регулярный consumer; для DR
сообщений — federation/shovel/replication.

```bash
make backup-defs           ENV=local        # backups/rabbitmq-defs-*.json.gz
make list-backups
make restore-defs          BACKUP_FILE=backups/rabbitmq-defs-…json.gz ENV=local
```

`restore-defs` идемпотентен (`rabbitmqctl import_definitions` делает merge).
После restore запустите `make apps-apply ENV=… ENABLED_SERVICES=rabbitmq`
— SHA256-хэши паролей в архиве могут отличаться от текущих в `apps/conf/`.

Полный disaster-recovery flow (включая `rabbitmq-erlang-cookie` через
`env-restore`) — см. **[BACKUP.md](BACKUP.md)**.

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

Теги в `rabbitmq/Makefile` (переопределяются через `RABBITMQ_TAG` /
`OS_SHELL_TAG`):

1. **bitnami/rabbitmq** — RabbitMQ 4.x (`4.1.3-debian-12-r1`)
2. **bitnami/os-shell** — init container для volumePermissions

Source-образы тянутся из `docker.io/bitnamilegacy/*` (теги совпадают с
локальными — `*_SRC_TAG ?= $(*_TAG)`).

## Erlang cookie caveat

Bitnami chart использует `rabbitmq-erlang-cookie` для Erlang cluster identity.
Этот cookie записывается в Secret `rabbitmq/rabbitmq` (ключ
`rabbitmq-erlang-cookie`) и в `mnesia` на PV. **При несовпадении** Secret и PV
mnesia нода не стартует с ошибкой `cookie mismatch`.

Сценарии:
- **Полный DR на новый кластер** — восстановить Secret из `env-backup` ДО
  `make up`, иначе сгенерится новый cookie и старые PV не подхватятся.
- **Случайно удалили Secret** — пересоздать с тем же cookie (если есть
  бэкап) либо `make rabbitmq-down` + `kubectl delete pvc` (⚠ потеря
  durable queues + всех сообщений).

См. [BACKUP.md](BACKUP.md) — раздел «Известные ограничения».

## Standalone vs cluster

`replicaCount: 1` (chart-default) — single node:
- Persistence через PV сохраняет durable queues + сообщения при рестартах.
- Нет high availability — потеря ноды = downtime.
- При переходе на multi-node — настроить `replicaCount: 3` + `clustering.*`
  (см. chart values.yaml). Quorum queues или classic mirrored для HA сообщений.

## Дополнительно

- [BACKUP.md](BACKUP.md) — детально про backup и DR-сценарии (Erlang cookie,
  shovel/federation, dump через consumer).
- [Bitnami RabbitMQ Chart](https://github.com/bitnami/charts/tree/main/bitnami/rabbitmq).
- Корневой `CLAUDE.md` / `README.md` — общие соглашения.
