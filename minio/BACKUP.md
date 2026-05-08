# Бэкапы и восстановление MinIO

В этой инфраструктуре MinIO бэкапит **только definitions**: IAM users, policies, описания бакетов (versioning, ILM, anonymous policy), tracking secrets `minio-app-<APP>` (содержат `buckets.json` для `app-append`). **Содержимое бакетов (объекты) `make backup-meta` не скачивает** — это отдельная задача.

## Что попадает в meta-бэкап

`make minio-backup-meta ENV=...` (или `make backup-meta` из `minio/`) создаёт **`minio/backups/minio-meta-YYYYMMDD-HHMMSS.tar.gz`** с:

- **`info.json`** — `mc admin info` (версия, режим, сервисы).
- **`users.json`** — `mc admin user list` (только access keys; secret keys не экспортируются).
- **`policies.list`** — список названий policies.
- **`policies/<name>.json`** — содержимое каждой policy (JSON в формате IAM).
- **`buckets.json`** — `mc ls --json` (имена bucket'ов и метаданные).
- **`buckets/<bucket>-versioning.json`** — `mc version info` (Enabled / Suspended / Disabled).
- **`buckets/<bucket>-ilm.json`** — `mc ilm rule export` (lifecycle policies).
- **`buckets/<bucket>-anonymous.json`** — `mc anonymous get-json` (public read/list/write если включено).
- **`tracking-secrets/<minio-app-APP>.yaml`** — Secret из namespace `minio` с `buckets.json` (используется для `app-append`).

Все файлы — текст / JSON, удобно diffить между бэкапами.

## Что **не** попадает в meta-бэкап

- **Объекты в бакетах** — для них используется `mc mirror` или backup на уровне PV (см. ниже).
- **Secret keys IAM-пользователей** — `mc admin user list` возвращает их **редактированными** (`mc admin user info` тоже не отдаёт plaintext). Plaintext-ключи живут только в Secret `<APP>-minio` в namespace приложения и в `apps/conf/<APP>/secrets.yaml`. Восстановление — через `apps-apply`.
- **Сертификаты MinIO** — chart их не использует (TLS терминируется на ingress).

## Создание бэкапа

```bash
# Из корня репозитория
make minio-backup-meta ENV=local

# Или из minio/
make backup-meta ENV=local
```

Список существующих:
```bash
make list-backups        # из minio/
```

## Восстановление policies + tracking secrets

`make restore-meta`:
1. Запускает helper-pod с `mc` и применяет каждый `policies/<name>.json` через `mc admin policy create` (системные `consoleAdmin/readonly/readwrite/writeonly/diagnostics` пропускаются).
2. На хосте применяет `kubectl apply -f tracking-secrets/<NAME>.yaml` для каждого `minio-app-<APP>`.

```bash
make minio-restore-meta BACKUP_FILE=minio/backups/minio-meta-20260508-143022.tar.gz ENV=local

# Без интерактивного подтверждения
make minio-restore-meta BACKUP_FILE=... SKIP_CONFIRM=1 ENV=local
```

## Восстановление IAM-пользователей и доступа приложений

⚠️ **Не из бэкапа.** IAM users пересоздаются через **`make apps-apply ENV=... ENABLED_SERVICES=minio`** — для каждого `enabled: true` приложения в `apps/registry.yaml` создаётся IAM user с access/secret keys из `apps/conf/<APP>/secrets.yaml` и привязывается к policy `app-<APP>` (которую уже восстановил `restore-meta`).

```bash
make apps-apply ENV=local ENABLED_SERVICES=minio
```

После этого Secret `<APP>-minio` в namespace приложения содержит работающие S3-кеды.

## Восстановление содержимого бакетов

⚠️ Это отдельная процедура от meta-бэкапа. Объекты могут быть очень большими (сотни ГБ) и бэкапиться по своему графику.

### Вариант A: `mc mirror` на внешнее хранилище

Регулярно реплицировать с MinIO на S3-совместимое хранилище:

```bash
# Через временный pod minio-client
kubectl run -it --rm minio-mirror --image=$(grep MINIO_CLIENT_IMAGE_LOCAL minio/Makefile | head -1) --restart=Never --namespace=minio \
  --command -- sh -c '
    mc alias set src http://minio.minio.svc.cluster.local:9000 ROOT_USER ROOT_PASSWORD
    mc alias set dst https://s3.example.com EXTERNAL_KEY EXTERNAL_SECRET
    mc mirror --overwrite src/<bucket> dst/<bucket-backup>
  '
```

При disaster recovery: обратный `mc mirror dst/<bucket-backup> src/<bucket>` после `make apps-apply`.

### Вариант B: snapshot PV

В microk8s со `storage` addon (hostpath-provisioner) можно сделать `tar` каталога PV напрямую с ноды:

```bash
ssh <node> 'sudo tar -czf /tmp/minio-pvc.tar.gz -C /var/snap/microk8s/common/default-storage <minio-pvc-dir>'
```

Это даёт полный консистентный бэкап (объекты + IAM internal state). Восстановление: scale down MinIO, заменить директорию, scale up. **Внимание:** бэкап получится несогласованным, если идут активные записи; для важных данных используйте `mc mb --with-lock` + `mc admin service restart` перед snapshot (или `mc admin trace` для понимания нагрузки).

### Вариант C: `mc cp --recursive` локально

Для небольших бакетов:

```bash
mc cp --recursive minio/<bucket> /var/backups/minio/<bucket>/
```

## Disaster recovery (новый сервер с нуля)

1. Восстановить Secret `minio/minio` (root creds) из `make env-backup` **до** `make up`. Без этого первый `make up` создаст **новый** Secret и потеряет связь с восстановленными IAM-internal данными (если используете snapshot PV).
2. `make up ENV=<env>` — поднимает MinIO с восстановленным root.
3. `make minio-restore-meta BACKUP_FILE=...` — восстановить policies + tracking secrets.
4. `make apps-apply ENV=<env> ENABLED_SERVICES=minio` — пересоздать IAM-users + Secret приложений.
5. (Опционально) Восстановить содержимое бакетов через `mc mirror` или snapshot PV.

## Автоматизация (cron)

```cron
# /etc/cron.d/minio-backup-meta — ежедневно в 03:40
40 3 * * * ubuntu cd /opt/infra && /usr/bin/make minio-backup-meta ENV=prod >> /var/log/minio-backup-meta.log 2>&1
```

Ротация:
```bash
find minio/backups -name 'minio-meta-*.tar.gz' -mtime +14 -delete
```

## Известные ограничения

- **Public read/list policies** не всегда полностью восстанавливаются через `mc anonymous set-json` обратным образом — формат ответа `get-json` не идентичен `set-json`. После restore сверяйтесь с фактическим состоянием бакета.
- **ILM rules** с `Filter` или `Transition` могут потребовать ручной правки.
- **Bucket configurations с object-lock** — `--with-lock` устанавливается **только при создании bucket**; на существующий применить нельзя. Если бэкап содержал object-locked бакет — пересоздавайте с нуля или используйте snapshot PV.
