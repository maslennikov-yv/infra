# PostgreSQL Chart для Kubernetes (Bitnami)

PostgreSQL Helm chart на основе Bitnami: `architecture: standalone`, один primary,
фиксированные теги образов из локального registry microk8s (`localhost:32000/bitnami/*`).
Для HA нужно переходить на `architecture: replication` и явно настраивать `readReplicas`.

## Требования

- Helm 3.x
- Kubernetes кластер (microk8s)
- Docker
- microk8s registry (опционально)

## Подготовка образов для offline использования

Для исключения pull образов с внешних ресурсов, используйте Makefile для загрузки всех необходимых Docker образов в local repository (microk8s).

### Способ 1: Через microk8s registry

1. Включите registry в microk8s:
```bash
microk8s enable registry
```

2. Загрузите все образы:
```bash
make images-sync
```

Эта команда выполнит:
- `images-pull` - скачает образы с hub.docker.com/u/bitnamilegacy
- `images-tag` - тегирует образы для local registry
- `images-push` - загрузит образы в microk8s registry

### Способ 2: Напрямую в containerd (fallback, без registry)

Если по какой-то причине нельзя использовать microk8s registry, образы можно
импортировать напрямую в containerd:

```bash
make load-containerd
```

**⚠ Внимание:** этот способ тегирует образы как `registry-1.docker.io/bitnami/*`,
тогда как `values-<ENV>.yaml` в этом репозитории по умолчанию задают
`image.registry: localhost:32000` (`bitnami/postgresql:18.0.0` и т.п.). Чтобы
такой импорт сработал, надо либо:

- временно убрать (или переопределить) `image.registry` / `volumePermissions.image.registry`
  / `metrics.image.registry` в values на пустую строку, чтобы chart использовал
  свой дефолт `registry-1.docker.io`; либо
- использовать **Способ 1** (`make images-sync`) — тогда правки values не нужны,
  это и есть штатный путь репозитория.

### Проверка загруженных образов

```bash
make list-images
```

## Использование

### Деплой PostgreSQL (standalone, один primary)

```bash
helm install postgres ./postgresql -f values-local.yaml -n postgres
```

> `values-*.yaml` ссылаются на `existingSecret: postgres-postgresql` (с ключом
> `postgres-password`). Если запускать **прямой `helm install`**, как в команде
> выше, Secret должен уже существовать — иначе init-container зависнет в ожидании.
> `make install` (и корневой `make up` / `make postgres-up ENV=...`) сами создают
> этот Secret со случайным паролем при первом запуске, если его ещё нет, поэтому
> для штатной установки с нуля проще использовать их.

Для другого окружения подставьте свой файл: `values-<ENV>.yaml` из этого каталога (как в корневом `helmfile`).

### Использование с local registry

После загрузки образов через `make images-sync`, образы будут доступны по адресу `localhost:32000/bitnami/*`.

Если используете microk8s registry, убедитесь что в `values-<ENV>.yaml` указано
(теги — те же, что зафиксированы в `postgres/Makefile`):
```yaml
image:
  registry: localhost:32000
  repository: bitnami/postgresql
  tag: "18.0.0"
```

### Просмотр созданных ресурсов

```bash
kubectl get statefulset
kubectl get pods
kubectl get pvc
```

## Доступные команды Makefile

### Основные команды загрузки образов:
- `make help` - Показать справку по всем командам
- `make check-registry` - Проверить доступность microk8s registry
- `make images-pull` - Скачать все образы с Docker Hub
- `make images-tag` - Тегировать образы для local registry
- `make images-push` - Загрузить образы в microk8s registry
- `make images-sync` - Выполнить все шаги (pull, tag, push)
- `make load-containerd` - Загрузить образы через containerd

### Сохранение и загрузка из файлов:
- `make images-save` - Сохранить все образы в tar файлы
- `make images-load` - Загрузить все образы из tar файлов
- `make images-sync-from-files` - load → tag → push (без pull, для оффлайна)
- `make list-saved-images` - Показать список сохраненных tar файлов

### Утилиты:
- `make list-images` - Показать список загруженных образов в microk8s
- `make images-clean` - Удалить локальные Docker образы
- `make images-clean-files` - Удалить сохраненные tar файлы

## Используемые образы

Следующие Docker образы загружаются в local repository (теги фиксируются в
`postgres/Makefile`, при необходимости переопределяются переменными
`POSTGRESQL_TAG` / `OS_SHELL_TAG` / `POSTGRES_EXPORTER_TAG`):

1. **bitnami/postgresql** — основной образ PostgreSQL (по умолчанию `18.0.0`)
2. **bitnami/os-shell** — образ для volume permissions, init container
   (по умолчанию `12-debian-12-r51`)
3. **bitnami/postgres-exporter** — образ для метрик Prometheus, опциональный
   (по умолчанию `0.18.1`)

Source-образы тянутся из `docker.io/bitnamilegacy/*` по immutable `sha256-*`
тегам (`POSTGRESQL_SRC_TAG` / `POSTGRES_EXPORTER_SRC_TAG`), затем
перетегируются в `localhost:32000/bitnami/*` под перечисленные выше теги.

## Сохранение образов в файлы

Для оффлайн использования или передачи образов на другой сервер:

```bash
# Скачать и сохранить все образы в tar файлы
make images-pull && make images-save
```

Образы будут сохранены в директории `images/` под именами вида
`<image>-<POSTGRESQL_TAG>.tar` (теги — из `postgres/Makefile`):
- `images/postgresql-18.0.0.tar`
- `images/os-shell-12-debian-12-r51.tar`
- `images/postgres-exporter-0.18.1.tar`

### Использование сохраненных образов

На другом сервере или после очистки штатный путь — через локальный registry
(совпадает с тем, что задано в `values-<ENV>.yaml`):

```bash
# Загрузить образы из tar-файлов в docker
make images-load

# Перетегировать и запушить в localhost:32000
make images-tag
make images-push
# Или одной целью:
make images-sync-from-files
```

`make load-containerd` как fallback тоже работает, но требует правок
`image.registry` в values (см. **Способ 2** выше).

### Просмотр сохраненных образов

```bash
make list-saved-images
```

## Настройка тегов и директорий

Вы можете указать конкретные версии образов через переменные:

```bash
POSTGRESQL_TAG=16.1.0 make images-pull images-save
```

Или изменить адрес registry и директорию для образов:

```bash
REGISTRY=my-registry.local:5000 make images-sync
IMAGES_DIR=/path/to/images make images-pull images-save
```

## App accounts (изоляция по приложениям)

Создание отдельной БД и роли для приложения, Secret с кредами в namespace приложения:

```bash
# Из корня репозитория
make pg-app-create APP=myapp ENV=stage
make pg-app-show-creds APP=myapp ENV=stage   # показать креды из Secret
make pg-app-drop APP=myapp ENV=stage         # удалить БД, роль и Secret (y/N; SKIP_CONFIRM=1)
make pg-app-verify APP=myapp ENV=stage      # проверить подключение

# Или из postgres/
make app-create APP=myapp ENV=stage
make app-show-creds APP=myapp ENV=stage
make app-drop APP=myapp ENV=stage
make app-verify APP=myapp ENV=stage
```

При несовпадении пароля postgres в Secret и в БД: `make pg-app-create APP=myapp ENV=prod POSTGRES_ADMIN_PASSWORD='фактический_пароль'`

## Бэкапы и восстановление

### Создание бэкапов

```bash
# Из корня репозитория
make postgres-backup ENV=stage

# Или из postgres/
make backup ENV=stage
make backup-single DB_NAME=app_db ENV=stage
```

### Просмотр бэкапов (с потоковой декомпрессией)

```bash
make view-backup BACKUP_FILE=backups/postgres-backup-20231103.sql.gz
make view-backup-head BACKUP_FILE=backups/postgres-backup-20231103.sql.gz
make view-backup-search BACKUP_FILE=backups/postgres-backup-20231103.sql.gz SEARCH='CREATE TABLE'
make list-backups
```

### Восстановление

```bash
# Из корня репозитория
make postgres-restore BACKUP_FILE=backups/postgres-backup-20231103-143022.sql.gz ENV=stage

# Или из postgres/
make restore BACKUP_FILE=backups/postgres-backup-20231103.sql.gz ENV=stage
make restore-single BACKUP_FILE=backups/app_db-backup-20231103.sql.gz DB_NAME=app_db ENV=stage
```

### Пересоздание с новым размером PVC

StatefulSet не позволяет изменить размер тома после создания. Для смены размера:

```bash
make postgres-recreate-prep ENV=stage   # бэкап → down → удаление PVC
# Отредактировать postgres/values-stage.yaml: primary.persistence.size
make postgres-up ENV=stage
make postgres-restore BACKUP_FILE=backups/postgres-backup-YYYYMMDD-HHMMSS.sql.gz ENV=stage
```

📖 **Подробное руководство**: См. [BACKUP.md](BACKUP.md)

## Устранение сбоев

Для диагностики проблем используйте:

```bash
# Автоматическая диагностика (из postgres/)
make troubleshoot

# Или вручную
kubectl get pods,statefulset,svc,pvc -n postgres
kubectl describe pod <pod-name> -n postgres
kubectl logs <pod-name> -n postgres
```

📖 **Подробное руководство**: См. [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

### Быстрые команды для диагностики:

```bash
# Статус всех ресурсов
kubectl get all -n postgres

# Логи пода
kubectl logs postgres-postgresql-0 -n postgres -f

# Описание пода (события, ошибки)
kubectl describe pod postgres-postgresql-0 -n postgres

# Вход в контейнер
kubectl exec -it postgres-postgresql-0 -n postgres -- bash

# Последние события
kubectl get events -n postgres --sort-by='.lastTimestamp' | tail -20
```

## Дополнительная информация

- [Bitnami PostgreSQL Chart](https://github.com/bitnami/charts/tree/main/bitnami/postgresql)
- [Docker Hub - bitnamilegacy](https://hub.docker.com/u/bitnamilegacy)

