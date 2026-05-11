# Backup verification: восстановление бэкапа в другой среде

Регулярная проверка, что бэкапы из `SRC_ENV` (обычно `prod`) реально восстановимы и приводят к рабочему приложению. Без такой проверки бэкапы — мёртвый артефакт: они существуют, занимают место, но никто не знает, рабочие они или нет.

Связанные документы:
- [`disaster-recovery.md`](disaster-recovery.md) — полное восстановление окружения с нуля (используется руками после реального инцидента).
- [`backups-encryption.md`](backups-encryption.md) — опциональное age-шифрование бэкапов и фингерпринтов.
- [`secrets-management.md`](secrets-management.md) — sops+age для `apps/conf/<APP>/<ENV>/secrets.enc.yaml`.
- Per-service: [`postgres/BACKUP.md`](../../postgres/BACKUP.md), [`redis/BACKUP.md`](../../redis/BACKUP.md), [`kafka/BACKUP.md`](../../kafka/BACKUP.md), [`minio/BACKUP.md`](../../minio/BACKUP.md), [`clickhouse/BACKUP.md`](../../clickhouse/BACKUP.md), [`rabbitmq/BACKUP.md`](../../rabbitmq/BACKUP.md).

---

## Что покрывает — и чего НЕ покрывает

### Покрывает (verdict PASS/FAIL влияет на это)

- **Целостность файлов бэкапа**: `tar -tzf`, `gunzip -t`, `age --decrypt --dry-run`.
- **Восстановимость**: `env-restore` + `make up` + per-service `*-restore` отрабатывают без ошибок на чистом DST_ENV.
- **Структурное соответствие источнику** (single APP) под admin-кредами:
  - Postgres: список таблиц + `pg_dump --schema-only` sha256 (без version-комментариев).
  - Redis: ACL пользователя `app_<APP>` (commands/keys/channels).
  - Kafka: список топиков с префиксом `<APP>.` + describe + ACL списка для `User:app_<APP>`.
  - MinIO: user info + policy + bucket existence + versioning/quota/anonymous.
  - ClickHouse: список таблиц БД `<APP>` + `SHOW CREATE TABLE` sha256 + GRANT'ы.
  - RabbitMQ: vhost/users/queues/exchanges/bindings/policies из `export_definitions`, filtered по vhost.
- **Smoke под APP-кредами**: `make doctor` + `*-app-verify` (подключение, минимальный запрос).

### НЕ покрывает (выводится как `informational`, не блокирует verdict)

- **Объёмные данные** для 5 из 6 сервисов: `*-backup-meta` бэкапит **definitions**, не данные. После restore:
  - Redis: RDB не восстановлен (`redis-restore-acl` восстанавливает только ACL — см. [`redis/BACKUP.md`](../../redis/BACKUP.md) раздел «Восстановление данных RDB»).
  - Kafka: топики пустые, offsets = 0 (`kafka-backup-meta` не содержит сообщений).
  - MinIO: бакеты пустые (объекты не бэкапятся).
  - ClickHouse: таблицы пустые (только schemas+grants в бэкапе).
  - RabbitMQ: очереди пустые (сообщения не дампятся).
- **Только PostgreSQL** имеет full data backup через `pg_dumpall` — для него `row_counts` сравниваются строго.

Для пяти «meta-only» сервисов diff покажет «data-divergence» — это **ожидаемо** и НЕ означает поломку бэкапа.

Если нужна **верификация данных** для всех сервисов — это отдельная задача (data-mirror: `mc mirror`, MirrorMaker2, scripted Redis SC0+cp+SC1, `clickhouse-backup` tool). Вне scope текущего runbook'а.

---

## Архитектура

```
admin-machine                                   SRC_ENV (prod node)
─────────────                                   ────────────────────
                       1. preflight
make backup-verify ───→ ssh scp ←─────────────  *-backup-* files
SRC_ENV=prod                                    environments/backups/<src>/*.tar.gz
DST_ENV=local                                   verify-reports/.../fingerprint-source-*.json
APP=myapp                ↓
                       2. fetch → verify-reports/<TS>-<APP>/incoming/

                       3. workspace-swap apps/conf → apps/conf.bak-verify-<TS>

                       4. (CLEAN=1) wipe DST: helm down + delete PVCs + wait

                       DST_ENV (local microk8s)
                       ────────────────────────
                       5. env-restore (Secrets + apps/conf) → kubectl apply
                       6. localize MINIO_PUBLIC_ENDPOINT → in-cluster URL DST
                       7. make up SKIP_APPS_APPLY=1     → helmfile apply
                       8. per-service *-restore         → pg_dumpall|psql, redis-cli, kafka-topics.sh, mc, clickhouse-client, rabbitmqctl
                       9. make apps-apply               → SCRAM/ACL/IAM creds из apps/conf
                       10. make doctor                  → rollout-status + per-app *-app-verify
                       11. fingerprint-dst              → structural snapshot
                       12. diff src ↔ dst               → strict structural + soft informational
                       13. summary.md + summary.json    → итоговый PASS/FAIL
```

---

## Prerequisites

### Источник (SRC_ENV)

На SRC_ENV должны регулярно выполняться:

```bash
# 1. Бэкапы всех сервисов + env-backup.
make backup-all   ENV=$SRC_ENV
make env-backup   ENV=$SRC_ENV CONFIRM=1

# 2. Сразу после — снять source fingerprint (по каждому APP, который верифицируем).
make backup-fingerprint APP=<app> ENV=$SRC_ENV ROLE=source
```

После двух шагов в `<svc>/backups/<SRC_ENV>/`, `environments/backups/<SRC_ENV>/` и `verify-reports/<TS>-<app>/` лежат свежие файлы.

> **Time-skew**: `backup-fingerprint ROLE=source` снимает snapshot ПОСЛЕ `backup-all`, чтобы фингерпринт отражал состояние, которое **должно** воспроизвестись. Если ваш APP активно пишет, разрыв между bкапом и фингерпринтом может приводить к ложным diff'ам для `informational` (data-metrics). Для `structural` это не критично — schema, ACL, topics стабильны.

### Admin-машина

```bash
# Тулинг (см. scripts/check-tools.sh; verify дополнительно требует:):
mc / minio-mc           # для fingerprint MinIO через kubectl run
psql                    # client, не Bitnami pod; для подключения через kubectl exec он не нужен
redis-cli               # для fingerprint Redis (опционально, можно через kubectl exec)
clickhouse-client       # для fingerprint ClickHouse
rabbitmqadmin           # для fingerprint RabbitMQ
age                     # только если бэкапы зашифрованы

# Доступ:
- kubeconfig к DST_ENV в k8s/config/<DST_ENV>
- environments/<SRC_ENV>.mk заполнен (SSH_HOST, SSH_USER, SSH_KEY, SSH_PORT)
- BACKUP_AGE_KEY_FILE доступен, если бэкапы шифрованы (см. backups-encryption.md)

# Apps/conf:
- apps/conf должен быть пуст ИЛИ передаётся FORCE=1 / явный workspace swap
- apps/registry.yaml содержит APP с enabled: true
```

### DST_ENV (целевой кластер)

```bash
# Достаточно одного из:
- местный microk8s (для DST_ENV=local) — make kubeconfig-microk8s-local ENV=local
- удалённый verify-кластер — make kubeconfig-fetch ENV=verify
- эфемерные namespace в local — отдельная схема (см. ниже)

# Образы в localhost:32000 registry DST_ENV должны быть запушены (make images-push ENV=$DST_ENV).
# helm releases в DST_ENV либо отсутствуют, либо все имеют label infra-env=$DST_ENV.
```

---

## Quick start: один прогон

```bash
# 1. На SRC_ENV (или через SSH):
make backup-all  ENV=prod
make env-backup  ENV=prod CONFIRM=1
make backup-fingerprint APP=myapp ENV=prod ROLE=source

# 2. На admin-машине:
make env-label-backfill ENV=local      # проставить infra-env=local на ns local-кластера (один раз)

make backup-verify \
    SRC_ENV=prod \
    DST_ENV=local \
    APP=myapp \
    CLEAN=1 \
    BACKUP_AGE_KEY_FILE=~/.config/sops/age/keys.txt  # если бэкапы шифрованы

# 3. Прочитать отчёт:
cat verify-reports/<TS>-myapp/summary.md
jq . verify-reports/<TS>-myapp/summary.json
```

Verdict `PASS` означает: бэкапы **целы**, **структура** (схема/ACL/topics/bucket-config/vhost) воспроизвелась, APP **подключается** к DST под restored creds. Verdict `FAIL` — смотрите `logs/<step>.log` и `diff.md`.

> **PASS ≠ «данные восстановлены».** Объёмные данные для Redis/Kafka/MinIO/ClickHouse/RabbitMQ **не** входят в `*-backup-meta` и не верифицируются — `informational` блок diff'а покажет расхождение, и это ожидаемо. См. полный disclaimer в разделе [«Что покрывает — и чего НЕ покрывает»](#что-покрывает--и-чего-не-покрывает). PostgreSQL — единственный сервис с full data-backup через `pg_dumpall`.

> **При FAIL — для повторного запуска всегда передавайте `CLEAN=1`.** `postgres-restore` с `PG_ON_ERROR_STOP=1` (strict mode оркестратора) падает на повторе с «role already exists» из `pg_dumpall`. Без `CLEAN=1` повтор не идёт.

---

## Подробно: каждый шаг

### 1. preflight (13 hard-checks)

Останавливает пайплайн до любого destructive шага.

```
DST_ENV not in prod blocklist           — DST_ENV ∉ {prod, production}
SRC_ENV != DST_ENV (text)               — нельзя верифицировать env сам в себя
cluster URL src != dst                  — сравнение server URL из k8s/config/$SRC_ENV ↔ $KUBECONFIG
tooling check                           — kubectl, helm, yq, jq, openssl, tar, gzip + опц. mc/psql/redis-cli/ch-client/rabbitmqadmin/age
namespace infra-env label               — ns DST с label infra-env=$DST_ENV (защита от чужого кластера)
PG major version src==dst               — pg_dumpall между мажорными PG ненадёжен
disk free admin                         — ≥ max(MIN_DISK_FREE_MB, sum(BACKUP_FILES)*3)
backup files integrity                  — tar -tzf / gunzip -t / age dry-run каждого файла
backup timestamp drift                  — разрыв между файлами BACKUP_FILES < TIMESTAMP_DRIFT_HOURS
apps/conf swap status                   — apps/conf пуст или будет swapped/FORCE=1
age key file                            — BACKUP_AGE_KEY_FILE существует и readable (если есть .age)
DST helm releases clean                 — все releases в ns с infra-env=$DST_ENV
APP in registry                         — APP найден в apps/registry.yaml и enabled: true
```

FAIL ⇒ exit 1. WARN ⇒ информационно, не блокирует (если не задан `FORCE=1`).

Запустить отдельно:
```bash
make backup-verify-preflight SRC_ENV=prod DST_ENV=local APP=myapp \
    BACKUP_FILES="path/to/file1 path/to/file2 ..."
```

### 2. fetch

```bash
make backup-verify-fetch SRC_ENV=prod APP=myapp
```

scp по SSH из `environments/<SRC>.mk` (или local-cp если SSH_HOST пуст) свежих файлов:
- `environments/backups/<SRC>/*.tar.gz[.age]`
- `<svc>/backups/<SRC>/<svc>-{backup,meta,defs}-*.{tar.gz,sql.gz,json.gz}[.age]`
- `verify-reports/.../fingerprint-source-<SRC>-*.json[.age]` (если `INCLUDE_FINGERPRINT=1`, default)

Кладёт в `verify-reports/<TS>-<APP>/incoming/`. Сразу после scp — integrity check каждого. Печатает `BACKUP_FILES=...` для downstream.

### 3. workspace-swap apps/conf

Если на admin-машине `apps/conf/` содержит non-`_example` каталоги — перемещаем в `apps/conf.bak-verify-<TS>/` и создаём пустой `apps/conf/` + копия `_example`. На `trap EXIT/INT/TERM` swap восстанавливается (даже если verify упал/Ctrl-C).

Зачем: env-restore из prod-снимка попытается записать `apps/conf/<APP>/<ENV>/secrets.yaml` с **prod creds**, что перетрёт ваши локальные creds. Swap делает откат тривиальным.

### 4. clean (только если `CLEAN=1`)

```bash
make down ENV=$DST_ENV
kubectl delete pvc -n <ns> -l app.kubernetes.io/managed-by=Helm  # для всех 7 platform-ns
# poll до удаления (TIMEOUT_PVC_DELETE, default 180s)
```

**Когда нужен `CLEAN=1`**: если DST_ENV не пустой и вы хотите чистый старт. Без CLEAN restore поверх существующего состояния может дать неоднозначные результаты (особенно Kafka KRaft cluster-id).

**Когда НЕ нужен `CLEAN=1`**: первый прогон на полностью пустом DST_ENV.

### 5. env-restore

```bash
make env-restore \
    BACKUP_FILE=verify-reports/<TS>-<APP>/incoming/<SRC>-*.tar.gz[.age] \
    ENV=$DST_ENV CONFIRM=1 \
    OVERWRITE_APPS_CONF=1 \
    BACKUP_AGE_KEY_FILE=...
```

Особенности (см. PR1.2 фичи в [scripts/env-restore.sh](../../scripts/env-restore.sh)):
- **Sanity-check**: server URL из `k8s/config/$SRC_ENV` ≠ server URL DST. Защита от выстрела в свой же кластер. Отключается `ALLOW_SRC_EQUALS_DST=1` (используется для DR того же env).
- **`OVERWRITE_APPS_CONF=1`**: перетирает существующие `apps/conf/<APP>/<ENV>/` (backup-verify нуждается в prod-creds для запуска под ними). Без флага — пропускает существующие.
- Restored Secrets уже содержат prod-пароли → следующий `make up` НЕ генерирует новые пароли, использует существующие.

### 6. localize

```bash
make backup-verify-localize DST_ENV=$DST_ENV APP=$APP
```

Подменяет в restored Secret `<APP>-minio` и `apps/conf/<APP>/<ENV>/secrets.yaml`:
- `MINIO_PUBLIC_ENDPOINT` → `http://minio.minio.svc.cluster.local:9000`
- `minio.public_endpoint` (в apps/conf) → то же

**Безопасность**: hardcoded guard `DST_ENV ∉ {prod, production}`. Без localize: local backend сгенерирует presigned URL на prod-домен → клиент уйдёт писать в prod-MinIO. Это запись в prod через verify — **критичная утечка**.

`LOCALIZE_DRY_RUN=1` — план без записи.

### 7. up

```bash
make up ENV=$DST_ENV SKIP_APPS_APPLY=1
```

`helmfile apply` поверх восстановленных Secret'ов. `SKIP_APPS_APPLY=1` потому что:
- `apps-apply` будет вызван явно на шаге 9 (после `*-restore`),
- Иначе `apps-apply` может пересоздать SCRAM/ACL/IAM creds **до** того как pg_dumpall успеет восстановить роли с теми же именами → расхождение пароля в кластере и в Secret приложения.

### 8. data-restore (per-service)

Последовательность:
1. `postgres-restore PG_ON_ERROR_STOP=1 SKIP_CONFIRM=1` ← новый strict-режим (PR1.1)
2. `redis-restore-acl` ← ACL only (RDB не восстанавливается, см. disclaimer выше)
3. `kafka-restore-meta-topics SKIP_CONFIRM=1` ← topics с `--if-not-exists`; ACL и SCRAM создаст apps-apply
4. `minio-restore-meta SKIP_CONFIRM=1` ← policies + tracking secrets minio-app-*
5. `clickhouse-restore SKIP_CONFIRM=1` ← schemas + users + grants (DROP USER IF EXISTS + CREATE)
6. `rabbitmq-restore-defs SKIP_CONFIRM=1` ← `import_definitions` (idempotent merge)

Каждый шаг логируется в `verify-reports/<TS>-<APP>/logs/data-restore.log`. Если файл бэкапа отсутствует — sub-step пропускается с пометкой `absent` (не fail).

### 9. apps-apply

```bash
make apps-apply ENV=$DST_ENV
```

Приводит SCRAM/ACL/IAM creds к состоянию, заявленному в `apps/conf/<APP>/<ENV>/secrets.yaml` (восстановленному из prod env-backup). Это важно потому что:
- Restored Secret `<APP>-postgres` содержит prod-пароль, который был на момент env-backup. Если на источнике после env-backup пароль менялся через apps-apply — restored Secret устарел.
- На стороне БД роль `app_<APP>` была создана с тем же паролем, что в restored Secret. apps-apply делает `ALTER ROLE ... PASSWORD` чтобы синхронизировать с `apps/conf`.

### 10. doctor

```bash
make doctor ENV=$DST_ENV
```

5 шагов: tools / cluster / helm releases / rollout-статусы / per-app `*-app-verify` smoke.

Логи каждого `*-app-verify` per-run — в `/tmp/doctor-<TS>-<PID>/<app>-<svc>.log` (PR1.5). При FAIL doctor печатает путь к логу.

### 11. fingerprint-dst

```bash
make backup-fingerprint APP=$APP ENV=$DST_ENV ROLE=dst
```

Снимает structural snapshot на DST (см. начало runbook'а). Файл `fingerprint-dst-<DST>-<TS>.json` в `verify-reports/<TS>-<APP>/`.

### 12. diff

```bash
make backup-fingerprint-diff \
    SRC_FINGERPRINT=verify-reports/<TS>-<APP>/incoming/fingerprint-source-<SRC>-*.json \
    DST_FINGERPRINT=verify-reports/<TS>-<APP>/fingerprint-dst-<DST>-<TS>.json
```

Per-service verdict:
- `PASS` — structural идентичны.
- `WARN` — structural идентичны, informational расходится. **Это нормально** для не-Postgres сервисов (data-metrics ожидаемо расходятся).
- `FAIL` — structural отличаются. Restore воспроизвёл не то — расследуйте.
- `SKIP` — APP не использует этот сервис.

Output: `diff.md` (markdown с per-service таблицей + JSON-блоки расхождений), `diff.json` (machine-readable).

### 13. summary

Сводный отчёт: `summary.md` (markdown) + `summary.json` (machine). Финальный verdict = AND(critical-steps PASS, fingerprint-diff PASS).

При `BACKUP_AGE_RECIPIENT` задан — отчёты шифруются age (структурный snapshot prod может быть чувствительным).

---

## Чек-лист первого запуска

Перед первым `make backup-verify` в новом окружении:

- [ ] `make env-label-backfill ENV=$DST_ENV` — однократно проставить `infra-env=$DST_ENV` на существующие ns (новые ns получают label автоматически в PR1.3).
- [ ] `environments/$SRC_ENV.mk` — SSH_HOST, SSH_USER, SSH_KEY, SSH_PORT заполнены.
- [ ] На SRC_ENV есть свежие бэкапы: `ssh $SRC ls -lh /opt/infra/postgres/backups/$SRC_ENV/ /opt/infra/environments/backups/$SRC_ENV/ ...`.
- [ ] На SRC_ENV снят source-fingerprint после backup-all: `ssh $SRC ls -lh /opt/infra/verify-reports/*/fingerprint-source-*`.
- [ ] `apps/conf/` либо пуст, либо вы готовы к workspace swap.
- [ ] `apps/registry.yaml` имеет `<APP>` с `enabled: true` (на admin-машине).
- [ ] `kubectl --kubeconfig k8s/config/$DST_ENV get nodes` работает.
- [ ] `helm --kubeconfig k8s/config/$DST_ENV list -A` либо пуст, либо все releases в ns с label `infra-env=$DST_ENV`.
- [ ] (Опционально) `BACKUP_AGE_KEY_FILE` если бэкапы шифрованы.
- [ ] Свободное место на admin ≥ `sum(BACKUP_FILES) * 3`.

После первого успешного `verdict: PASS` — фиксируйте конфигурацию (env-vars, версии, kubeconfig) и переходите к регулярному запуску.

---

## Регулярный запуск

В рамках текущего scope — внешний cron / systemd timer на admin-машине:

```bash
# /etc/systemd/system/backup-verify-myapp.service
[Service]
Type=oneshot
ExecStart=/usr/bin/make -C /opt/infra-admin backup-verify \
    SRC_ENV=prod \
    DST_ENV=local \
    APP=myapp \
    CLEAN=1 CLEAN_AFTER=1 \
    BACKUP_AGE_KEY_FILE=/etc/age/admin.key
User=infra-admin
WorkingDirectory=/opt/infra-admin

# /etc/systemd/system/backup-verify-myapp.timer
[Timer]
OnCalendar=Mon 04:00     # после ночного backup-all в 02:00 SRC_ENV
Persistent=true

[Install]
WantedBy=timers.target
```

Алёртинг: post-step shell-hook в `summary.json` → отправка Slack / email при `verdict=FAIL`.

> **Не входит в текущий scope (отдельный PR)**: автоматический запуск через `make backup-verify-loop`, integration с `/schedule`, Slack-нотификации, multi-app параллельный verify.

---

## Troubleshooting

### preflight: `DST helm releases clean` FAIL

```
✗  DST helm releases clean   releases в ns без infra-env=local: postgres/postgres(=<no-label>) ...
```

Причина: на DST уже работают helm releases в ns, у которых нет label `infra-env=$DST_ENV`. Это или чужой стек, или существующее окружение, на которое PR1.3 ещё не применён.

Решение:
```bash
make env-label-backfill ENV=$DST_ENV
make backup-verify-preflight ...   # повторно
```

Если releases действительно чужие — verify на этом кластере небезопасен. Используйте `DST_ENV=verify` (отдельный кластер) или эфемерные namespace.

### preflight: `apps/conf swap status` FAIL

```
✗  apps/conf swap status     apps/conf содержит N app(s). Сохраните в apps/conf.bak-verify-TS/ или передайте FORCE=1
```

Решение 1 — позволить orchestrator'у сделать swap автоматически (он управляет swap внутри workflow):
```bash
make backup-verify SRC_ENV=... DST_ENV=... APP=... FORCE=1
```

Решение 2 — вручную (orchestrator делает это автоматически на шаге workspace-swap, но если хотите контроль):
```bash
TS=$(date +%s)
SWAP="apps/conf.bak-before-verify-$TS"
mv apps/conf "$SWAP"
mkdir -m 700 apps/conf
# Если в исходном apps/conf был _example, скопировать его обратно:
[ -d "$SWAP/_example" ] && cp -rp "$SWAP/_example" apps/conf/_example

make backup-verify SRC_ENV=... DST_ENV=... APP=...

# Восстановить после:
rm -rf apps/conf
mv "$SWAP" apps/conf
```

### preflight: `PG major version src==dst` FAIL

```
✗  PG major version src==dst   src=17 dst=18 — pg_dumpall между мажорными версиями ненадёжен
```

`pg_dumpall` от старшей версии PG восстанавливаемся в младшую — не гарантировано. Restore может частично работать, но FAIL'ы тихие.

Решение: поднять PG на DST_ENV до версии SRC_ENV. Обновите `postgres/values-$DST_ENV.yaml`: `image.tag` → версия prod.

### env-restore: «архив этого env применяется в свой же кластер»

```
✗ Sanity-check fail: kubeconfig источника (k8s/config/prod) и целевой KUBECONFIG указывают на ОДИН кластер
```

Опечатка KUBECONFIG → snapshot prod бы поехал обратно в prod. Если вы делаете DR того же env намеренно — `ALLOW_SRC_EQUALS_DST=1`.

### data-restore: kafka-restore-meta-topics упал по auth

Возможная причина — KRaft metadata пуст (clean DST), SCRAM user1 ещё не создан bitnami chart'ом провижионером, restore-meta-topics не может подключиться.

Решение: проверьте логи kafka pod'ов после `make up` — должны видеть «Created user user1». Если нет — может потребоваться `make kafka-bootstrap ENV=$DST_ENV` (см. [`kafka/BACKUP.md`](../../kafka/BACKUP.md), раздел «KRaft cluster-id и восстановление PV»). После этого:
```bash
make backup-verify SRC_ENV=... DST_ENV=... APP=... SKIP_STEPS=preflight,fetch
```

### diff: structural FAIL для MinIO bucket versioning

Причина: `minio-restore-meta` не применяет `buckets/<bucket>-versioning.json` обратно (см. аудит в плане). Это известная gap в `minio-backup-meta`/`restore-meta`.

Решение — отдельная задача (либо patch в minio/Makefile, либо ручное `mc version enable local/<bucket>` после restore). Не блокер для самого пайплайна.

### diff: informational data расходится для всех 5 не-Postgres сервисов

**Это ожидаемо** (см. disclaimer в начале runbook'а). Verdict diff остаётся PASS, потому что informational — soft.

Если хотите подавить warning — отдельный data-mirror flow (вне текущего scope).

### orchestrator: hang после `make down`

PVC не удаляются за `TIMEOUT_PVC_DELETE` (default 180s). Обычная причина — finalizer на pod, который не завершается graceful.

Решение:
```bash
# В другом терминале:
kubectl --kubeconfig k8s/config/$DST_ENV get pod -A | grep Terminating
kubectl delete pod ... --force --grace-period=0
```

Затем повторно: `make backup-verify SRC_ENV=... DST_ENV=... APP=... CLEAN=1`.

### orchestrator: Ctrl-C

Trap EXIT/INT/TERM в `backup-verify.sh` **всегда** восстанавливает `apps/conf` swap. Если по какой-то причине не сработал — swap-каталог `apps/conf.bak-verify-<TS>/` останется рядом с пустым `apps/conf/`. Восстановите вручную:
```bash
rm -rf apps/conf
mv apps/conf.bak-verify-<TS> apps/conf
```

### Resume после FAIL: всегда `CLEAN=1`

`postgres-restore` под `PG_ON_ERROR_STOP=1` (включает оркестратор по дефолту, см. PR1.1) при повторном запуске на «грязном» DST_ENV падает на первом же `CREATE ROLE postgres` из дампа (роль уже существует). Аналогично — `CREATE USER` в ClickHouse, conflict в Kafka topics, etc.

Поэтому: если verify упал на шагах 5+, перезапуск **должен** идти с `CLEAN=1`:
```bash
make backup-verify SRC_ENV=... DST_ENV=... APP=... CLEAN=1
```

`CLEAN=1` выполняет `make down` + `kubectl delete pvc` для всех platform-namespaces + ждёт удаления PVC. После этого DST_ENV пустой, и повтор идёт по чистому пути.

Если `CLEAN=1` сам зависает на удалении PVC — см. [«orchestrator: hang после make down»](#orchestrator-hang-после-make-down).

### Verify FAIL: prod-creds в apps/conf

Если `apps/conf` не существовал на admin до запуска (типично на чистой verify-машине), env-restore создаёт `apps/conf/<APP>/<SRC_ENV>/secrets.yaml` с **prod-creds**. После verify orchestrator перемещает их в `apps/conf.from-verify-<TS>/` (с пометкой в logs), чтобы они **не оставались в активном `apps/conf/`**. Если хотите использовать prod-creds локально (например, для повторной отладки) — переносите вручную из `apps/conf.from-verify-<TS>/`.

Если `apps/conf` существовал до запуска — он временно перемещён в `apps/conf.bak-verify-<TS>/` и **возвращён обратно** trap-cleanup'ом. prod-creds, которые лежали в swap-каталоге во время verify, сохраняются как `apps/conf.restored-<TS>/`.

### Verify завершился PASS, но приложение не работает

`PASS` означает: бэкапы восстановимы, схема/ACL/IAM соответствуют источнику, smoke прошёл. Но **данные** для 5 сервисов не восстановлены (см. disclaimer). Если APP полагается на конкретные сообщения Kafka / объекты MinIO / строки ClickHouse — этого verify-flow недостаточно. Нужен data-mirror.

---

## Расширения (вне текущего scope)

| Что | Зачем | Как |
|---|---|---|
| **Data-mirror layer** | Восстановление объёмных данных для verify | `mc mirror` (MinIO), MirrorMaker2 (Kafka), scripted RDB restore (Redis), `clickhouse-backup` tool, для RabbitMQ federation |
| **Эфемерные namespace внутри local** | Параллельные verify разных APP без CLEAN | Suffix namespace'ов: `postgres-verify-<TS>`, `redis-verify-<TS>`, ... + values-overlay |
| **Параллельные verify** | Быстрее verify N приложений | flock на `<svc>/backups/<ENV>/` (уже есть PID в timestamp — PR1.6); запуск orchestrator'ов в фоне |
| **Slack/email алёртинг** | Уведомление при FAIL | hook в `summary.json` → `curl <slack-webhook>` |
| **Multi-DST_ENV** | Verify в нескольких целевых средах одновременно | Внешний orchestrator (cron + matrix) |
| **GitOps verify** | Запуск из CI на каждый PR | Kind-cluster + mock backups + scenario tests |

Каждое — отдельная задача с собственным runbook'ом.

---

## Связанные команды (cheat-sheet)

```bash
# Отдельные шаги (для отладки):
make backup-verify-preflight SRC_ENV=prod DST_ENV=local APP=myapp
make backup-fingerprint APP=myapp ENV=prod ROLE=source
make backup-verify-fetch SRC_ENV=prod APP=myapp
make backup-verify-localize DST_ENV=local APP=myapp [LOCALIZE_DRY_RUN=1]
make backup-fingerprint APP=myapp ENV=local ROLE=dst
make backup-fingerprint-diff SRC_FINGERPRINT=... DST_FINGERPRINT=...

# Полный пайплайн:
make backup-verify SRC_ENV=prod DST_ENV=local APP=myapp \
    [CLEAN=1] [CLEAN_AFTER=1] [STOP_ON_FAIL=0] [FORCE=1] \
    [SKIP_STEPS=preflight,fetch,...] [SRC_FINGERPRINT=path] \
    [BACKUP_AGE_KEY_FILE=path]

# Связанные:
make env-label-backfill ENV=<env>              # одноразовый backfill labels
make doctor ENV=<env>                          # быстрый smoke (не нужно verify-pipeline)
make backup-all ENV=<env>                      # на источнике
make env-backup ENV=<env> CONFIRM=1            # на источнике
```
