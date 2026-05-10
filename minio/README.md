# MinIO Chart для Kubernetes (Bitnami)

S3-совместимое объектное хранилище на основе Bitnami chart: **standalone-mode**
(один pod, осознанно для single-node microk8s; на multi-node distributed имеет
смысл, у нас не используется), root-учётка в Secret `minio/minio`, IAM users
с per-app policies + bucket-префиксами создаются через `make app-create`.
Образы — из локального registry microk8s (`localhost:32000/bitnami/*`).

## Требования

- Helm 3.x, kubectl, Docker.
- `python3` — для генерации IAM policy JSON в `app-create` / `app-append`
  (`scripts/minio-build-app-policy.py`).
- `jq` — для `app-drop MINIO_REMOVE_BUCKETS=1` (парсинг `buckets.json` из
  tracking-secret).

## Подготовка образов

```bash
microk8s enable registry
make images-sync                      # pull → tag → push в localhost:32000
```

Оффлайн:
```bash
make images-pull images-save          # tar в images/
make images-sync-from-files           # на целевой машине
```

## Деплой

```bash
# Из корня репозитория (рекомендуется)
make minio-up ENV=local

# Или из minio/
make install ENV=local
```

> `make install` (как и корневой `make up`) сам создаёт Secret `minio/minio`
> со случайным `root-password` через `openssl rand -hex 16` и `root-user=admin`,
> если его ещё нет. Прямой `helm install minio ./minio -f values-local.yaml`
> требует pre-existing Secret.

После деплоя: `https://s3.<your-domain>` (prod, ingress включён) или
`kubectl port-forward svc/minio -n minio 9000:9000` (local).

## App accounts (изоляция по приложениям)

Базовый flow — IAM user с access/secret-key + policy на bucket-префикс.
Пароль (`secret_key`) приложения берётся из `apps/conf/<APP>/secrets.yaml`
через `apps-merge-config`.

```bash
# Из корня
make minio-app-create APP=myapp ENV=local              # bucket=myapp, private_rw
make minio-app-show-creds APP=myapp ENV=local
make minio-app-verify    APP=myapp ENV=local           # smoke: mc alias + mc ls
make minio-app-drop      APP=myapp ENV=local           # IAM user + policy + Secret
make minio-app-drop      APP=myapp MINIO_REMOVE_BUCKETS=1 ENV=local   # + удалить bucket'ы

# Или из minio/
make app-create APP=myapp ENV=local
make app-append APP=myapp BUCKET=myapp-archive PREFIX=2026/ ACCESS_MODE=private_ro ENV=local
```

### Параметры `make app-create`

| Параметр | Дефолт | Назначение |
|---|---|---|
| `APP` | (обязательный) | Имя приложения, используется в `<APP>-minio` Secret и `app_<APP>` IAM-username |
| `APP_NS` | `<APP>` | Namespace, куда положить Secret с кредами |
| `BUCKET` | `<APP>` | Имя bucket'а (создаётся, если нет) |
| `PREFIX` | `""` | Префикс ключей внутри bucket'а; пустой = доступ ко всему bucket |
| `ACCESS_MODE` | `private_rw` | `private_rw` / `private_ro` / `private_wo` |
| `PUBLIC_READ` | `false` | Анонимный GetObject (best-effort через `mc anonymous set-json`) |
| `PUBLIC_LIST` | `false` | Анонимный ListBucket в дополнение к PUBLIC_READ |
| `VERSIONING` | `skip` | `enable` / `suspend` / `skip` |
| `QUOTA` | `skip` | Размер `10Gi`, `100Gi` или `skip` |
| `TAGS` | `skip` | `k=v,k2=v2` или `skip` |
| `LIFECYCLE_JSON` | `skip` | Путь к JSON-файлу с ILM rules или `skip` |
| `OBJECT_LOCK` | `skip` | `skip` / `governance` / `compliance` (только при создании bucket!) |
| `RETENTION_DAYS` | — | Default retention (только если `OBJECT_LOCK != skip`) |
| `ACCESS_KEY` | `app_<APP>` | Override IAM-username; иначе берётся из merged-config или дефолт |
| `SECRET_KEY` | merged-config | `minio.secret_key` из `apps/conf/<APP>/`; CLI override через `SECRET_KEY=` |
| `MINIO_SCHEME` | `http` | `http` / `https` (для `MINIO_ENDPOINT` в Secret приложения) |
| `APP_PUBLIC_ENDPOINT` | (отсутствует) | Внешний URL (`https://files.myapp.com`) для presigned-URL — пишется в Secret отдельным полем |

Что попадает в Secret `<APP_NS>/<APP>-minio`:
- `MINIO_ENDPOINT` (внутрикластерный), `MINIO_PUBLIC_ENDPOINT` (внешний для presign)
- `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (стандартные имена SDK)
- `S3_BUCKET` / `S3_PREFIX`
- `AWS_REGION` (`us-east-1` фиктивный, MinIO его не валидирует)

Дополнительно в namespace `minio` создаётся **tracking-secret** `minio-app-<APP>`
с `buckets.json` — список bucket+prefix+access_mode, нужен для `app-append`
(добавление дополнительного bucket к существующей IAM-учётке).

### Multi-bucket: `app-append`

```bash
make app-append APP=myapp BUCKET=archive PREFIX=cold/ ACCESS_MODE=private_ro
```

Чарт-helper `scripts/minio-build-app-policy.py` пересобирает combined-policy
по обновлённому `buckets.json`, применяет через `mc admin policy create` и
attach'ит к существующей IAM-учётке. Tracking-secret обновляется атомарно.

### Presigned URL и публичный доступ

Рекомендуемая схема для веб-приложений: пользователи **не получают** постоянные S3-ключи; backend после проверки JWT/session выдаёт **presigned URL** (GET/PUT/POST). Снаружи используется **path-style**: `https://files.appA.com/<bucket>/<key>`.

Ingress для MinIO API настраивается в `minio/values-$(ENV).yaml` (блок `ingress:`). По умолчанию `console.ingress` выключен и не должен публиковаться в интернет. Чтобы presigned URL подписывались на «внешний» домен, при `app-create` передавайте `APP_PUBLIC_ENDPOINT`.

### CORS

Если браузер ходит по presigned URL напрямую — настройте CORS на bucket через `mc cors set` (XML). Минимальный пример (фронт `https://appA.com`):

```xml
<CORSConfiguration>
  <CORSRule>
    <AllowedOrigin>https://appA.com</AllowedOrigin>
    <AllowedMethod>GET</AllowedMethod>
    <AllowedMethod>HEAD</AllowedMethod>
    <AllowedMethod>PUT</AllowedMethod>
    <AllowedMethod>POST</AllowedMethod>
    <AllowedHeader>*</AllowedHeader>
    <ExposeHeader>ETag</ExposeHeader>
    <MaxAgeSeconds>3600</MaxAgeSeconds>
  </CORSRule>
</CORSConfiguration>
```

## Бэкапы и восстановление

`make backup-meta` сохраняет **definitions**: IAM users, policies (содержимое),
buckets с настройками (versioning + ILM + anonymous policy), tracking-secrets
`minio-app-*`. **Содержимое bucket'ов (объекты) не бэкапится** — для них
используется `mc mirror` или snapshot PV (см. BACKUP.md).

```bash
make backup-meta              ENV=local        # backups/minio-meta-*.tar.gz
make list-backups
make restore-meta             BACKUP_FILE=backups/minio-meta-…tar.gz ENV=local
```

`restore-meta` восстанавливает policies + tracking-secrets. **IAM-users
(secret_key)** не восстанавливаются автоматически (mc их не экспортирует) —
для них:

```bash
make apps-apply ENV=local ENABLED_SERVICES=minio
```

Полный disaster-recovery flow (включая root creds и опции snapshot PV) —
см. **[BACKUP.md](BACKUP.md)**.

## Полезные команды

```bash
make help                   # сводка по всем командам
make status                 # helm + поды + svc + PVC
make logs                   # логи первого pod
make shell                  # shell в первый pod
make images-verify          # SRC-теги в bitnamilegacy
make check-registry         # localhost:32000
make check-updates          # доступные версии чарта в bitnami
make uninstall              # ⚠ удалит helm release (PVC и Secret minio останутся)
```

## Используемые образы

Теги в `minio/Makefile` (переопределяются через `MINIO_TAG` /
`MINIO_CLIENT_TAG` / `MINIO_OBJECT_BROWSER_TAG` / `OS_SHELL_TAG`):

1. **bitnami/minio** — основной сервер S3
2. **bitnami/minio-client** (`mc`) — для admin-операций через kubectl run
3. **bitnami/minio-object-browser** — Web UI (доступен через `console.ingress`,
   по умолчанию выключен)
4. **bitnami/os-shell** — init container для volumePermissions

Source-образы тянутся из `docker.io/bitnamilegacy/*` (теги совпадают с
локальными — `*_SRC_TAG ?= $(MINIO_TAG)`), перетегируются в
`localhost:32000/bitnami/*`.

## Standalone vs distributed

`mode: standalone` зафиксирован в `values-{local,prod}.yaml`:
- На single-node microk8s `distributed` (минимум 4 pods + 4 PVC) не даёт
  выигрыша по надёжности — все pod'ы на одной ноде, потеря ноды убивает всё.
- Standalone достаточен для текущей нагрузки (см. `Critical 2` в ревью —
  prod-профиль рассчитан на ~50Gi PVC).
- При переходе на multi-node кластер имеет смысл переключиться на
  `mode: distributed` с `statefulset.replicaCount: 4` и `podAntiAffinity`.

## Console (Web UI)

`console.enabled: true` в обоих env, но `console.ingress.enabled: false` —
веб-консоль доступна только через port-forward или `kubectl port-forward`.
Публиковать MinIO Console наружу не рекомендуется (admin-доступ к IAM).

## Дополнительно

- [BACKUP.md](BACKUP.md) — детально про backup-meta и DR-сценарии (включая
  snapshot PV для содержимого bucket'ов).
- [Bitnami MinIO Chart](https://github.com/bitnami/charts/tree/main/bitnami/minio).
- [scripts/minio-build-app-policy.py](../scripts/minio-build-app-policy.py) —
  helper для генерации IAM policy JSON.
- Корневой `CLAUDE.md` / `README.md` — общие соглашения (envs, helmfile,
  apps-merge).
