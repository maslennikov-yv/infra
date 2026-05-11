# Шифрование бэкапов через age

## TL;DR

Бэкапы инфра-сервисов и `env-backup` могут опционально шифроваться через
[age](https://age-encryption.org/). По умолчанию шифрование **выключено** —
бэкапы создаются как обычно (`*.sql.gz`, `*.tar.gz`, etc.). Чтобы
включить — задайте `BACKUP_AGE_RECIPIENT` (public key); после этого все
backup-цели автоматически шифруют свежий файл (`*.age` суффикс),
restore-цели автоматически расшифровывают перед применением.

Согласован по инструменту с уже существующим sops+age workflow для
`apps/conf/<APP>/secrets.enc.yaml` (см.
`docs/runbooks/secrets-management.md`).

## Зачем

`umask 077` уже даёт правам 600 на бэкап-файлы локально. Но:

- При **переносе на off-cluster хранилище** (S3, scp на другой сервер)
  права теряются.
- **Бэкап-сервер** может быть скомпрометирован — без шифрования его
  диск раскрывает все секреты кластера (Kubernetes secrets, SCRAM-
  пароли, MinIO root-credentials).
- **`environments/backups/<env>-*.tar.gz`** содержит **все Secret из
  всех namespaces** — самый чувствительный артефакт в репо.

age решает это «дёшево и сердито» — один публичный ключ для шифрования,
один приватный для расшифровки, без keyring и иерархии.

## Что покрывается

| Цель | Бэкап-каталог | Шифруется | Расшифровывается |
|------|---------------|-----------|-------------------|
| `make postgres-backup` / `postgres-restore` | `postgres/backups/` | ✓ | ✓ |
| `make redis-backup` / `redis-restore-acl` | `redis/backups/` | ✓ | ✓ |
| `make kafka-backup-meta` / `kafka-restore-meta-topics` | `kafka/backups/` | ✓ | ✓ |
| `make minio-backup-meta` / `minio-restore-meta` | `minio/backups/` | ✓ | ✓ |
| `make clickhouse-backup` / `clickhouse-restore` | `clickhouse/backups/` | ✓ | ✓ |
| `make rabbitmq-backup-defs` / `rabbitmq-restore-defs` | `rabbitmq/backups/` | ✓ | ✓ |
| `make backup-all` | каждый из выше | ✓ | — |
| `make env-backup` / `env-restore` | `environments/backups/` | ✓ | ✓ |

## Включение

### Шаг 1. Установить age

```bash
sudo apt install age            # Ubuntu 22.04+
brew install age                # macOS
```

Проверка: `make tools-check` должен показать age как `OK` (опциональный).

### Шаг 2. Сгенерировать keypair

```bash
mkdir -p ~/.config/age
age-keygen -o ~/.config/age/backups.txt
chmod 600 ~/.config/age/backups.txt
```

В `~/.config/age/backups.txt` после генерации:

```
# created: 2026-01-15T...
# public key: age1xyz...   ← это recipient
AGE-SECRET-KEY-...
```

`age1xyz...` — публичный ключ (recipient), используется для шифрования.
`AGE-SECRET-KEY-...` — приватный, используется для расшифровки.

**ВАЖНО**: приватный ключ — резервируйте off-cluster (LastPass, KeePass,
другая нода). При его потере зашифрованные бэкапы становятся **навсегда
недоступны** — это и есть цель шифрования, защита от утечки, но это
двусторонне: вы тоже можете потерять доступ.

### Шаг 3. Задать `BACKUP_AGE_RECIPIENT`

В `environments/<env>.mk` (gitignored):

```makefile
# Опциональное шифрование бэкапов через age. Снять/закомментить чтобы
# отключить. Public key получите из ~/.config/age/backups.txt после
# age-keygen.
BACKUP_AGE_RECIPIENT := age1xyz0123456789...
```

Альтернатива: передавать на CLI:

```bash
make backup-all ENV=prod BACKUP_AGE_RECIPIENT=age1xyz...
```

`BACKUP_AGE_KEY_FILE` для restore по умолчанию `~/.config/age/backups.txt`.
Переопределить, если ключ лежит в другом месте:

```bash
make postgres-restore BACKUP_FILE=backups/prod/postgres-backup-…sql.gz.age \
    BACKUP_AGE_KEY_FILE=/secure/keys/backups.txt ENV=prod
```

## Backup flow

```bash
make postgres-backup ENV=prod
# ...
# ✓ Бэкап создан: backups/prod/postgres-backup-20260115-120000.sql.gz (15M)
# 🔒 backup-encrypt: postgres-backup-20260115-120000.sql.gz.age (age, recipient=age1xyz0123456789…)
```

Скрипт `scripts/backup-encrypt.sh`:

1. Если `BACKUP_AGE_RECIPIENT` пуст → no-op (exit 0), файл остаётся
   plain. Это default — без явной настройки ничего не шифруется.
2. Если задан → ищет свежий файл по паттерну в каталоге, шифрует,
   удаляет оригинал.
3. При ошибке (age не установлен, неверный recipient) — exit 1, оригинал
   остаётся; следующая попытка backup увидит уже его и попробует
   зашифровать заново.

## Restore flow

```bash
# С зашифрованным файлом — auto-decrypt
make postgres-restore BACKUP_FILE=backups/prod/postgres-backup-20260115.sql.gz.age ENV=prod

# С plain (старые бэкапы) — passthrough, всё работает как раньше
make postgres-restore BACKUP_FILE=backups/prod/postgres-backup-20260115.sql.gz ENV=prod
```

`scripts/backup-decrypt.sh`:

1. Если файл не оканчивается на `.age` → passthrough (stdout = path).
2. Если `.age` → расшифровывает в `<file>.decrypted` (рядом с
   оригиналом), stdout = `<file>.decrypted`.
3. Caller (Makefile) использует stdout как `BACKUP_FILE` для per-service
   restore-цели, после restore удаляет `.decrypted`.

Если ключа нет в `~/.config/age/backups.txt` или `BACKUP_AGE_KEY_FILE` —
ошибка с понятным сообщением, restore прерывается до изменения данных.

## Ротация ключей

```bash
# 1. Сгенерировать новый keypair
age-keygen -o ~/.config/age/backups-new.txt

# 2. Расшифровать старые бэкапы и зашифровать новым ключом
for f in postgres/backups/*/*.age; do
    age -d -i ~/.config/age/backups.txt "$f" \
        | age -r "$(grep 'public key' ~/.config/age/backups-new.txt | awk '{print $4}')" \
              -o "${f%.age}.new.age"
    mv "${f%.age}.new.age" "$f"
done
# (повторить для redis/, kafka/, minio/, clickhouse/, rabbitmq/, environments/)

# 3. Заменить активный ключ
mv ~/.config/age/backups-new.txt ~/.config/age/backups.txt

# 4. Обновить BACKUP_AGE_RECIPIENT в environments/<env>.mk
```

Альтернатива: указать в age-encrypt **несколько** recipients (старый +
новый), переходить плавно. Bitnami chart этого не делает напрямую, но
скрипт можно расширить через `age -r r1 -r r2`.

## Smoke-тест включения

```bash
# Без recipient — обычный flow
make redis-backup ENV=prod
ls redis/backups/prod/   # должен быть .tar.gz, без .age

# С recipient
export BACKUP_AGE_RECIPIENT=$(grep 'public key' ~/.config/age/backups.txt | awk '{print $4}')
make redis-backup ENV=prod
ls redis/backups/prod/   # должен быть .tar.gz.age

# Restore с auto-decrypt
LATEST=$(ls -t redis/backups/prod/redis-backup-*.tar.gz.age | head -1)
make redis-restore-acl BACKUP_FILE="${LATEST#redis/}" ENV=prod
# Должно: backup-decrypt создаёт .decrypted, restore применяет, .decrypted удаляется
```

## Откат

Шифрование — опциональная фича, отключается убиранием
`BACKUP_AGE_RECIPIENT` (закомментить в `<env>.mk`). Старые `.age` бэкапы
остаются доступны через `backup-decrypt.sh`, новые будут plain.

Если `age` сломан или ключ потерян:

```bash
# Расшифровать вручную (с любого хоста, где есть age + ключ):
age -d -i ~/.config/age/backups.txt -o postgres/backups/prod/foo.sql.gz \
    postgres/backups/prod/foo.sql.gz.age
# Дальше — обычный restore с plain-файлом.
```

## Что не покрывается

- **Шифрование данных «в живом» PVC** (encryption at rest на уровне
  диска) — это про SC и StorageClass, не про бэкапы. Для prod
  рекомендуется LUKS на хост-диске или CSI с встроенным шифрованием.
- **Подпись (signing)** бэкапов — age шифрует, но не аутентифицирует
  «кто записал». Если важно — используйте `gpg --sign` поверх или
  переходите на minisign.
- **Длительный срок хранения**: age сейчас стабилен, но протокол молодой
  (~2020). Для архивов на 5+ лет рассмотрите GPG (более устоявшийся).

## Альтернативы

- **GPG** — стандарт, многоключевая иерархия, тяжелее для простого
  use-case.
- **OpenSSL CMS** — встроен в openssl, но клавдогрямный синтаксис.
- **Бэкапы внутри Vault / KMS** — overkill для single-node репозитория.

age был выбран за совпадение с уже используемым sops+age — единая
утилита, единый ключ-стандарт, минимум новой механики в репо.
