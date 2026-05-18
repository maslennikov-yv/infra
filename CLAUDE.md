# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Что это за репозиторий

Инфраструктура данных в Kubernetes (microk8s): локальные Helm-чарты для PostgreSQL, Redis, Kafka, RabbitMQ, MinIO, ClickHouse и Netdata, оркестрируемые через `helmfile` и корневой `Makefile`. Образы тянутся из `docker.io/bitnamilegacy/*`, сохраняются в tar и публикуются в локальный registry microk8s (`localhost:32000`) — это даёт офлайн-сборку и независимость от закрытия старых тегов в Bitnami.

Подробности эксплуатации — в `README.md` и README внутри каталогов сервисов; сценарии работы — `docs/runbooks/usage-scenarios.md`. Расширенные сценарии: `docs/runbooks/disaster-recovery.md` (восстановление на новом сервере), `docs/onboarding-admin.md` (онбординг нового админа), `docs/runbooks/secrets-management.md` (опциональный sops+age для `apps/conf/<APP>/<ENV>/secrets.enc.yaml` в git; краткий cheat-sheet — `docs/runbooks/sops-quickstart.md`), `<service>/BACKUP.md` (backup/restore по сервисам).

## Архитектура

- **Каталог сервиса = модуль.** Каждый сервис (`postgres/`, `redis/`, `kafka/`, `rabbitmq/`, `minio/`, `clickhouse/`, `monitoring/netdata/`) содержит свой Helm-чарт, `values-<ENV>.yaml`, `Makefile`, каталог `images/` для tar-файлов. Никакая «магия» вне этих точек входа не приветствуется.
- **`helmfile.yaml.gotmpl`** в корне — единая точка деплоя. Релизы включаются через `ENABLED_SERVICES=...` (whitelist, приоритетнее) или `EXCLUDE_SERVICES=...` (blacklist). Имя файла values определяется `ENV`: `values-{{ $env }}.yaml`. Для Redis/RabbitMQ helmfile подставляет пароли из Secret в кластере; на «чистом» рендеринге без кластера используйте `helmfile template` с заглушками `REDIS_PASSWORD`/`RABBITMQ_PASSWORD`/`RABBITMQ_ERLANG_COOKIE`.
- **Корневой `Makefile`** инклюдит `environments/$(ENV).mk` (per-env: `SSH_HOST`, `SSH_KEY`, `KUBECONFIG`, `REGISTRY` и т.п.). `KUBECONFIG ?= k8s/config/$(ENV)` — без файла команды с `kubectl` падают намеренно (никаких тихих fallback-ов на `~/.kube/config`).
- **Per-service `Makefile`** работает напрямую через `helm` (не `helmfile`) и используется для управления образами и точечных операций (`make install`/`upgrade`/`uninstall`/`status` и т.д.).
- **Окружения** — суффикс файлов values: `ENV=local` → `values-local.yaml`, `ENV=prod` → `values-prod.yaml`, `ENV=stage` → `values-stage.yaml`. Имя `ENV` должно совпадать с суффиксом — `ENV=staging` ищет `values-staging.yaml`, не `values-stage.yaml`.
- **Overlay для env-specific данных, не попадающих в git.** Каждый release принимает второй values-файл `<svc>/values-<ENV>.local.yaml`, если он существует (helmfile проверяет наличие через `readDir`). Файл gitignored (`**/values-*.local.yaml`) и предназначен для оверрайдов, которые не должны попадать в публичный репозиторий: реальные публичные hostname'ы ingress, личные домены/email'ы для cert-manager, IP-allowlist'ы и т.п. См. `minio/README.md` (раздел «Реальный публичный hostname (overlay)»).

### Учётки и данные приложений (`apps/`)

Вся **специфичная для приложений** информация живёт под `apps/` — не разносить такие данные по произвольным каталогам.

- `apps/registry.yaml` — реестр приложений окружения (**не в git**: содержит реальные имена/namespaces). В git только `apps/registry.yaml.example` как шаблон. У каждой записи обязательно `enabled: true|false`; среди `enabled: true` поля `name` не должны повторяться (это проверяется при merge). На новом клоне: `cp apps/registry.yaml.example apps/registry.yaml`.
- `apps/conf/<APP>/<ENV>/*.yaml` — пер-приложенческие секреты/overrides, разбитые по окружениям (deep-merge с реестром); **не в git**, кроме `apps/conf/_example/`.
- Merge выполняется через `mikefarah/yq` v4 (либо `YQ=...`, либо бинарь `./.tools/yq-mikefarah`).
- `make apps-merge-print` — собранный merge в stdout для отладки.
- `make apps-apply ENV=...` — идемпотентно создаёт учётки (Postgres/Redis/Kafka/RabbitMQ/MinIO/ClickHouse) для каждого `enabled: true` приложения с заданными паролями/ключами в merge. По умолчанию останавливается на первой ошибке `make`; `APPS_APPLY_CONTINUE_ON_ERROR=1` пытается остальные шаги (код выхода всё равно ненулевой при сбоях).
- `make apps-apply-diff ENV=...` — dry-run для `apps-apply`: печатает дельту (would create / update / drop / drift), ничего не меняет. Использовать перед `apps-apply` после правок реестра или `apps/conf/`.
- После `make up` автоматически запускается `apps-apply`, если не задан `SKIP_APPS_APPLY=1`. Те же фильтры `ENABLED_SERVICES` / `EXCLUDE_SERVICES` действуют и для `apps-apply` / `apps-apply-diff`.
- Учётки приложения создают Secret `<APP>-<service>` в namespace приложения (`postgres`, `redis`, `kafka`, `rabbitmq`, `minio`, `clickhouse`); изоляция — на уровне БД/role/ACL/policy/vhost/prefix.

### Lifecycle приложений (infra-interface v2)

Стандартизированный контракт, по которому `infra` управляет lifecycle приложения через его `Makefile` — в том же стиле, что управляет сервисами. Текущая версия — **v2**; v1 жёстко заблокирован (ошибка «обновите до v2»).

**Принцип v2.** Infra передаёт приложению **только секреты + endpoints infra-сервисов** (Postgres / Redis / Kafka / MinIO / ClickHouse / RabbitMQ) — содержимое `apps/conf/<APP>/<ENV>/secrets.yaml`. Не-секретные env-параметры (replicas, ingress host, log level, resources и т.п.) — внутреннее дело приложения и хранятся в его репозитории (`deploy/helm/values-<ENV>.base.yaml`). Никакого merge registry/app.yaml/secrets infra больше не делает.

- **`apps/src/<APP>/infra-interface.yaml`** — `version: 2` + список методов (`render-values` обязательно, далее `deploy`, `rollback`, `status`, `logs`, `migrate`, `seed`, `shell`). Файл живёт в репозитории приложения; infra читает его из `apps/src/<APP>/` (gitignored в infra).
- **`apps/src/<APP>/Makefile.infra`** — реализация `infra-*` целей. Включается через `include Makefile.infra`. Infra вызывает: `make -C apps/src/<APP> infra-<method> ENV=... KUBECONFIG=... APP=... APP_NS=... APP_SECRETS=... VALUES_OUT=... GOMPLATE=...`.
- **`APP_SECRETS`** — путь к `apps/conf/<APP>/<ENV>/secrets.yaml` (plain). Если есть только `secrets.enc.yaml` — infra расшифровывает sops в `apps/.tmp/<APP>-<ENV>.secrets.yaml` (chmod 600) и передаёт его. Если ни того, ни другого — пишет пустой `{}`. Подготовка вынесена в `scripts/app-render-values-prep.sh`.
- **`VALUES_OUT`** — путь, куда приложение должно сохранить отрендеренный values: `apps/src/<APP>/deploy/helm/values-<ENV>.yaml`. Этот же файл используется в `infra-deploy` через `helm -f`. В `.gitignore` приложения: `values-<ENV>.yaml` игнорируется, `values-<ENV>.base.yaml` коммитим.
- `make app-render-values APP=myapp ENV=...` — рендер values-<ENV>.yaml без деплоя (для отладки/проверки). `make app-deploy` сам вызывает `render-values` перед `deploy`.
- `make app-interface-init APP=myapp` — генерирует рыбу v2: `infra-interface.yaml` + `Makefile.infra` + `deploy/helm/values.yaml.gotmpl` (если не существует). `OVERWRITE=1` — перезаписать `infra-interface.yaml`/`Makefile.infra` (но не gotmpl-шаблон).
- `make app-capabilities APP=myapp` — показывает версию, список методов и проверяет наличие целей в Makefile.
- `APP_NS` вычисляется из registry (`app_ns` или дефолт = `APP`); приложение читает доп. секреты из k8s Secret, созданного `apps-apply` (если ему нужны не только те, что в `secrets.yaml`).
- Полный контракт (переменные, ожидания по каждому методу, пример Makefile, миграция v1→v2) — `docs/runbooks/app-interface.md`.

### Образы

Каждый сервис в своём `Makefile` фиксирует список образов и теги (`postgresql`, `os-shell`, `postgres-exporter`, и т.п.). Поток: `docker.io/bitnamilegacy/*` → `*/images/*.tar` → `localhost:32000/bitnami/*`. В values для каждого сервиса задано `image.registry: localhost:32000` и `global.security.allowInsecureImages: true`.

## Часто используемые команды

```bash
# Bootstrap нового окружения
make env-new ENV=staging                         # рыба: environments/staging.mk + .yaml + k8s/config/staging + values-staging.yaml у каждого сервиса
make kubeconfig-fetch ENV=prod SSH_HOST=... SSH_KEY=...   # kubeconfig с удалённого microk8s
make kubeconfig-microk8s-local ENV=local         # kubeconfig локального microk8s (без SSH)
make microk8s-setup ENV=prod                     # настройка microk8s + аддонов + docker на удалённой ноде

# Образы
make images-save ENV=local [SERVICE=redis]       # docker pull + tar
make images-push ENV=local [SERVICE=redis]       # load + tag + push в localhost:32000
make images-push-remote ENV=prod                 # scp tar + загрузка в registry на удалённой ноде

# Деплой стека
make up   ENV=local                              # helmfile apply + apps-apply (если не SKIP_APPS_APPLY=1)
make diff ENV=local                              # helmfile diff
make down ENV=local                              # helmfile destroy
make up   ENV=local ENABLED_SERVICES=postgres,redis
make up   ENV=local EXCLUDE_SERVICES=kafka,clickhouse
make <service>-up|diff|down ENV=...              # шорткат: запускает корневой up/diff/down с ENABLED_SERVICES=<service>

# Учётки приложений (создают Secret <APP>-<service> в namespace приложения)
make pg-app-create        APP=myapp ENV=stage
make redis-app-create     APP=myapp ENV=stage [REDIS_DB=3]
make kafka-app-create     APP=myapp ENV=stage
make rabbitmq-app-create  APP=myapp ENV=stage
make minio-app-create     APP=myapp BUCKET=myapp ACCESS_MODE=private_rw [APP_PUBLIC_ENDPOINT=https://files.myapp.com]
make clickhouse-app-create APP=myapp ENV=stage
make <service>-app-show-creds APP=myapp ENV=...
make <service>-app-drop      APP=myapp ENV=... [SKIP_CONFIRM=1]

# Kafka topics (всегда префикс <APP>.)
make kafka-topic-create APP=appA TOPIC_SUFFIX=events PARTITIONS=6 CONFIGS='retention.ms=...,cleanup.policy=delete'
make kafka-topic-alter  TOPIC=appA.events PARTITIONS=12
make kafka-topic-describe TOPIC=appA.events
make kafka-topic-list   PREFIX=appA.

# PostgreSQL backup/restore
make postgres-backup  ENV=stage
make postgres-restore BACKUP_FILE=backups/stage/postgres-backup-YYYYMMDD-HHMMSS.sql.gz ENV=stage
make postgres-recreate-prep ENV=stage              # бэкап + down + delete PVC (см. postgres/TROUBLESHOOTING.md)

# Per-app бэкапы — apps/backups/<ENV>/<APP>/<service>/<APP>-<scope>-<TS>.<ext>
make app-backup APP=myapp ENV=stage                                # все сервисы APP сразу (по merged конфигу)
make pg-app-backup        APP=myapp ENV=stage
make clickhouse-app-backup APP=myapp ENV=stage
make minio-app-backup     APP=myapp ENV=stage                      # включает данные bucket'а (mc mirror)
make kafka-app-backup     APP=myapp ENV=stage                      # definitions топиков <APP>.*; данные топиков не входят
make rabbitmq-app-backup  APP=myapp ENV=stage                      # vhost-specific definitions; сообщения не входят
make <svc>-app-restore    APP=myapp ENV=stage BACKUP_FILE=apps/backups/stage/myapp/<svc>/...

# Lifecycle приложений (infra-interface v2) — требуют apps/src/<APP>/ и infra-interface.yaml
make app-interface-init APP=myapp [OVERWRITE=1]      # рыба infra-interface.yaml v2 + Makefile.infra
make app-render-values  APP=myapp ENV=prod           # рендер deploy/helm/values-<ENV>.yaml из APP_SECRETS (без деплоя)
make app-capabilities   APP=myapp                    # версия + методы + валидация целей Makefile
make app-deploy         APP=myapp ENV=prod
make app-rollback       APP=myapp ENV=prod [REVISION=N]
make app-status         APP=myapp ENV=prod
make app-logs           APP=myapp ENV=prod [FOLLOW=1] [CONTAINER=name]
make app-migrate        APP=myapp ENV=prod
make app-seed           APP=myapp ENV=prod [SKIP_CONFIRM=1]    # ⚠ деструктивно — запрашивает подтверждение
make app-shell          APP=myapp ENV=prod [CONTAINER=name]

# Диагностика
make status      ENV=...                         # ноды, поды, helm list -A
make top-totals  ENV=...                         # CPU/память: занято/доступно (Metrics API + jq)
make <service>-status|logs|shell ENV=...
make monitoring-top-nodes|events|pod-events|describe-pod ENV=...

# microk8s ingress TCP (порт expose)
make k8s-port-expose-show  ENV=...
make k8s-port-expose-patch ENV=... LAYER=tcp HOST_PORT=1883 BACKEND=ns/svc:1883
make k8s-port-expose-apply ENV=...               # из k8s-port-expose/ports-<env>.yaml; не удаляет лишнее, только доводит до состояния списка

# TUI и помощники
make infra                                        # action-first TUI (альтернативы: npm run infra, ./scripts/infra.mjs, infra после npm link)
make help                                         # подробная справка по корневому Makefile
```

Per-service из каталога сервиса: `make install|upgrade|uninstall|status` (helm напрямую), `make images-pull|save|load|tag|push|sync|sync-from-files`, `make check-registry`.

## Зависимости

- `make`, Helm 3, `helmfile`, `kubectl`, Docker.
- `mikefarah/yq` v4 — для merge `apps/registry.yaml` + `apps/conf/`. Либо `YQ=...`, либо `./.tools/yq-mikefarah`.
- `gomplate` 4+ (опционально, нужен только для приложений с `deploy/helm/values.yaml.gotmpl`) — рендер шаблона values из `APP_SECRETS` (контракт infra-interface v2). `make tools-check` подсказывает установку.
- Node.js 18+ и `npm install` в корне (зависимость `@clack/prompts`) — для `make infra`.
- `jq` — для `top-totals` и `k8s-port-expose-patch`.

## Инженерные правила

- **KISS / YAGNI.** Один сервис — отдельный каталог; общие сценарии — корневой `Makefile` и `helmfile.yaml.gotmpl`. Не плодить абстракции «на будущее».
- **Правки строго по задаче.** Не рефакторить соседние сервисы и не менять стиль без нужды. Если задача про `postgres/` — не трогать `kafka/`, `redis/` и т.п.
- **DRY там, где принято в репо** (общие цели Make, шаблоны helmfile). Дублирование `values-*.yaml` между окружениями осознанно — это не «скопировал и забыл».
- **Явная конфигурация.** Теги образов, `image.registry`, ресурсы, persistence — задаём явно в `values-<ENV>.yaml` без «тихих» дефолтов, скрывающих ошибки.
- **Values не правим mass-sed-ом.** Отдельные файлы и осмысленные правки.
- **Корневая причина, не симптом.** Под в `Pending` — события ноды, PVC, лимиты; неверные креды — цепочка Secret/namespace/`APP`. Не маскировать проблемы костылями в values.
- **Перед критичным применением — `make diff ENV=...`** (или эквивалент по сервису), либо `helmfile template` без кластера.
- **Деструктивные операции** с PVC, reset Kafka и т.п. — только по документации сервиса (`*/TROUBLESHOOTING.md`, `postgres/BACKUP.md` и т.д.). Не выполнять «по наитию».
- **Сообщения оператору с контекстом** (`ENV`, namespace, имя релиза/пода), а не голый traceback. Не глотать ошибки в shell/Make без причины — `set -e`, проверка предусловий (`kubeconfig`, `SSH_HOST`).
- **Config-driven reconciliation для multi-tenant сервисов.** Источник истины для состояния, разделяемого приложениями (ACL/users/policies/topics), — `apps/registry.yaml` + `apps/conf/<APP>/<ENV>/`. Состояние сервиса после `apps-apply` должно быть **равно** desired-state из конфигов, а не результатом последовательности императивных правок. Инварианты:
  - Рестарт пода сервиса не должен терять учётки приложений — данные пользователей живут либо в ConfigMap/чарт-values (для in-memory сервисов вроде Redis ACL), либо в PVC (Postgres/CH/Minio).
  - `app-create`/`app-drop` обновляют per-app данные (apps/conf, Secret в namespace приложения), затем дёргают `*-reconcile` (полная пересборка из реестра). Никаких прямых `SETUSER`/`add_user`/`mc admin user add` в обход источника истины.
  - Действия по одному приложению **не должны** влиять на другие (нет глобальных flush, нет «снеси и пересоздай ACL для всех»). Reconcile применяет diff атомарно (Redis: `ACL LOAD` полностью замещает; RabbitMQ: `import_definitions`; MinIO: `mc admin policy attach/detach` per user).
  - Текущая реализация: Redis (`scripts/redis-acl-reconcile.sh`, `make redis-acl-reconcile ENV=...`). Аналог для других сервисов — отдельный аудит/тикеты.
  - **Redis ACL — двойной путь применения**, чтобы инвариант держался и при рестарте пода без вызова reconcile: (1) `scripts/redis-build-acl-overlay.sh` пересобирает overlay `redis/values-<ENV>.acl.yaml` (gitignored) из merged config; helmfile подхватывает его дополнительным values-файлом для release redis → Bitnami chart рендерит `users.acl` в ConfigMap уже с app-users. (2) `redis-acl-reconcile` параллельно патчит живой ConfigMap + перезаписывает aclfile в поде + `ACL LOAD`. Формат строк users.acl в обоих путях идентичен (`user <name> on #<sha256(pw)> ~<prefix>:* &<prefix>:* +@all <DENY>`) — `helmfile diff` после reconcile нулевой, лишних rolling restart redis-master нет. Корневой `make up`/`make diff` сами вызывают `redis-build-acl-overlay.sh` перед helmfile, поэтому новые приложения попадают в helm-рендер автоматически.

### Что коммитим, что нет

- **В git:** Helm-чарты, `Chart.lock`, `values-<ENV>.yaml`, корневые `Makefile`/`helmfile.yaml.gotmpl`, `apps/registry.yaml.example`, `apps/conf/_example/`, `environments/<env>.yaml` (реестр для `env-backup`), `docs/`, `scripts/`.
- **Не в git** (см. `.gitignore`): `environments/<env>.mk`, `k8s/config/<env>` (kubeconfig), `<service>/images/*.tar`, `apps/registry.yaml` (живой реестр окружения), `apps/conf/<app>/<env>/` (живые секреты; структура `apps/conf/<APP>/<ENV>/`), `apps/src/`, `environments/backups/<env>/` (env-backup tar'ы), `<service>/backups/<env>/` (service-wide бэкапы), `apps/backups/<env>/<app>/<service>/` (per-app бэкапы). Для каждого есть команда (или копирование из `.example`), которая его создаёт (см. раздел в `README.md` «Файлы, которые не коммитятся»).

### Периметр и безопасность

- Ingress и внешние endpoint'ы (MinIO API, console, Netdata, RabbitMQ management) — только осознанно через `values-<ENV>.yaml`. Админские UI не публиковать в интернет без явной необходимости.
- Учётки приложений изолированы по namespace + Secret + ACL/policy/vhost/prefix; пользователи приложений **не получают** постоянные S3-ключи — backend выдаёт presigned URL (для presign на внешний домен передавайте `APP_PUBLIC_ENDPOINT` в `make minio-app-create`).
- **NetworkPolicy** включён в `values-prod.yaml` всех сервисов (Bitnami chart создаёт NP-ресурсы), но `allowExternal: true` делает их функционально noop. План жёсткой сегментации (`allowExternal: false` + `ingressNSMatchLabels: { infra-client: "true" }` + label app-namespaces) — `docs/runbooks/network-policy.md`.
- **Kafka listeners**: client = `SASL_PLAINTEXT` (SCRAM-auth, трафик в plaintext), controller/interbroker = `PLAINTEXT`. Bootstrap chicken-egg: SCRAM-юзеры в KRaft metadata → controller'ы не могут стартовать с SCRAM. Целевое состояние (`SSL` для controller/interbroker через mTLS, `SASL_SSL` для client) и план миграции с downtime — `docs/runbooks/kafka-listener-security.md`.
- **Шифрование бэкапов** — опциональное (по умолчанию выключено). Включается через `BACKUP_AGE_RECIPIENT` (public key) в `environments/<env>.mk`; все backup-цели (`postgres-backup`, `redis-backup`, `kafka-backup-meta`, `minio-backup-meta`, `clickhouse-backup`, `rabbitmq-backup-defs`, `env-backup`, `backup-all`) автоматически шифруют свежий файл, restore — auto-decrypt при `.age` суффиксе. Согласован с sops+age для secrets; см. `docs/runbooks/backups-encryption.md`.
- **storageClass и reclaimPolicy** — `storageClass: ""` (default `microk8s-hostpath`) с `reclaimPolicy: Delete`: случайное удаление PVC уничтожает данные. План перехода на явный SC `microk8s-hostpath-retain` через `<svc>-recreate-prep` — `docs/runbooks/storage-class.md`.
- Примеры в `examples/` согласованы с тем, как в кластере создаются Secret и политики доступа — при изменении flow обновлять и примеры.

## Спец-сценарии (skills из `.claude/skills/`)

- **microk8s ingress TCP / hostPort** (`.claude/skills/k8s-port-expose-microk8s/SKILL.md`). Открытие/закрытие TCP-портов на ноде через `nginx-ingress-microk8s-controller` (DaemonSet `hostPort`) + ConfigMap `nginx-ingress-tcp-microk8s-conf` (`HOST_PORT: "ns/svc:port"`). Открытие нового порта: сначала `LAYER=hostport OP=add`, затем `LAYER=tcp` с `BACKEND`. Удаление — обратный порядок. `DRY_RUN=client|server` для прогона без записи. Для каталога целевого состояния — `make k8s-port-expose-apply ENV=...` (только доводит до состояния списка, **не удаляет** лишнее).

## Язык

Документация репозитория и комментарии в Makefile/values — преимущественно на русском. Сообщения о работе, чеклисты и issues при ревью — на русском; имена ресурсов Kubernetes, переменных и пути к файлам — как в репозитории.
