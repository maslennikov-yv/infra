# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Что это за репозиторий

Инфраструктура данных в Kubernetes (microk8s): локальные Helm-чарты для PostgreSQL, Redis, Kafka, RabbitMQ, MinIO, ClickHouse и Netdata, оркестрируемые через `helmfile` и корневой `Makefile`. Образы тянутся из `docker.io/bitnamilegacy/*`, сохраняются в tar и публикуются в локальный registry microk8s (`localhost:32000`) — это даёт офлайн-сборку и независимость от закрытия старых тегов в Bitnami.

Подробности эксплуатации — в `README.md` и README внутри каталогов сервисов; сценарии работы — `docs/runbooks/usage-scenarios.md`.

## Архитектура

- **Каталог сервиса = модуль.** Каждый сервис (`postgres/`, `redis/`, `kafka/`, `rabbitmq/`, `minio/`, `clickhouse/`, `monitoring/netdata/`) содержит свой Helm-чарт, `values-<ENV>.yaml`, `Makefile`, каталог `images/` для tar-файлов. Никакая «магия» вне этих точек входа не приветствуется.
- **`helmfile.yaml.gotmpl`** в корне — единая точка деплоя. Релизы включаются через `ENABLED_SERVICES=...` (whitelist, приоритетнее) или `EXCLUDE_SERVICES=...` (blacklist). Имя файла values определяется `ENV`: `values-{{ $env }}.yaml`. Для Redis/RabbitMQ helmfile подставляет пароли из Secret в кластере; на «чистом» рендеринге без кластера используйте `helmfile template` с заглушками `REDIS_PASSWORD`/`RABBITMQ_PASSWORD`/`RABBITMQ_ERLANG_COOKIE`.
- **Корневой `Makefile`** инклюдит `environments/$(ENV).mk` (per-env: `SSH_HOST`, `SSH_KEY`, `KUBECONFIG`, `REGISTRY` и т.п.). `KUBECONFIG ?= k8s/config/$(ENV)` — без файла команды с `kubectl` падают намеренно (никаких тихих fallback-ов на `~/.kube/config`).
- **Per-service `Makefile`** работает напрямую через `helm` (не `helmfile`) и используется для управления образами и точечных операций (`make install`/`upgrade`/`uninstall`/`status` и т.д.).
- **Окружения** — суффикс файлов values: `ENV=local` → `values-local.yaml`, `ENV=prod` → `values-prod.yaml`, `ENV=stage` → `values-stage.yaml`. Имя `ENV` должно совпадать с суффиксом — `ENV=staging` ищет `values-staging.yaml`, не `values-stage.yaml`.

### Учётки и данные приложений (`apps/`)

Вся **специфичная для приложений** информация живёт под `apps/` — не разносить такие данные по произвольным каталогам.

- `apps/registry.yaml` — реестр приложений (в git). У каждой записи обязательно `enabled: true|false`; среди `enabled: true` поля `name` не должны повторяться (это проверяется при merge).
- `apps/conf/<APP>/*.yaml` — пер-приложенческие секреты/overrides (deep-merge с реестром); **не в git**, кроме `apps/conf/_example/`.
- Merge выполняется через `mikefarah/yq` v4 (либо `YQ=...`, либо бинарь `./.tools/yq-mikefarah`).
- `make apps-merge-print` — собранный merge в stdout для отладки.
- `make apps-apply ENV=...` — идемпотентно создаёт учётки (Postgres/Redis/Kafka/RabbitMQ/MinIO/ClickHouse) для каждого `enabled: true` приложения с заданными паролями/ключами в merge. По умолчанию останавливается на первой ошибке `make`; `APPS_APPLY_CONTINUE_ON_ERROR=1` пытается остальные шаги (код выхода всё равно ненулевой при сбоях).
- После `make up` автоматически запускается `apps-apply`, если не задан `SKIP_APPS_APPLY=1`. Те же фильтры `ENABLED_SERVICES` / `EXCLUDE_SERVICES` действуют и для `apps-apply`.
- Учётки приложения создают Secret `<APP>-<service>` в namespace приложения (`postgres`, `redis`, `kafka`, `rabbitmq`, `minio`, `clickhouse`); изоляция — на уровне БД/role/ACL/policy/vhost/prefix.

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
make postgres-restore BACKUP_FILE=backups/postgres-backup-YYYYMMDD-HHMMSS.sql.gz ENV=stage
make postgres-recreate-prep ENV=stage              # бэкап + down + delete PVC (см. postgres/TROUBLESHOOTING.md)

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
make infra-lab                                    # node scripts/infra-lab.mjs (нужен npm install в корне)
make help                                         # подробная справка по корневому Makefile
```

Per-service из каталога сервиса: `make install|upgrade|uninstall|status` (helm напрямую), `make images-pull|save|load|tag|push|sync|sync-from-files`, `make check-registry`.

## Зависимости

- `make`, Helm 3, `helmfile`, `kubectl`, Docker.
- `mikefarah/yq` v4 — для merge `apps/registry.yaml` + `apps/conf/`. Либо `YQ=...`, либо `./.tools/yq-mikefarah`.
- Node.js 18+ и `npm install` в корне (зависимость `@clack/prompts`) — для `make infra-lab` и `make infra-control-parity-check`.
- `jq` — для `top-totals` и `k8s-port-expose-patch`.

## Инженерные правила (адаптировано из `.cursor/rules/general-engineering.mdc`)

- **KISS / YAGNI.** Один сервис — отдельный каталог; общие сценарии — корневой `Makefile` и `helmfile.yaml.gotmpl`. Не плодить абстракции «на будущее».
- **Правки строго по задаче.** Не рефакторить соседние сервисы и не менять стиль без нужды. Если задача про `postgres/` — не трогать `kafka/`, `redis/` и т.п.
- **DRY там, где принято в репо** (общие цели Make, шаблоны helmfile). Дублирование `values-*.yaml` между окружениями осознанно — это не «скопировал и забыл».
- **Явная конфигурация.** Теги образов, `image.registry`, ресурсы, persistence — задаём явно в `values-<ENV>.yaml` без «тихих» дефолтов, скрывающих ошибки.
- **Values не правим mass-sed-ом.** Отдельные файлы и осмысленные правки.
- **Корневая причина, не симптом.** Под в `Pending` — события ноды, PVC, лимиты; неверные креды — цепочка Secret/namespace/`APP`. Не маскировать проблемы костылями в values.
- **Перед критичным применением — `make diff ENV=...`** (или эквивалент по сервису), либо `helmfile template` без кластера.
- **Деструктивные операции** с PVC, reset Kafka и т.п. — только по документации сервиса (`*/TROUBLESHOOTING.md`, `postgres/BACKUP.md` и т.д.). Не выполнять «по наитию».
- **Сообщения оператору с контекстом** (`ENV`, namespace, имя релиза/пода), а не голый traceback. Не глотать ошибки в shell/Make без причины — `set -e`, проверка предусловий (`kubeconfig`, `SSH_HOST`).

### Что коммитим, что нет

- **В git:** Helm-чарты, `Chart.lock`, `values-<ENV>.yaml`, корневые `Makefile`/`helmfile.yaml.gotmpl`, `apps/registry.yaml`, `apps/conf/_example/`, `environments/<env>.yaml` (реестр для `env-backup`), `docs/`, `scripts/`.
- **Не в git** (см. `.gitignore`): `environments/<env>.mk`, `k8s/config/<env>` (kubeconfig), `<service>/images/*.tar`, `apps/conf/<app>/` (живые секреты), `apps/src/`, `environments/backups/`, `<service>/backups/`. Для каждого есть команда, которая его создаёт (см. раздел в `README.md` «Файлы, которые не коммитятся»).

### Периметр и безопасность

- Ingress и внешние endpoint'ы (MinIO API, console, Netdata, RabbitMQ management) — только осознанно через `values-<ENV>.yaml`. Админские UI не публиковать в интернет без явной необходимости.
- Учётки приложений изолированы по namespace + Secret + ACL/policy/vhost/prefix; пользователи приложений **не получают** постоянные S3-ключи — backend выдаёт presigned URL (для presign на внешний домен передавайте `APP_PUBLIC_ENDPOINT` в `make minio-app-create`).
- Примеры в `examples/` согласованы с тем, как в кластере создаются Secret и политики доступа — при изменении flow обновлять и примеры.

## Спец-сценарии (skills из `.cursor/skills/`)

- **Код-ревью** (`.cursor/skills/code-review/SKILL.md`). Любые формулировки «посмотри код», «проверь PR», «всё ли ок с X», «можно ли мержить», «аудит» и т.п. — это запрос на ревью. Применять структурированный чеклист C.L.E.A.R., правила `general-engineering.mdc`, README сервисов; выбрать режим **A** (полный скан), **B** (PR/ветка) или **C** (один модуль/сервис) — приоритет у B, если указаны и ветка, и область. Итог: **чеклист + список issues с приоритетами Critical / Suggestion / Nice to have**, **на русском** (имена ресурсов и пути — как в репо).
- **microk8s ingress TCP / hostPort** (`.cursor/skills/k8s-port-expose-microk8s/SKILL.md`). Открытие/закрытие TCP-портов на ноде через `nginx-ingress-microk8s-controller` (DaemonSet `hostPort`) + ConfigMap `nginx-ingress-tcp-microk8s-conf` (`HOST_PORT: "ns/svc:port"`). Открытие нового порта: сначала `LAYER=hostport OP=add`, затем `LAYER=tcp` с `BACKEND`. Удаление — обратный порядок. `DRY_RUN=client|server` для прогона без записи. Для каталога целевого состояния — `make k8s-port-expose-apply ENV=...` (только доводит до состояния списка, **не удаляет** лишнее).
- **Локальный код приложения в поды через hostPath** (`.cursor/skills/k8s-app-local-src-hostpath/SKILL.md`, только `ENV=local`). Предпочтительно — Helm с условным `app.volumes` (`make apps-local-src-helm-sets ENV=local APP=<name>` выводит готовую `--set` строку, путь = абсолютный `apps/src/<APP>`). Fallback — `make app-local-src-hostpath-mount ENV=local APP=<name> APP_LOCAL_K8S_WORKLOAD=<kind>/<name>` (JSON Patch, `DirectoryOrCreate`, может дрейфнуть при следующем `helm upgrade`).

## Язык

Документация репозитория и комментарии в Makefile/values — преимущественно на русском. Сообщения о работе, чеклисты и issues при ревью — на русском; имена ресурсов Kubernetes, переменных и пути к файлам — как в репозитории.
