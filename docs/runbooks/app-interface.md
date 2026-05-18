# App Interface (infra-interface) v2

Контракт, по которому `infra` управляет lifecycle приложения через его `Makefile` — в том же стиле, что управляет сервисами (`postgres/`, `redis/` и т.п.).

## Принцип

Infra **не знает** о внутренней конфигурации приложения (replicas, ingress host, log level, resources и т.п.). Она передаёт приложению только то, чем владеет: **секреты + endpoints infra-сервисов** (Postgres / Redis / Kafka / MinIO / ClickHouse / RabbitMQ). Всё остальное — внутреннее дело приложения и хранится рядом с его чартом.

Генерация `values-<ENV>.yaml` выполняется **в самом приложении** (целью `infra-render-values` в `Makefile.infra`) и запускается infra через метод `render-values`. Параметр — путь к `apps/conf/<APP>/<ENV>/secrets.yaml`.

## Как это работает

1. Приложение кладёт в корень своего репозитория файл `infra-interface.yaml` с декларацией `version: 2` и списком реализованных методов.
2. Приложение реализует соответствующие `infra-*` цели в `Makefile.infra`.
3. Infra читает `apps/src/<APP>/infra-interface.yaml`, валидирует версию и наличие целей, делегирует вызовы:
   ```
   make app-deploy APP=myapp ENV=prod
   # 1) check.sh: версия = 2, методы render-values + deploy реализованы
   # 2) подготовка APP_SECRETS (plain или sops-decrypt в apps/.tmp/<APP>-<ENV>.secrets.yaml)
   # 3) make -C apps/src/myapp infra-render-values  → deploy/helm/values-prod.yaml
   # 4) make -C apps/src/myapp infra-deploy         → helm upgrade -f values-prod.yaml
   ```

## Требования

- `apps/src/<APP>/` — клон репозитория приложения (`make apps-src-clone APP=myapp`).
- `apps/src/<APP>/infra-interface.yaml` — манифест интерфейса (`version: 2`).
- `apps/src/<APP>/Makefile` — `include Makefile.infra`.
- `apps/src/<APP>/Makefile.infra` — реализация целей `infra-*`.
- `apps/src/<APP>/deploy/helm/values.yaml.gotmpl` — шаблон, рендерится в `values-<ENV>.yaml`.

## Формат `infra-interface.yaml`

```yaml
version: 2
implements:
  - render-values   # обязательно: генерация values-<ENV>.yaml из APP_SECRETS
  - deploy          # обязательно если задекларировано
  - rollback
  - status
  - logs
  - migrate
  - seed
  - shell
```

| Поле | Тип | Описание |
|---|---|---|
| `version` | int | Контракт. Infra поддерживает **только v2** (v1 заблокирован: ошибка «обновите до v2»). |
| `implements` | list[string] | Методы, реализованные приложением. Infra проверяет наличие цели `infra-<method>` в Makefile. `render-values` — обязательно для `app-render-values`/`app-deploy`. |

## Переменные, которые infra передаёт

| Переменная | Когда | Описание |
|---|---|---|
| `ENV` | всегда | Окружение: `local`, `prod`, `stage`, … |
| `KUBECONFIG` | всегда | Абсолютный путь к kubeconfig |
| `APP` | всегда | Имя приложения (= поле `name` в registry) |
| `APP_NS` | всегда | Kubernetes namespace (= `app_ns` из registry или `APP` если не задано) |
| `APP_SECRETS` | render-values, deploy, migrate, seed | Абсолютный путь к `secrets.yaml` приложения. Источник: `apps/conf/<APP>/<ENV>/secrets.yaml`. Если есть только `secrets.enc.yaml` — infra расшифровывает sops в `apps/.tmp/<APP>-<ENV>.secrets.yaml` (chmod 600) и передаёт этот путь. Если ни того, ни другого — infra пишет пустой `{}` и передаёт его. |
| `VALUES_OUT` | всегда | Абсолютный путь к месту, куда приложение должно сохранять отрендеренный values: `apps/src/<APP>/deploy/helm/values-<ENV>.yaml`. Этот же файл должен использоваться в `infra-deploy` через `helm -f`. |
| `GOMPLATE` | всегда | Абсолютный путь к бинарю gomplate (или пусто — из PATH) |

Дополнительные переменные по методу:

| Метод | Доп. переменные |
|---|---|
| `rollback` | `REVISION` — номер ревизии (может быть пустым: откат к предыдущему) |
| `logs` | `FOLLOW=1` — следить за потоком; `CONTAINER` — имя контейнера |
| `shell` | `CONTAINER` — имя контейнера |
| `seed` | `SKIP_CONFIRM=1` — пропустить подтверждение |

**Чего infra НЕ передаёт** (v2):
- `APPS_REGISTRY` (registry — внутреннее дело infra).
- `APP_CONFIG` (merge registry + app.yaml + secrets — больше не делается).
- Любой non-secret env-specific параметр (replicas, ingress host, log level, resources, image tag и т.п.).

## Что приложение должно хранить у себя

Контракт v2 предполагает, что приложение знает:
- Свой Helm-чарт `deploy/helm/`.
- Свои env-specific параметры — в `deploy/helm/values-<ENV>.base.yaml` (или в одном `values.yaml.gotmpl` с веткой по `(ds "sec").app.env` — на ваш вкус). Эти файлы лежат **в git репозитория приложения**, не в infra.
- Шаблон `deploy/helm/values.yaml.gotmpl`, который мержит `base` + `sec` → `values-<ENV>.yaml`.

`.gitignore` приложения: коммитим `values-<ENV>.base.yaml`, игнорируем сгенерированный `values-<ENV>.yaml`.

```gitignore
/deploy/helm/values-*.yaml
!/deploy/helm/values-*.base.yaml
```

## Реализация `infra-render-values`

Пример из career2 (`apps/src/career2/Makefile.infra`):

```makefile
CHART      := deploy/helm
GOMPLATE   ?= gomplate
VALUES_OUT ?= $(CHART)/values-$(ENV).yaml
BASE_VALUES := $(CHART)/values-$(ENV).base.yaml

infra-render-values:
	@test -n "$(ENV)" || (echo '✗ ENV не задан' >&2; exit 1)
	@test -n "$(APP_SECRETS)" || (echo '✗ APP_SECRETS не задан' >&2; exit 1)
	@test -f "$(APP_SECRETS)" || (echo "✗ APP_SECRETS не найден: $(APP_SECRETS)" >&2; exit 1)
	@test -f "$(BASE_VALUES)" || (echo "✗ $(BASE_VALUES) не найден" >&2; exit 1)
	@mkdir -p "$(dir $(VALUES_OUT))"
	@$(GOMPLATE) -f "$(CHART)/values.yaml.gotmpl" \
	  -d sec="$(APP_SECRETS)" \
	  -d base="$(BASE_VALUES)" \
	  -o "$(VALUES_OUT)"

infra-deploy:
	@test -f "$(VALUES_OUT)" || (echo "✗ $(VALUES_OUT) не найден — сначала 'make app-render-values'" >&2; exit 1)
	helm upgrade --install $(APP) $(CHART) \
	  --kubeconfig $(KUBECONFIG) -n $(APP_NS) --create-namespace \
	  -f $(VALUES_OUT) --wait --timeout=5m
```

**Важно**: цель `infra-render-values` не должна объявлять файловые prerequisites с переменными именами (`$(VALUES_OUT)`, `$(BASE_VALUES)`) — `app-capabilities` запускает `make -n` для проверки наличия цели без переменных, и при пустом `ENV` make попытается разрешить путь `deploy/helm/values-.base.yaml` и упадёт. Делайте все проверки **внутри рецепта**.

## Пример `values.yaml.gotmpl`

```gotmpl
{{- $base := ds "base" -}}
{{- $sec := ds "sec" -}}
replicaCount: {{ $base.replicaCount | default 1 }}

app:
  env: {{ $base.app.env | quote }}
  logLevel: {{ $base.app.logLevel | default "info" }}
{{- if has $sec.app "key" }}
  key: {{ $sec.app.key | quote }}
{{- end }}

postgres:
  host: {{ $sec.postgres.host | quote }}
  username: {{ $sec.postgres.username | quote }}
  password: {{ $sec.postgres.password | quote }}
  database: {{ $sec.postgres.database | quote }}

{{- with $base.ingress }}
ingress:
{{ . | data.ToYAML | indent 2 }}
{{- end }}
```

## Контракт методов

### render-values
**Обязательный** для приложений, использующих helm с генерируемым values. Читает `APP_SECRETS` (+ собственные base-values приложения), пишет `VALUES_OUT`. Идемпотентен.

### deploy
Идемпотентный деплой (`helm upgrade --install`). Использует уже отрендеренный `VALUES_OUT`. `app-deploy` infra-цели сама вызывает `infra-render-values` перед `infra-deploy`.

### rollback
Откат release к предыдущей (`REVISION` пуст) или заданной ревизии. `APP_SECRETS` не используется.

### status, logs, shell
Чтение состояния. `APP_SECRETS` не используется.

### migrate
Запуск миграций БД. Идемпотентный. Может использовать `APP_SECRETS` для получения подключения.

### seed
**Может быть деструктивным**. Infra спрашивает двойное подтверждение, если не задано `SKIP_CONFIRM=1`.

## Использование из infra

```bash
# Просмотр capabilities и валидация
make app-capabilities APP=myapp

# Рендер values-<ENV>.yaml (без деплоя — для проверки/отладки)
make app-render-values APP=myapp ENV=prod

# Lifecycle
make app-deploy   APP=myapp ENV=prod     # render-values + deploy
make app-rollback APP=myapp ENV=prod [REVISION=3]
make app-status   APP=myapp ENV=prod
make app-logs     APP=myapp ENV=prod [FOLLOW=1] [CONTAINER=php]
make app-migrate  APP=myapp ENV=prod
make app-seed     APP=myapp ENV=prod [SKIP_CONFIRM=1]
make app-shell    APP=myapp ENV=prod [CONTAINER=php]
```

Из TUI (`make infra`): пункт **«Lifecycle приложения»**.

## Инициализация интерфейса в новом приложении

```bash
make apps-src-clone APP=myapp
make app-interface-init APP=myapp           # рыба infra-interface.yaml + Makefile.infra + values.yaml.gotmpl
make app-capabilities APP=myapp
make app-render-values APP=myapp ENV=local  # для проверки
```

`OVERWRITE=1` — перезаписать существующие `infra-interface.yaml` / `Makefile.infra` (но не `values.yaml.gotmpl` — шаблон чарта).

## Версионирование

Версия в `infra-interface.yaml` определяет контракт. Текущая: **v2**.

- **v1 → v2 (текущая граница)**: infra **жёстко блокирует** `version: 1`. Миграция:
  1. `version: 1` → `version: 2`, добавить `render-values` в `implements:`.
  2. Цель `infra-values-render` (если была) переименовать в `infra-render-values`, выпилить зависимость от `APP_CONFIG`, использовать `APP_SECRETS` как datasource.
  3. Не-секретные env-параметры из `apps/conf/<APP>/<ENV>/app.yaml` перенести в репозиторий приложения как `deploy/helm/values-<ENV>.base.yaml`.
  4. `VALUES_OUT` теперь `deploy/helm/values-<ENV>.yaml` (вместо `.tmp/values.yaml`). Обновить `.gitignore` приложения.
  5. `infra-deploy` больше не вызывает gomplate сам — он использует уже отрендеренный `VALUES_OUT`.

При несовместимом изменении контракта (v3+) `version: 2` будет либо поддерживаться с deprecation-warning, либо блокироваться — решение принимается при выпуске.
