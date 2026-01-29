# Руководство по бэкапам и восстановлению PostgreSQL

## Создание бэкапов

### Полный бэкап всех баз данных

Создает бэкап всех баз данных PostgreSQL с автоматической архивацией (gzip):

```bash
make backup
```

Бэкап будет сохранен в `backups/postgres-backup-YYYYMMDD-HHMMSS.sql.gz`

### Бэкап конкретной базы данных

Создает бэкап только указанной базы данных:

```bash
make backup-single DB_NAME=app_db
```

Бэкап будет сохранен в `backups/app_db-backup-YYYYMMDD-HHMMSS.sql.gz`

### Настройка директории для бэкапов

```bash
BACKUP_DIR=/custom/path make backup
```

## Просмотр бэкапов

### Просмотр полного содержимого (с потоковой декомпрессией)

Бэкапы архивируются с помощью gzip для экономии места. При просмотре используется потоковая декомпрессия - файл не распаковывается полностью, что позволяет просматривать даже очень большие бэкапы:

```bash
make view-backup BACKUP_FILE=backups/postgres-backup-20231103-143022.sql.gz
```

Использует `less` для просмотра. Навигация:
- `Space` - следующая страница
- `b` - предыдущая страница
- `/pattern` - поиск
- `q` - выход

### Просмотр начала бэкапа

Показать первые N строк бэкапа (по умолчанию 50):

```bash
make view-backup-head BACKUP_FILE=backups/postgres-backup-20231103-143022.sql.gz
```

С указанием количества строк:

```bash
LINES=100 make view-backup-head BACKUP_FILE=backups/postgres-backup-20231103-143022.sql.gz
```

### Поиск в бэкапе (с потоковой декомпрессией)

Поиск с регулярными выражениями без полной распаковки файла:

```bash
make view-backup-search BACKUP_FILE=backups/postgres-backup-20231103-143022.sql.gz SEARCH='CREATE TABLE'
```

Примеры поиска:
```bash
# Поиск создания таблиц
make view-backup-search BACKUP_FILE=backups/...sql.gz SEARCH='CREATE TABLE'

# Поиск INSERT
make view-backup-search BACKUP_FILE=backups/...sql.gz SEARCH='INSERT INTO'

# Поиск конкретной таблицы
make view-backup-search BACKUP_FILE=backups/...sql.gz SEARCH='users'
```

### Список всех бэкапов

```bash
make list-backups
```

Показывает список всех бэкапов с размерами и датами создания.

## Восстановление

⚠️ **ВНИМАНИЕ**: Восстановление перезапишет существующие данные в базе данных!

### Восстановление всех баз данных

Восстанавливает все базы данных из полного бэкапа (pg_dumpall):

```bash
make restore BACKUP_FILE=backups/postgres-backup-20231103-143022.sql.gz
```

Команда запросит подтверждение перед восстановлением.

### Восстановление конкретной базы данных

Восстанавливает только указанную базу данных:

```bash
make restore-single BACKUP_FILE=backups/app_db-backup-20231103-143022.sql.gz DB_NAME=app_db
```

### Восстановление из неархивированного SQL файла

Если у вас есть обычный SQL файл (не .gz):

```bash
make restore-from-file BACKUP_FILE=backup.sql
```

## Технические детали

### Потоковая архивация и декомпрессия

Все команды просмотра используют потоковую декомпрессию через `gunzip -c`, что означает:

1. **Экономия места на диске** - бэкапы остаются сжатыми
2. **Работа с большими файлами** - не требуется полная распаковка в память
3. **Быстрый доступ** - начало файла доступно сразу
4. **Эффективность** - данные обрабатываются потоково

### Формат бэкапов

- **Полный бэкап**: Использует `pg_dumpall` - содержит все БД, роли, привилегии
- **Бэкап одной БД**: Использует `pg_dump` - содержит только указанную БД
- **Сжатие**: Все бэкапы автоматически сжимаются через `gzip`

### Процесс создания бэкапа

```
pg_dumpall/pg_dump → gzip → файл.sql.gz
```

Процесс восстановления (обратный):

```
файл.sql.gz → gunzip -c → psql
```

## Примеры использования

### Ежедневный бэкап

Создать бэкап и заархивировать:

```bash
make backup
# Результат: backups/postgres-backup-20231103-143022.sql.gz
```

### Проверка содержимого перед восстановлением

```bash
# 1. Посмотреть список бэкапов
make list-backups

# 2. Просмотреть начало бэкапа
make view-backup-head BACKUP_FILE=backups/postgres-backup-20231103-143022.sql.gz

# 3. Поиск нужных объектов
make view-backup-search BACKUP_FILE=backups/postgres-backup-20231103-143022.sql.gz SEARCH='CREATE TABLE my_table'

# 4. Полный просмотр (если нужно)
make view-backup BACKUP_FILE=backups/postgres-backup-20231103-143022.sql.gz
```

### Восстановление после сбоя

```bash
# 1. Убедиться что PostgreSQL работает
make status

# 2. Просмотреть доступные бэкапы
make list-backups

# 3. Восстановить из последнего бэкапа
make restore BACKUP_FILE=backups/postgres-backup-20231103-143022.sql.gz
```

### Бэкап перед обновлением

```bash
# Создать бэкап перед обновлением Helm chart
make backup

# Сохранить имя файла для возможного отката
export BACKUP_FILE=backups/postgres-backup-$(date +%Y%m%d-%H%M%S).sql.gz
make backup

# После обновления, если нужно откатиться
make restore BACKUP_FILE=$BACKUP_FILE
```

## Автоматизация

### Cron job для регулярных бэкапов

Добавьте в crontab для ежедневного бэкапа в 2:00 ночи:

```bash
0 2 * * * cd /home/user/projects/postgres && make backup >> /var/log/postgres-backup.log 2>&1
```

### Скрипт для ротации бэкапов

Создайте скрипт для удаления старых бэкапов (старше 30 дней):

```bash
#!/bin/bash
find backups/ -name "*.sql.gz" -mtime +30 -delete
```

## Безопасность

### Хранение паролей

Пароли для доступа к PostgreSQL автоматически извлекаются из Kubernetes секретов. Бэкапы **не содержат** паролей в открытом виде.

### Рекомендации

1. **Регулярные бэкапы**: Создавайте бэкапы регулярно (ежедневно, еженедельно)
2. **Хранение вне кластера**: Копируйте бэкапы на внешнее хранилище
3. **Тестирование восстановления**: Периодически проверяйте что бэкапы восстанавливаются корректно
4. **Шифрование**: Для чувствительных данных используйте дополнительное шифрование

## Устранение проблем

### Ошибка "Поды PostgreSQL не найдены"

Убедитесь что PostgreSQL развернут:
```bash
kubectl get pods -n postgres
```

### Ошибка "Не удалось получить пароль"

Проверьте секреты:
```bash
kubectl get secret postgres-postgresql -n postgres
```

### Ошибка при восстановлении

1. Проверьте что бэкап не поврежден:
```bash
gunzip -t backups/postgres-backup-20231103-143022.sql.gz
```

2. Проверьте логи PostgreSQL:
```bash
make logs
```

3. Проверьте размер бэкапа и доступное место:
```bash
df -h
ls -lh backups/
```

