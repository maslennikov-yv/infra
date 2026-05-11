# Kafka Chart для Kubernetes (Bitnami, KRaft)

Kafka на основе Bitnami chart: **KRaft** (без ZooKeeper) с 3 controller-pod в prod
и 1 — в local. Авторизация: `SASL_PLAINTEXT` + `SCRAM-SHA-256` для клиентов,
`PLAINTEXT` для controller/interbroker (chicken-egg для KRaft + ACL обходится
через `super.users: User:user1;User:ANONYMOUS`). ACL включён через
`StandardAuthorizer` с `allow.everyone.if.no.acl.found: false` — каждое
приложение получает SCRAM-учётку и явные ACL по префиксу топиков/групп
(`<APP>.`). Образы — из локального registry microk8s
(`localhost:32000/bitnami/*`).

## Требования

- Helm 3.8+, kubectl, Docker, microk8s.
- `python3` + `openssl` — для генерации `kafka-kraft` (cluster-id, controller IDs)
  и SCRAM-паролей в `secrets-init`.
- Локальный registry microk8s (или fallback через containerd).

## Подготовка образов

```bash
microk8s enable registry
make images-sync          # pull → tag → push в localhost:32000/bitnami/*
```

Полный набор tar для оффлайн-стенда:
```bash
make images-pull images-save              # положит tar в images/
# на целевой машине:
make images-sync-from-files               # load → tag → push
```

## Деплой

### Первичная установка (рекомендуется через bootstrap)

KRaft + SCRAM имеет chicken-egg при первой установке: чтобы создать SCRAM-юзеров,
нужен живой брокер; чтобы брокер стартовал с включённым `StandardAuthorizer` и
непустым ACL, нужны юзеры. `make bootstrap` это закрывает:

```bash
# Из корня репозитория (рекомендуется)
make kafka-up ENV=local
# или для bootstrap-сценария:
make -C kafka bootstrap ENV=local

# Из kafka/
make bootstrap ENV=local
```

`bootstrap` под капотом:
1. `secrets-init` — создаёт `kafka-kraft` (cluster-id + controller IDs) и
   `kafka-user-passwords` (admin SCRAM-пароль), если их ещё нет.
2. `helm install` с `values-bootstrap.yaml` (без `StandardAuthorizer`),
   ожидание готовности controller-StatefulSet.
3. `helm upgrade` на `values-$(ENV).yaml` — включает authorizer и ACL.

`make install` (упрощённая цель) сейчас тоже зависит от `secrets-init`, но
**не** делает bootstrap-flow с пере-upgrade — если authorizer был включён
сразу, и SCRAM-юзера ещё нет, кластер может не подняться. Поэтому для первой
установки используйте `bootstrap`, а `make install` — только для случаев,
когда вы уверены, что Secrets и values совместимы.

### Обновление и статус

```bash
make upgrade ENV=local       # helm upgrade на values-$(ENV).yaml
make status ENV=local        # release + поды + svc + PVC + StatefulSets
make logs                    # логи первого controller-pod
make shell                   # shell в первый controller-pod
```

## App accounts (изоляция по приложениям)

Создание SCRAM-учётки + ACL по префиксу топиков и групп (`<APP>.*`):

```bash
# Из корня
make kafka-app-create APP=myapp ENV=local
make kafka-app-show-creds APP=myapp ENV=local
make kafka-app-verify    APP=myapp ENV=local      # smoke: SASL/SCRAM auth + topic-list
make kafka-app-drop      APP=myapp ENV=local      # ACL + SCRAM user + Secret (⚠ y/N; SKIP_CONFIRM=1)
make kafka-app-print-env APP=myapp                # рекомендуемые env для приложения

# Или из kafka/
make app-create APP=myapp ENV=local
```

Что попадает в Secret `<APP_NS>/<APP>-kafka`:
- `KAFKA_BOOTSTRAP_SERVER` (`kafka.kafka.svc.cluster.local:9092`)
- `KAFKA_SECURITY_PROTOCOL` = `SASL_PLAINTEXT`
- `KAFKA_SASL_MECHANISM` = `SCRAM-SHA-256`
- `KAFKA_USERNAME` (`app_<APP>`) / `KAFKA_PASSWORD` (из `apps/conf/<APP>/`)
- `KAFKA_TOPIC_PREFIX` / `KAFKA_GROUP_PREFIX` (`<APP>.`) — приложение **обязано**
  префиксовать все имена топиков и consumer-группы (ACL это форсирует).

ACL-правила: `Read`/`Write`/`Describe`/`Create` на топики `<APP>.*` (prefixed)
и `Read`/`Describe` на группы `<APP>.*`. **Топики не удаляются** при `app-drop` —
данные сохраняются, удалять вручную через `kafka-topics.sh --delete`.

## Топики

```bash
make topic-create  APP=myapp TOPIC_SUFFIX=events PARTITIONS=6 \
                   CONFIGS='retention.ms=604800000,cleanup.policy=delete'
make topic-create  TOPIC=myapp.events PARTITIONS=6     # без APP-prefix builder
make topic-alter   TOPIC=myapp.events PARTITIONS=12
make topic-alter   TOPIC=myapp.events CONFIGS='max.message.bytes=1048576'
make topic-describe TOPIC=myapp.events
make topic-list    [PREFIX=myapp.]
```

Имя топика обязательно начинается с `<APP>.` (иначе ACL заблокирует доступ из
приложения).

## Бэкапы и восстановление

`make backup-meta` сохраняет **definitions** топиков + ACL + список SCRAM-юзеров
в `backups/<ENV>/kafka-meta-YYYYMMDD-HHMMSS.tar.gz`. **Содержимое топиков
(сообщения) не бэкапится** — для этого используется отдельный механизм
(MirrorMaker 2 / репликация на второй кластер).

```bash
make backup-meta              ENV=local
make list-backups
make restore-meta-topics      BACKUP_FILE=backups/local/kafka-meta-…tar.gz ENV=local
```

Полный disaster recovery (KRaft cluster-id, SCRAM creds через apps-apply,
сценарии A/B/C/D) — см. **[BACKUP.md](BACKUP.md)**.

## Полезные команды

```bash
make help                   # сводка по всем командам
make secrets-init           # создать kafka-kraft / kafka-user-passwords (idempotent)
make bootstrap ENV=local    # bootstrap-safe install (см. выше)
make reset                  # ⚠ DATA LOSS: KRaft PVCs + Secrets, для аварийки
make uninstall              # ⚠ удалит helm release; PVC и Secret kafka-kraft остаются
make images-verify          # проверить SRC-теги в bitnamilegacy
make check-registry         # доступность localhost:32000
make check-updates          # доступные версии чарта в bitnami
```

## Тестирование (smoke с user1)

```bash
make test-client-properties           # /tmp/client.properties
make test-create-topic                # тестовый топик `test-topic`
make test-producer                    # автопинги каждые 2с
make test-consumer [FROM_BEGINNING=true]
make test-clean                       # удалить тестовые поды и файлы
```

## Используемые образы

Теги в `kafka/Makefile` (переопределяются через `KAFKA_TAG`/`OS_SHELL_TAG`/
`KUBECTL_TAG`/`JMX_EXPORTER_TAG`):

1. **bitnami/kafka** — `4.0.0-debian-12-r10`
2. **bitnami/os-shell** — `12-debian-12-r51` (init container для volumePermissions)
3. **bitnami/kubectl** — `1.33.4-debian-12-r0` (chart hooks)
4. **bitnami/jmx-exporter** — `1.4.0-debian-12-r0` (metrics)

Source-образы тянутся из `docker.io/bitnamilegacy/*` по immutable `sha256-*`
тегам, перетегируются в `localhost:32000/bitnami/*`.

## StorageClass

`storageclass.yaml` — `local-path` provisioner для microk8s. Применяется
**только при ENV=local** через `make setup`. На prod-кластерах с собственным
default StorageClass этот файл применять не нужно.

## Дополнительно

- [BACKUP.md](BACKUP.md) — детально про backup-meta и DR-сценарии (включая
  KRaft cluster-id и совместимость PV/Secret).
- [Bitnami Kafka Chart](https://github.com/bitnami/charts/tree/main/bitnami/kafka).
- Корневой `CLAUDE.md` / `README.md` — общие соглашения.
