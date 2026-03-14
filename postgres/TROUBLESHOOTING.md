# Руководство по устранению сбоев PostgreSQL

## Быстрая диагностика

### 1. Проверка статуса всех ресурсов

```bash
# Общий статус всех ресурсов в namespace
kubectl get all -n postgres

# Детальная информация о подах, StatefulSet, Services, PVC
kubectl get pods,statefulset,svc,pvc -n postgres -o wide
```

### 2. Проверка событий (Events)

```bash
# Просмотр последних событий
kubectl get events -n postgres --sort-by='.lastTimestamp' | tail -20

# События для конкретного пода
kubectl describe pod <pod-name> -n postgres
```

---

## Типичные проблемы и решения

### Проблема 1: Pod в статусе Pending

**Симптомы:**
```
NAME                    READY   STATUS    RESTARTS   AGE
postgres-postgresql-0   0/1     Pending   0          5m
```

**Диагностика:**
```bash
# Проверить описание пода
kubectl describe pod postgres-postgresql-0 -n postgres

# Проверить события
kubectl get events -n postgres --field-selector involvedObject.name=postgres-postgresql-0
```

**Возможные причины и решения:**

1. **Нехватка ресурсов на нодах**
   ```bash
   # Проверить ресурсы нод
   kubectl top nodes
   kubectl describe nodes
   ```
   **Решение:** Освободить ресурсы или добавить ноды в кластер

2. **Проблемы с PVC (PersistentVolumeClaim)**
   ```bash
   # Проверить статус PVC
   kubectl get pvc -n postgres
   kubectl describe pvc data-postgres-postgresql-0 -n postgres
   ```
   **Решение:** 
   - Проверить наличие StorageClass: `kubectl get storageclass`
   - Проверить доступное место на нодах
   - При необходимости удалить и пересоздать PVC (⚠️ **потеря данных!**)

3. **NodeSelector/Taint не позволяют разместить под**
   ```bash
   kubectl describe pod postgres-postgresql-0 -n postgres | grep -A 5 "Node-Selectors\|Tolerations"
   ```

---

### pg-app-create: пароль postgres и проверка кредов

При создании роли и БД для приложения (`make pg-app-create APP=myapp ENV=...`) пароль суперпользователя postgres берётся в таком порядке:

1. **POSTGRES_ADMIN_PASSWORD** — если задан при вызове (ручной override).
2. **Файл в поде** — `kubectl exec ... cat /opt/bitnami/postgresql/secrets/postgres-password` (тот же источник, что использует процесс Postgres).
3. **Секрет Kubernetes** — ключ `postgres-password` в секрете `postgres-postgresql` в namespace `postgres`.

Если секрет в API не совпадает с реальным паролем в БД, задайте пароль явно:

```bash
make pg-app-create APP=mcp ENV=prod POSTGRES_ADMIN_PASSWORD='фактический_пароль_postgres'
```

После создания роли и Secret выполняется **проверка подключения** под ролью приложения (`SELECT 1`). Если она падает, выведется сообщение «Проверка подключения под ролью ... не удалась» — значит, роль или пароль в БД не совпадают с записанным в Secret; проверьте логи выше и при необходимости повторите вызов с правильным `POSTGRES_ADMIN_PASSWORD` или `APP_PASSWORD`.

Креды, которые записываются в Secret приложения, можно посмотреть командой `make pg-app-show-creds APP=myapp ENV=...`.

---

### Пересоздание StatefulSet с новым размером диска (PVC)

У StatefulSet нельзя изменить `volumeClaimTemplates` (в т.ч. размер тома) после создания. Чтобы выставить новый размер:

**Через make (из корня репозитория):**

```bash
# 1. Подготовка: бэкап → down → удаление PVC
make postgres-recreate-prep ENV=stage

# 2. Отредактировать postgres/values-stage.yaml: primary.persistence.size: 16Gi

# 3. Развернуть и восстановить
make postgres-up ENV=stage
make postgres-restore BACKUP_FILE=backups/postgres-backup-YYYYMMDD-HHMMSS.sql.gz ENV=stage
```

**Вручную:**

1. **Сделать бэкап** (обязательно, данные при пересоздании PVC теряются):
   ```bash
   make postgres-backup ENV=stage
   ```

2. **Удалить release** (StatefulSet и поды удалятся, PVC по умолчанию останутся):
   ```bash
   make postgres-down ENV=stage
   ```

3. **Удалить PVC** в namespace `postgres`:
   ```bash
   make postgres-delete-pvcs ENV=stage
   # или вручную: kubectl delete pvc -n postgres -l app.kubernetes.io/instance=postgres
   ```

4. **Задать новый размер** в `postgres/values-<env>.yaml`:
   ```yaml
   primary:
     persistence:
       size: 16Gi   # новый размер
   ```

5. **Развернуть заново** и при необходимости восстановить:
   ```bash
   make postgres-up ENV=stage
   make postgres-restore BACKUP_FILE=backups/postgres-backup-YYYYMMDD-HHMMSS.sql.gz ENV=stage
   ```

**Альтернатива — только увеличить диск** (без пересоздания): если StorageClass поддерживает расширение (`allowVolumeExpansion: true`), можно увеличить размер без удаления PVC:
   ```bash
   kubectl get storageclass
   kubectl edit pvc data-postgres-postgresql-0 -n postgres
   # Увеличить spec.resources.requests.storage (уменьшать нельзя).
   ```
   После этого файловая система внутри пода может потребовать расширения (например, `resize2fs`). Уменьшить размер тома без пересоздания PVC нельзя.

---

### Проблема 2: Pod в статусе ImagePullBackOff или ErrImagePull

**Симптомы:**
```
NAME                    READY   STATUS             RESTARTS   AGE
postgres-postgresql-0   0/1     ImagePullBackOff   0          3m
```

**Диагностика:**
```bash
kubectl describe pod postgres-postgresql-0 -n postgres | grep -A 10 "Events:"
```

**Решение:**

1. **Образы не загружены локально**
   ```bash
   # Загрузить образы в containerd
   make load-containerd
   
   # Или из файлов
   make load-from-files
   make load-containerd
   ```

2. **Проверить доступность образа**
   ```bash
   # Проверить образы в containerd
   make list-images
   
   # Или напрямую
   microk8s ctr images list | grep postgresql
   ```

3. **Импортировать образ вручную**
   ```bash
   # Если образ уже в Docker
   docker save bitnami/postgresql:latest | microk8s ctr image import -
   microk8s ctr image tag bitnami/postgresql:latest registry-1.docker.io/bitnami/postgresql:latest
   ```

---

### Проблема 3: Pod в статусе CrashLoopBackOff

**Симптомы:**
```
NAME                    READY   STATUS             RESTARTS   AGE
postgres-postgresql-0   0/1     CrashLoopBackOff   5          10m
```

**Диагностика:**
```bash
# Просмотр логов текущего контейнера
kubectl logs postgres-postgresql-0 -n postgres

# Просмотр логов предыдущего контейнера (если был перезапуск)
kubectl logs postgres-postgresql-0 -n postgres --previous

# Детальная информация о поде
kubectl describe pod postgres-postgresql-0 -n postgres
```

**Возможные причины:**

1. **Проблемы с правами доступа к PVC**
   ```bash
   # Проверить права на volume
   kubectl exec -it postgres-postgresql-0 -n postgres -- ls -la /bitnami/postgresql
   ```
   **Решение:** Убедиться что `volumePermissions.enabled: true` в values или включить вручную

2. **Некорректная конфигурация PostgreSQL**
   ```bash
   # Проверить конфигурацию
   kubectl exec -it postgres-postgresql-0 -n postgres -- cat /opt/bitnami/postgresql/conf/postgresql.conf | head -20
   ```

3. **Проблемы с паролями**
   ```bash
   # Проверить секреты
   kubectl get secret postgres-postgresql -n postgres -o yaml
   ```

---

### Проблема 4: Pod зависает в статусе ContainerCreating

**Диагностика:**
```bash
kubectl describe pod postgres-postgresql-0 -n postgres
```

**Возможные причины:**

1. **Проблемы с init containers (volume permissions)**
   ```bash
   # Проверить статус init containers
   kubectl get pod postgres-postgresql-0 -n postgres -o jsonpath='{.status.initContainerStatuses[*]}'
   ```

2. **Медленная загрузка образов**
   - Убедиться что образы загружены локально: `make list-images`

3. **Проблемы с сетью (pull секреты)**
   ```bash
   kubectl get secrets -n postgres | grep image-pull
   ```

---

### Проблема 5: StatefulSet не создает все реплики

**Симптомы:**
```
NAME                  READY   AGE
postgres-postgresql   1/2     15m
```

**Диагностика:**
```bash
# Проверить статус StatefulSet
kubectl describe statefulset postgres-postgresql -n postgres

# Проверить статус всех подов
kubectl get pods -n postgres -l app.kubernetes.io/name=postgresql
```

**Решение:**

1. **Проверить условия готовности первого пода**
   - Первый под (postgres-postgresql-0) должен быть Ready перед созданием второго

2. **Проверить ресурсы**
   ```bash
   kubectl top pods -n postgres
   ```

3. **Удалить проблемный под (если нужно)**
   ```bash
   # StatefulSet автоматически пересоздаст под
   kubectl delete pod postgres-postgresql-1 -n postgres
   ```

---

### Проблема 6: Проблемы с подключением к базе данных

**Диагностика:**
```bash
# Проверить доступность сервиса
kubectl get svc -n postgres

# Проверить эндпоинты
kubectl get endpoints postgres-postgresql -n postgres

# Тест подключения из другого пода
kubectl run postgres-client --rm -it --restart=Never -n postgres \
  --image=registry-1.docker.io/bitnami/postgresql:latest \
  --env="PGPASSWORD=$(kubectl get secret postgres-postgresql -n postgres -o jsonpath='{.data.password}' | base64 -d)" \
  -- psql --host postgres-postgresql.postgres.svc.cluster.local -U app_user -d app_db
```

**Решение:**

1. **Проверить NetworkPolicy**
   ```bash
   kubectl get networkpolicy -n postgres
   kubectl describe networkpolicy <policy-name> -n postgres
   ```

2. **Проверить порт-forward для локального теста**
   ```bash
   kubectl port-forward svc/postgres-postgresql -n postgres 5432:5432
   ```

---

### Проблема 7: Потеря данных / Проблемы с PVC

**Диагностика:**
```bash
# Проверить статус PVC
kubectl get pvc -n postgres

# Проверить привязанный PV
kubectl get pv

# Проверить данные в поде
kubectl exec -it postgres-postgresql-0 -n postgres -- ls -lh /bitnami/postgresql/data
```

**⚠️ ВАЖНО: Удаление PVC приведет к потере данных!**

**Восстановление:**

1. **Бэкап данных (если под работает)**
   ```bash
   # Создать бэкап через kubectl exec
   kubectl exec postgres-postgresql-0 -n postgres -- \
     pg_dumpall -U postgres > backup.sql
   ```

2. **Пересоздание PVC (только если данные потеряны)**
   ```bash
   # Удалить StatefulSet (⚠️ УДАЛИТ ПОДЫ!)
   helm uninstall postgres -n postgres
   
   # Удалить PVC вручную (⚠️ ПОТЕРЯ ДАННЫХ!)
   kubectl delete pvc data-postgres-postgresql-0 -n postgres
   
   # Переустановить
   helm install postgres ./postgresql -f values-custom.yaml -n postgres
   ```

---

## Полезные команды для диагностики

### Просмотр логов

```bash
# Логи конкретного пода
kubectl logs postgres-postgresql-0 -n postgres -f

# Логи всех подов с лейблом
kubectl logs -l app.kubernetes.io/name=postgresql -n postgres --all-containers=true

# Логи предыдущего контейнера (после краша)
kubectl logs postgres-postgresql-0 -n postgres --previous
```

### Вход в контейнер для диагностики

```bash
# Войти в под PostgreSQL
kubectl exec -it postgres-postgresql-0 -n postgres -- bash

# Выполнить команды PostgreSQL
kubectl exec -it postgres-postgresql-0 -n postgres -- \
  psql -U postgres

# Проверить статус PostgreSQL
kubectl exec postgres-postgresql-0 -n postgres -- \
  pg_isready -U postgres
```

### Проверка ресурсов

```bash
# Использование ресурсов подами
kubectl top pods -n postgres

# Использование ресурсов нодами
kubectl top nodes

# Детальная информация о ресурсах пода
kubectl describe pod postgres-postgresql-0 -n postgres | grep -A 5 "Limits\|Requests"
```

### Проверка конфигурации

```bash
# Проверить текущие values Helm
helm get values postgres -n postgres

# Проверить все конфигурации (включая вычисленные)
helm get all postgres -n postgres

# Вывести манифесты (для отладки)
helm template postgres ./postgresql -f values-custom.yaml -n postgres
```

---

## Восстановление после серьезных сбоев

### Полное пересоздание (⚠️ ПОТЕРЯ ДАННЫХ!)

```bash
# 1. Удалить релиз Helm
helm uninstall postgres -n postgres

# 2. Удалить PVC (если нужна чистая установка)
kubectl delete pvc -l app.kubernetes.io/name=postgresql -n postgres

# 3. Убедиться что все удалено
kubectl get all,pvc -n postgres

# 4. Переустановить
helm install postgres ./postgresql -f values-custom.yaml -n postgres
```

### Мягкое пересоздание (с сохранением данных)

```bash
# 1. Масштабировать до 0
kubectl scale statefulset postgres-postgresql -n postgres --replicas=0

# 2. Подождать завершения
kubectl wait --for=delete pod/postgres-postgresql-0 -n postgres --timeout=60s

# 3. Масштабировать обратно
kubectl scale statefulset postgres-postgresql -n postgres --replicas=2

# Или через Helm
helm upgrade postgres ./postgresql -f values-custom.yaml -n postgres
```

---

## Мониторинг и предупреждения

### Проверка готовности базы данных

```bash
# Скрипт для проверки
kubectl exec postgres-postgresql-0 -n postgres -- \
  pg_isready -U postgres -h localhost
```

### Проверка репликации (если используется)

```bash
kubectl exec postgres-postgresql-0 -n postgres -- \
  psql -U postgres -c "SELECT * FROM pg_stat_replication;"
```

### Проверка размера базы данных

```bash
kubectl exec postgres-postgresql-0 -n postgres -- \
  psql -U postgres -c "SELECT pg_size_pretty(pg_database_size('app_db'));"
```

---

## Экстренные контакты и ссылки

- **Bitnami PostgreSQL Chart Issues**: https://github.com/bitnami/charts/issues
- **Kubernetes Troubleshooting**: https://kubernetes.io/docs/tasks/debug/
- **PostgreSQL Documentation**: https://www.postgresql.org/docs/

## Шпаргалка команд

```bash
# Быстрая проверка статуса
alias pg-status='kubectl get pods,statefulset,svc,pvc -n postgres'

# Быстрый доступ к логам
alias pg-logs='kubectl logs -f postgres-postgresql-0 -n postgres'

# Быстрый доступ к поду
alias pg-exec='kubectl exec -it postgres-postgresql-0 -n postgres -- bash'

# Добавить в ~/.bashrc или ~/.zshrc
```

