# PostgreSQL Chart для Kubernetes (Bitnami)

PostgreSQL Helm chart на основе Bitnami с настройкой StatefulSet на 2 ноды.

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
make load-all
```

Эта команда выполнит:
- `pull-images` - скачает образы с hub.docker.com/u/bitnamilegacy
- `tag-images` - тегирует образы для local registry
- `push-images` - загрузит образы в microk8s registry

### Способ 2: Напрямую в containerd (без registry) - РЕКОМЕНДУЕТСЯ

Если registry не используется, можно импортировать образы напрямую в containerd. 
Этот способ автоматически тегирует образы с теми же именами, что используются в chart 
(`registry-1.docker.io/bitnami/*`), поэтому не нужно менять `values.yaml`:

```bash
make load-containerd
```

**Преимущества этого способа:**
- Не требует включения registry
- Образы тегируются под теми же именами, что в chart
- Не нужно изменять `values.yaml`

### Проверка загруженных образов

```bash
make list-images
```

## Использование

### Деплой PostgreSQL с 2 нодами

```bash
helm install postgres ./postgresql -f values-custom.yaml
```

### Использование с local registry

После загрузки образов через `make load-all`, образы будут доступны по адресу `localhost:32000/bitnami/*`.

Если используете microk8s registry, убедитесь что в `values-custom.yaml` указан:
```yaml
image:
  registry: localhost:32000
  repository: bitnami/postgresql
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
- `make pull-images` - Скачать все образы с Docker Hub
- `make tag-images` - Тегировать образы для local registry
- `make push-images` - Загрузить образы в microk8s registry
- `make load-all` - Выполнить все шаги (pull, tag, push)
- `make load-containerd` - Загрузить образы через containerd

### Сохранение и загрузка из файлов:
- `make save-images` - Сохранить все образы в tar файлы
- `make save-all` - Скачать и сохранить все образы в файлы (рекомендуется для оффлайн использования)
- `make load-from-files` - Загрузить все образы из tar файлов
- `make list-saved-images` - Показать список сохраненных tar файлов

### Утилиты:
- `make list-images` - Показать список загруженных образов в microk8s
- `make clean` - Удалить локальные Docker образы
- `make clean-images` - Удалить сохраненные tar файлы
- `make clean-all` - Удалить локальные образы и сохраненные файлы

## Используемые образы

Следующие Docker образы загружаются в local repository:

1. **bitnami/postgresql:latest** - Основной образ PostgreSQL
2. **bitnami/os-shell:latest** - Образ для volume permissions (init container)
3. **bitnami/postgres-exporter:latest** - Образ для метрик Prometheus (опционально)

## Сохранение образов в файлы

Для оффлайн использования или передачи образов на другой сервер:

```bash
# Скачать и сохранить все образы в tar файлы
make save-all
```

Образы будут сохранены в директории `images/`:
- `images/postgresql-latest.tar`
- `images/os-shell-latest.tar`
- `images/postgres-exporter-latest.tar`

### Использование сохраненных образов

На другом сервере или после очистки:

```bash
# Загрузить образы из файлов
make load-from-files

# Затем загрузить в containerd
make load-containerd
```

### Просмотр сохраненных образов

```bash
make list-saved-images
```

## Настройка тегов и директорий

Вы можете указать конкретные версии образов через переменные:

```bash
POSTGRESQL_TAG=16.1.0 make save-all
```

Или изменить адрес registry и директорию для образов:

```bash
REGISTRY=my-registry.local:5000 make load-all
IMAGES_DIR=/path/to/images make save-all
```

## App accounts (изоляция по приложениям)

Создание отдельной БД и роли для приложения, Secret с кредами в namespace приложения:

```bash
# Из корня репозитория
make pg-app-create APP=myapp ENV=stage
make pg-app-show-creds APP=myapp ENV=stage   # показать креды из Secret
make pg-app-drop APP=myapp ENV=stage         # удалить БД, роль и Secret
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

