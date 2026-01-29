# Быстрая шпаргалка по устранению сбоев

## 🚀 Быстрая диагностика

```bash
# Автоматическая диагностика
make troubleshoot
# или
./scripts/troubleshoot.sh

# Быстрый статус
make status
```

## 🔍 Типичные проблемы

### ❌ Pod в статусе Pending

```bash
# Проверить причину
kubectl describe pod postgres-postgresql-0 -n postgres

# Частые причины:
# 1. Нет ресурсов → kubectl top nodes
# 2. Проблемы с PVC → kubectl get pvc -n postgres
# 3. Taints/NodeSelector → kubectl describe node
```

### ❌ ImagePullBackOff / ErrImagePull

```bash
# Решение: загрузить образы локально
make load-containerd

# Или из файлов
make load-from-files
make load-containerd
```

### ❌ CrashLoopBackOff

```bash
# Просмотр логов
kubectl logs postgres-postgresql-0 -n postgres
kubectl logs postgres-postgresql-0 -n postgres --previous

# Детальная информация
kubectl describe pod postgres-postgresql-0 -n postgres
```

### ❌ Pod не создается / StatefulSet завис

```bash
# Проверить статус StatefulSet
kubectl get statefulset -n postgres
kubectl describe statefulset postgres-postgresql -n postgres

# Удалить проблемный под (StatefulSet пересоздаст)
kubectl delete pod postgres-postgresql-0 -n postgres
```

### ❌ Не могу подключиться к БД

```bash
# Проверить сервисы
kubectl get svc -n postgres
kubectl get endpoints postgres-postgresql -n postgres

# Port-forward для теста
kubectl port-forward svc/postgres-postgresql -n postgres 5432:5432

# Тест подключения из кластера
kubectl run postgres-client --rm -it --restart=Never -n postgres \
  --image=registry-1.docker.io/bitnami/postgresql:latest \
  --env="PGPASSWORD=$(kubectl get secret postgres-postgresql -n postgres -o jsonpath='{.data.password}' | base64 -d)" \
  -- psql --host postgres-postgresql.postgres.svc.cluster.local -U app_user -d app_db
```

## 🔧 Полезные команды

### Логи
```bash
# Текущие логи
make logs
# или
kubectl logs -f postgres-postgresql-0 -n postgres

# Логи предыдущего контейнера
kubectl logs postgres-postgresql-0 -n postgres --previous
```

### События
```bash
# Последние события
make events
# или
kubectl get events -n postgres --sort-by='.lastTimestamp' | tail -20
```

### Вход в контейнер
```bash
kubectl exec -it postgres-postgresql-0 -n postgres -- bash

# Проверка PostgreSQL
kubectl exec postgres-postgresql-0 -n postgres -- pg_isready -U postgres
```

### Ресурсы
```bash
# Использование ресурсов
kubectl top pods -n postgres
kubectl top nodes
```

## 🔄 Восстановление

### Мягкий перезапуск (без потери данных)
```bash
# Масштабировать до 0
kubectl scale statefulset postgres-postgresql -n postgres --replicas=0

# Подождать
sleep 10

# Масштабировать обратно
kubectl scale statefulset postgres-postgresql -n postgres --replicas=2
```

### Полное пересоздание (⚠️ ПОТЕРЯ ДАННЫХ!)
```bash
# 1. Удалить релиз
helm uninstall postgres -n postgres

# 2. Удалить PVC (если нужно)
kubectl delete pvc -l app.kubernetes.io/name=postgresql -n postgres

# 3. Переустановить
helm install postgres ./postgresql -f values-custom.yaml -n postgres
```

## 📋 Чеклист диагностики

- [ ] Проверить статус: `make status`
- [ ] Проверить события: `make events`
- [ ] Проверить логи: `make logs`
- [ ] Проверить описание пода: `make describe`
- [ ] Проверить ресурсы: `kubectl top pods -n postgres`
- [ ] Проверить PVC: `kubectl get pvc -n postgres`
- [ ] Проверить образы: `make list-images`

## 💾 Бэкапы и восстановление

### Создание бэкапа
```bash
# Полный бэкап всех БД
make backup

# Бэкап одной БД
make backup-single DB_NAME=app_db
```

### Просмотр бэкапов (с потоковой декомпрессией)
```bash
# Просмотр полного содержимого
make view-backup BACKUP_FILE=backups/postgres-backup-20231103.sql.gz

# Начало файла
make view-backup-head BACKUP_FILE=backups/postgres-backup-20231103.sql.gz

# Поиск
make view-backup-search BACKUP_FILE=backups/...sql.gz SEARCH='CREATE TABLE'

# Список бэкапов
make list-backups
```

### Восстановление
```bash
# Восстановить все БД
make restore BACKUP_FILE=backups/postgres-backup-20231103.sql.gz

# Восстановить одну БД
make restore-single BACKUP_FILE=backups/app_db-backup-20231103.sql.gz DB_NAME=app_db
```

## 📚 Подробная документация

- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Устранение сбоев
- [BACKUP.md](BACKUP.md) - Бэкапы и восстановление

