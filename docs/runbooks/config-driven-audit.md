# Аудит config-driven подхода и план закрытия гепов

Дата: 2026-05-08. Документ описывает, насколько полно репозиторий поддерживает сценарий «новый сервер + git clone + бэкапы → идентичный setup», и план закрытия гепов.

---

## 1. Что уже работает хорошо

- **Helmfile + локальные чарты под git**, per-env values (`values-<env>.yaml`), фиксированные теги образов в `*/Makefile` и values, `Chart.lock` у kafka/minio/clickhouse/rabbitmq.
- **`make env-new ENV=<env>`** создаёт полную «рыбу» окружения (mk + yaml + values + kubeconfig placeholder).
- **`.gitignore`** чётко разделяет «что в git / что нет»; документировано в `README.md` («Файлы, которые не коммитятся»).
- **`helmfile.yaml.gotmpl`** с `ENABLED_SERVICES`/`EXCLUDE_SERVICES` — гибкий, идемпотентный whitelist/blacklist.
- **Авто-генерация Secret для redis/rabbitmq в `make up`** (с проверкой существования — идемпотентно).
- **Учётки приложений** в namespace приложения, Secret `<APP>-<service>`, изоляция per-app.
- **`apps-merge-config.sh`** валидирует обязательность `enabled` и уникальность `name` среди enabled-приложений.
- **`pg-app-verify`** — образец smoke-теста для учётки приложения.
- **`kafka-bootstrap`** — двухфазная установка через `values-bootstrap.yaml` → ACL.
- **`make microk8s-setup`** идемпотентен, проверяет аддоны индивидуально.
- **TUI `infra-lab`** зеркалирует CLI через `docs/infra-control/parity-check.mjs`.
- **PostgreSQL backup/restore** полностью покрыт (`make postgres-backup/restore`, `postgres/BACKUP.md`).

---

## 2. Сводная таблица состояния

| Аспект | Состояние |
|---|---|
| Helmfile + чарты в git | OK |
| Per-env values, overrides не в git | OK |
| Образы офлайн (tar + localhost:32000) | OK |
| Реестр приложений в git, secrets вне git | OK |
| Авто-Secret для redis/rabbitmq в `make up` | OK |
| Авто-Secret для **MinIO** в `make up` | **Critical геп** |
| Авто-Secret для kafka в `make up` (через `kafka-bootstrap`) | вызывается отдельно — геп |
| Хардкод postgres `postgres123` / пустой clickhouse password в values | **Critical геп** |
| Backup PostgreSQL | OK |
| Backup Redis / Kafka / MinIO / ClickHouse / RabbitMQ definitions | **Critical геп** |
| `env-backup` k8s Secrets/CM платформы | OK |
| `env-backup` namespaces приложений (`<APP>-<service>` Secret) | **High геп** |
| `env-backup` копирует `apps/conf/<APP>/` и `apps/registry.yaml` | **Critical геп** |
| `make env-restore` | **High геп** |
| Drift: `helmfile diff` | OK |
| Drift: `apps-apply --dry-run` / `apps-apply` дроп при `enabled:false` | High геп |
| Drift: `k8s-port-expose-diff` | Medium геп |
| Версии тулинга (helm/helmfile/kubectl/yq/jq) | Medium геп |
| Pin версии microk8s (`--channel=…`) | Medium геп |
| Smoke-тесты учёток для всех сервисов | High геп |
| `make doctor` (один статус-чек) | High геп |
| Документ disaster recovery | Medium геп |
| Документ онбординга админа | High геп |
| Менеджер секретов (sops/sealed-secrets/vault) | High геп (опционально) |
| Идемпотентность `make up` | OK |

---

## 3. Гепы по приоритетам

### Critical

- **C1.** Бэкап `apps/conf/<APP>/` — единственный носитель паролей приложений; не входит ни в один tar.gz; потеря = потеря всех приложений.
- **C2.** Авто-создание Secret `minio/minio` в `make up` — без него первый деплой MinIO на новом сервере падает (`existingSecret: minio` ожидает готовый Secret).
- **C3.** Backup definitions для Redis (ACL/RDB), Kafka (topics+ACL+SCRAM), MinIO (buckets+policies+IAM+tracking secrets), ClickHouse (schemas+users), RabbitMQ (vhost+users+permissions+queues+exchanges+bindings).
- **C4.** Хардкод admin-паролей в `postgres/values-*.yaml` (`postgres123`) и пустой пароль в `clickhouse/values-local.yaml`. Замена на `existingSecret` + автогенерация в `make up` по аналогии с redis/rabbitmq.

### High

- **H1.** `env-backup` пропускает namespaces приложений (берёт только из `environments/<env>.yaml`); нужно добавить чтение `apps/registry.yaml.apps[].app_ns`.
- **H2.** Нет `make env-restore` (зеркало `env-backup`).
- **H3.** `apps-apply` при изменении `enabled: true → false` не дропает учётку — тихий дрейф; нужен флаг `APPS_APPLY_DROP_DISABLED=1` или предупреждение.
- **H4.** Документация восстановления Kafka KRaft (`kafka-kraft.cluster-id` критичен; PV vs Secret).
- **H5.** `docs/onboarding-admin.md` — нет регламента «как новый админ получает `environments/<env>.mk`, `k8s/config/<env>`, `apps/conf/`, бэкапы».
- **H6.** Менеджер секретов (sops+age, sealed-secrets, vault) — выбор архитектурный; минимум — закрепить регламент в документе.
- **H7.** Smoke-тесты `*-app-verify` для redis/kafka/minio/clickhouse/rabbitmq (по образцу `pg-app-verify`).
- **H8.** `make doctor ENV=<env>` — одна точка проверки: тулинг, кластер, релизы, smoke-тесты учёток.

### Medium

- **M1.** `make tools-check` / `scripts/check-tools.sh` — проверка минимальных версий helm/helmfile/kubectl/yq/jq/openssl/docker.
- **M2.** Pin microk8s channel (`MICROK8S_CHANNEL ?= 1.30/stable` вместо `latest/stable` в `microk8s-setup`).
- **M3.** `Chart.lock` для postgres/redis/netdata (сейчас отсутствует).
- **M4.** `apps-apply --dry-run` / `make apps-apply-diff` — показать дельту перед применением.
- **M5.** `make k8s-port-expose-diff` — drift detection для TCP-портов.
- **M6.** `k8s-port-expose/ports-<env>.yaml` в `.gitignore` + создание из шаблона в `make env-new`.
- **M7.** `docs/runbooks/disaster-recovery.md` — полный сценарий восстановления.
- **M8.** Документация cron-расписаний бэкапов (`postgres/BACKUP.md` упоминает, но не интегрировано).

### Low

- **L1.** Осиротевший `environments/dev.yaml` без `dev.mk` — либо удалить, либо доделать.
- **L2.** `*-recreate-prep` есть только у postgres; для других сервисов нет.
- **L3.** Расширить `make help` секциями backup/restore/doctor по мере появления.

---

## 4. Конкретные изменения по каждому гепу

### C1 — Бэкап `apps/conf/<APP>/`

- **`/home/user/projects/infra/Makefile`**: модифицировать цель `env-backup`. После цикла по namespaces копировать `apps/registry.yaml` и `apps/conf/` (исключая `_example/`) в `$$OUT_DIR/apps/`.
- **`/home/user/projects/infra/scripts/env-restore.sh`** (новый): обратная операция к `env-backup`.
- **`/home/user/projects/infra/Makefile`**: новая цель `env-restore BACKUP_FILE=…`, требует `CONFIRM=1`.
- **`/home/user/projects/infra/docs/runbooks/disaster-recovery.md`** (новый): сценарий полного восстановления.

Зависимость: после H1 (бэкап namespaces приложений), иначе данные несогласованы.

### C2 — Авто-Secret `minio/minio` в `make up`

- **`/home/user/projects/infra/Makefile`** (цель `up`, ~Makefile:594-621): добавить блок генерации Secret `minio/minio` (root-user/root-password) по аналогии с redis/rabbitmq, с проверкой `kubectl get secret`, `openssl rand -hex 16` при отсутствии. Учесть `ENABLED_SERVICES`/`EXCLUDE_SERVICES`.
- **`/home/user/projects/infra/Makefile`**: при включённом `kafka` в активных вызывать `$(MAKE) -C kafka secrets-init` перед helmfile.apply (kafka/Makefile:128-154 уже идемпотентен).

### C3 — Backup/restore per-service

Минимум — definitions, не данные (для данных топиков Kafka — отдельно через MirrorMaker).

- **Redis:** `redis/Makefile.backup/restore` — RDB (`redis-cli --rdb`), `users.acl`, опционально AOF. + `redis/BACKUP.md`.
- **Kafka:** `kafka/Makefile.backup-meta/restore-meta` — `kafka-topics.sh --describe`, `kafka-acls.sh --list`, `kafka-configs.sh --entity-type users`. + `kafka/BACKUP.md` с разделом про KRaft (см. H4).
- **MinIO:** `minio/Makefile.backup-meta/restore-meta` — `mc admin user/policy list`, `kubectl get secrets -n minio -l app=minio-app -o yaml` (tracking secrets). Бэкап содержимого бакетов опционально через `mc mirror`. + `minio/BACKUP.md`.
- **ClickHouse:** `clickhouse/Makefile.backup/restore` — `clickhouse-backup` или `BACKUP DATABASE`. + `clickhouse/BACKUP.md`.
- **RabbitMQ:** `rabbitmq/Makefile.backup-defs/restore-defs` — `rabbitmqctl export_definitions/import_definitions`. + `rabbitmq/BACKUP.md`.
- **Корневой Makefile:** мета-цели `backup-all` / `restore-all`, обновить `make help`.

### C4 — Убрать хардкод admin-паролей

- **`/home/user/projects/infra/postgres/values-{local,prod,stage}.yaml`**: заменить `auth.postgresPassword: "postgres123"` на `auth.existingSecret: postgres-postgresql`. Удалить блок `auth.username/password/database` — за изоляцию приложений отвечает `pg-app-create`.
- **`/home/user/projects/infra/Makefile`** (цель `up`): добавить генерацию Secret `postgres/postgres-postgresql` по аналогии с redis/rabbitmq.
- **`/home/user/projects/infra/clickhouse/values-{local,prod}.yaml`**: задать `auth.existingSecret: clickhouse`; добавить генерацию в корневом `make up`.

### H1 — Бэкап namespaces приложений в `env-backup`

- **`/home/user/projects/infra/Makefile`** (цель `env-backup`): после `NAMESPACES=…` добавить чтение `apps/registry.yaml`:
  ```
  APP_NS=$$($(YQ) -r '.apps[] | select(.enabled == true) | .app_ns' "$(APPS_REGISTRY)" | sort -u)
  NAMESPACES="$$NAMESPACES $$APP_NS"
  ```
  Существующий цикл подхватит и Secret `<APP>-<service>` в namespace приложения.

### H2 — `make env-restore`

См. C1; реализуется одним скриптом `scripts/env-restore.sh`. Применяет архив в обратную сторону: `kubectl apply -f` для всех `secrets.yaml`/`configmaps.yaml` (фильтруя `creationTimestamp`/`resourceVersion`/`uid`); копирует `apps/conf/` если отсутствует.

### H3 — Дроп учётки при `enabled: false`

- **`/home/user/projects/infra/scripts/apps-apply.sh`**: добавить второй проход по записям `enabled: false`. Сравнить с состоянием в кластере; при наличии Secret `<APP>-<service>` — предупредить или (при `APPS_APPLY_DROP_DISABLED=1`) вызвать `*-app-drop`.
- **`/home/user/projects/infra/Makefile`** (цель `apps-apply`): пробросить переменную `APPS_APPLY_DROP_DISABLED`.

### H4 — Документация Kafka KRaft

- **`/home/user/projects/infra/kafka/BACKUP.md`** (новый): отдельный раздел «KRaft cluster-id и PV». Что делать, когда `env-backup` принёс `kafka-kraft` Secret обратно, а PV пустой/непустой. Важно: применить Secret из бэкапа **до** `kafka-bootstrap`.

### H5 — `docs/onboarding-admin.md`

- **`/home/user/projects/infra/docs/onboarding-admin.md`** (новый): какие файлы вне git нужны новому админу, как их получить, безопасные каналы (rsync поверх SSH, не email/git), команды проверки (`make kubeconfig-info`, `make status`, `make doctor`).

### H6 — Менеджер секретов (опционально)

Минимально-инвазивный путь — **sops + age** для `apps/conf/<APP>/secrets.yaml` в git:
- **`/home/user/projects/infra/.sops.yaml`** (новый): правило шифрования.
- **`/home/user/projects/infra/.gitignore`**: разрешить коммит `secrets.enc.yaml`.
- **`/home/user/projects/infra/scripts/apps-merge-config.sh`**: расшифровка sops перед deep-merge.
- **`/home/user/projects/infra/Makefile`**: цели `apps-conf-encrypt`/`apps-conf-decrypt`.
- **`/home/user/projects/infra/docs/runbooks/secrets-management.md`**: регламент age-ключей.

Альтернатива: задокументировать «`apps/conf/` синхронизируется через rsync по SSH между админами», без кода. Решение — за владельцем репо.

### H7 — Smoke-тесты `*-app-verify`

Для каждого сервиса добавить цель по образцу `postgres/Makefile:339-355`:
- **redis/Makefile**: `app-verify` — `redis-cli -u redis://$APP_USER:$APP_PASSWORD/$REDIS_DB PING`.
- **kafka/Makefile**: `app-verify` — `kafka-topics.sh --command-config <client.properties> --list`.
- **minio/Makefile**: `app-verify` — `mc alias set test … + mc ls`.
- **clickhouse/Makefile**: `app-verify` — `clickhouse-client --query "SELECT 1"` под APP-кредами.
- **rabbitmq/Makefile**: `app-verify` — `rabbitmqctl status` + проверка vhost/user.
- **Корневой Makefile**: пробросы `<service>-app-verify APP=…` по образцу `pg-app-verify`.

### H8 — `make doctor`

- **`/home/user/projects/infra/Makefile`**: цель `doctor ENV=<env>`:
  - `tools-check` (см. M1)
  - `kubectl cluster-info`
  - `helm list -A` сверка с активным составом из `helmfile.yaml.gotmpl`
  - для каждого сервиса — `kubectl rollout status`
  - для каждого `enabled: true` приложения — соответствующий `*-app-verify`

### M1 — `make tools-check`

- **`/home/user/projects/infra/scripts/check-tools.sh`** (новый): проверка минимальных версий: helm ≥ 3.14, helmfile ≥ 0.165, kubectl ≥ 1.28, yq (mikefarah) ≥ 4.40, jq ≥ 1.7, openssl, docker. Конкретные минимумы — по факту, что используется в репо.
- **`/home/user/projects/infra/Makefile`**: цель `tools-check`. Зависимость для `doctor`.

### M2 — Pin microk8s channel

- **`/home/user/projects/infra/Makefile`** (цель `microk8s-setup`): заменить `--channel=latest/stable` на `MICROK8S_CHANNEL ?= 1.30/stable`, перекрываемое в `environments/<env>.mk`.
- **`/home/user/projects/infra/README.md`**: задокументировать.

### M3 — `Chart.lock` для postgres/redis/netdata

- В `postgres/postgresql/`, `redis/redis/`, `monitoring/netdata/netdata/` запустить `helm dependency update`, скоммитить `Chart.lock`.
- Корневой `Makefile`: мета-цель `chart-lock-update`.

### M4 — `apps-apply --dry-run`

- **`/home/user/projects/infra/scripts/apps-apply.sh`**: флаг `APPS_APPLY_DRY_RUN=1`. В dry-run режиме печатать «будет создано: …» без `kubectl exec`; сравнивать с уже существующими Secret.
- **`/home/user/projects/infra/Makefile`**: цель `apps-apply-diff`.

### M5 — `k8s-port-expose-diff`

- **`/home/user/projects/infra/scripts/k8s-port-expose-apply-config.sh`**: режим `MODE=diff` — печатать дельту между `ports-<env>.yaml` и live (DaemonSet + ConfigMap).
- **`/home/user/projects/infra/Makefile`**: цель `k8s-port-expose-diff`.

### M6 — Gitignore для `ports-<env>.yaml`

- **`/home/user/projects/infra/.gitignore`**: добавить `k8s-port-expose/ports-*.yaml` + `!k8s-port-expose/ports.example.yaml`.
- **`/home/user/projects/infra/Makefile`** (цель `env-new`): копировать `ports.example.yaml` → `ports-$(ENV).yaml` если не существует.

### M7 — `docs/runbooks/disaster-recovery.md`

См. C1; покрывает полный сценарий «git clone + бэкапы → рабочий кластер»:
1. Подготовить новый сервер (microk8s через `microk8s-setup`)
2. Восстановить tar-файлы образов (или re-pull, если bitnamilegacy ещё доступен)
3. `make env-restore ENV=<env> BACKUP_FILE=… CONFIRM=1`
4. `make up ENV=<env>`
5. Восстановить данные (`postgres-restore`, `kafka-restore-meta`, `minio-restore-meta`, `clickhouse-restore`, `rabbitmq-restore-defs`, `redis-restore`)
6. `make doctor ENV=<env>`

### L1 — Осиротевший `environments/dev.yaml`

- Либо `git rm environments/dev.yaml`, либо `make env-new ENV=dev` (создать `dev.mk`).

---

## 5. Порядок работ

```
Этап 1 — Фундамент воспроизводимости (Critical):
  C2 (auto-create minio Secret в make up) ── изолированно
  C4 (убрать хардкод admin-паролей) ── требует осторожности (миграция кластеров)
  ↓
Этап 2 — Безопасность данных (Critical):
  C3 (per-service backup/restore) ── после Этапа 1
  ↓
Этап 3 — Расширение env-backup (High):
  H1 (env-backup namespaces приложений) ── после C3
  H2 (env-restore) ── после H1
  C1 (apps/conf в env-backup) ── после H1+H2
  ↓
Этап 4 — Защита от дрейфа (High):
  H3, H4, M4, M5 ── изолированно
  ↓
Этап 5 — Smoke и diagnostics:
  H7 (per-service app-verify) ── изолированно
  M1 (tools-check) ── изолированно
  H8 (doctor) ── после M1 + H7
  ↓
Этап 6 — Документация:
  H5 (onboarding-admin.md) ── после Этапа 1
  M7 (disaster-recovery.md) ── после Этапов 2-3
  M8 (BACKUP.md cron) ── после C3
  ↓
Этап 7 — Полировка:
  M2, M3, M6, L1, L2
  ↓
Этап 8 (опционально, по решению):
  H6 (sops/sealed-secrets/vault)
```
