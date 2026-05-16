# App Interface (infra-interface)

Контракт, по которому `infra` управляет lifecycle приложения через его `Makefile` — в том же стиле, что управляет сервисами (`postgres/`, `redis/` и т.п.).

## Как это работает

1. Приложение кладёт в корень своего репозитория файл `infra-interface.yaml` с декларацией версии и списком реализованных методов.
2. Приложение реализует соответствующие `infra-*` цели в своём `Makefile`.
3. Infra читает файл (`apps/src/<APP>/infra-interface.yaml`), валидирует и делегирует вызовы:
   ```
   make app-deploy APP=myapp ENV=prod
   # → make -C apps/src/myapp infra-deploy ENV=prod KUBECONFIG=... APP=myapp APP_NS=myapp APPS_REGISTRY=...
   ```

## Требования

- `apps/src/<APP>/` — клон репозитория приложения (`make apps-src-clone APP=myapp`).
- `apps/src/<APP>/infra-interface.yaml` — манифест интерфейса.
- `apps/src/<APP>/Makefile` — реализация `infra-*` целей.

## Формат infra-interface.yaml

```yaml
version: 1
implements:
  - deploy      # обязательно если задекларировано
  - rollback
  - status
  - logs
  - migrate
  - seed
  - shell
```

| Поле | Тип | Описание |
|---|---|---|
| `version` | int | Версия интерфейса. Infra поддерживает до v1. |
| `implements` | list[string] | Методы, реализованные приложением. Infra проверяет наличие цели `infra-<method>` в Makefile. |

Все методы необязательны — объявляйте только те, что реализованы. Вызов незадекларированного метода завершится с понятной ошибкой.

## Переменные, которые infra передаёт при каждом вызове

| Переменная | Описание |
|---|---|
| `ENV` | Окружение: `local`, `prod`, `stage`, … |
| `KUBECONFIG` | Абсолютный путь к kubeconfig |
| `APP` | Имя приложения (= поле `name` в registry) |
| `APP_NS` | Kubernetes namespace (= `app_ns` из registry или `APP` если не задано) |
| `APPS_REGISTRY` | Абсолютный путь к `apps/registry.yaml` |
| `APP_CONFIG` | Абсолютный путь к merged YAML-конфигу приложения (`apps/.tmp/<APP>-<ENV>.merged.yaml`). Содержит запись из registry + deep-merge всех `apps/conf/<APP>/<ENV>/*.yaml` (включая зашифрованные `*.enc.yaml`). Используется как datasource для шаблона `deploy/helm/values.yaml.gotmpl` (gomplate). Файл регенерируется infra перед каждым вызовом `app-*` через `apps-config-merge`. |

Дополнительные переменные по методу:

| Метод | Доп. переменные |
|---|---|
| `rollback` | `REVISION` — номер ревизии (может быть пустым: откат к предыдущему) |
| `logs` | `FOLLOW=1` — следить за потоком; `CONTAINER` — имя контейнера |
| `shell` | `CONTAINER` — имя контейнера |
| `seed` | `SKIP_CONFIRM=1` — пропустить подтверждение (уже подтверждено TUI/Makefile) |

## Конфигурация приложения через `APP_CONFIG`

Infra передаёт в `Makefile.infra` приложения путь к merged YAML — единый файл, в котором собрано всё, что нужно для рендера values:

| Источник | Что добавляет |
|---|---|
| `apps/registry.yaml` (запись `<APP>`) | `name`, `app_ns`, `repo_url`, `repo_branch`, любые пользовательские поля |
| `apps/conf/<APP>/<ENV>/secrets.yaml` (gitignored) | креды postgres/redis/kafka/minio/clickhouse/rabbitmq |
| `apps/conf/<APP>/<ENV>/secrets.enc.yaml` (в git, sops+age) | те же креды, опционально зашифрованные |
| `apps/conf/<APP>/<ENV>/app.yaml` | не-секретные env-specific параметры (replicas, ingress host, ресурсы, log level) |
| `apps/conf/<APP>/<ENV>/*.yaml` (любые другие) | произвольная env-specific конфигурация |

Порядок мержа (`mikefarah/yq` deep-merge): registry → encrypted → plain. Последнее победит.

### Рендер `values.yaml.gotmpl`

Приложение хранит **один** шаблон `deploy/helm/values.yaml.gotmpl` (вместо `values-<ENV>.yaml` для каждой среды) и рендерит его через [gomplate](https://docs.gomplate.ca/) с datasource `cfg`:

```makefile
# Makefile.infra (вырезка)
VALUES_OUT := $(CHART)/.tmp/values.yaml

$(VALUES_OUT): $(CHART)/values.yaml.gotmpl $(APP_CONFIG)
	@test -f "$(APP_CONFIG)" || (echo "✗ APP_CONFIG не найден: $(APP_CONFIG)" >&2; exit 1)
	@mkdir -p "$(CHART)/.tmp"
	gomplate -f "$(CHART)/values.yaml.gotmpl" -d cfg="$(APP_CONFIG)" -o "$(VALUES_OUT)"

infra-deploy: $(VALUES_OUT)
	helm upgrade --install $(APP) $(CHART) -n $(APP_NS) --create-namespace -f $(VALUES_OUT) --wait
```

### Пример `values.yaml.gotmpl`

```gotmpl
replicaCount: {{ (ds "cfg").app.replicas.web | default 1 }}

app:
  env: {{ (ds "cfg").app.env | quote }}
  logLevel: {{ (ds "cfg").app.logLevel | default "info" }}
  {{- with (ds "cfg").app.trustedProxies }}
  trustedProxies: {{ . | quote }}
  {{- end }}

ingress:
  enabled: {{ (ds "cfg").app.ingress.enabled | default false }}
  {{- with (ds "cfg").app.ingress.host }}
  host: {{ . | quote }}
  {{- end }}

{{- with (ds "cfg").app.resources }}
resources:
{{ . | toYAML | indent 2 }}
{{- end }}
```

### Отладка

```bash
make apps-merge-app-print APP=myapp ENV=local      # stdout merged YAML
make apps-config-merge    APP=myapp ENV=local      # запись в apps/.tmp/<APP>-<ENV>.merged.yaml
make -C apps/src/myapp infra-values-print \
  APP_CONFIG=$(realpath apps/.tmp/myapp-local.merged.yaml)
```

### Совместимость

`Makefile.infra` приложения может поддерживать **оба** пути — `values.yaml.gotmpl` и legacy `values-<ENV>.yaml` — пока не все приложения мигрированы. `APP_CONFIG` инфраструктура передаёт всегда; приложение само решает, использовать ли его.

## Контракт методов

### deploy
Идемпотентный деплой приложения в кластер (например, `helm upgrade --install`). При повторном запуске должен обновить release до текущего состояния. Читает секреты подключения из k8s Secret, созданного `apps-apply`.

### rollback
Откат release к предыдущей (`REVISION` пуст) или заданной ревизии. Пример: `helm rollback $APP $REVISION -n $APP_NS`.

### status
Вывод текущего состояния: поды, статус helm release. Должен быть неинтерактивным и завершаться с кодом 0.

### logs
Вывод логов приложения. Если `FOLLOW=1` — следить за потоком (`kubectl logs -f`). Если задан `CONTAINER` — только этот контейнер.

### migrate
Запуск миграций БД (например, `artisan migrate`, `alembic upgrade head`, `flask db upgrade`). Должен быть идемпотентным — повторный запуск на актуальной БД не должен ломаться.

### seed
Наполнение начальными данными. **Может быть деструктивным** (перезаписывает строки). Infra всегда спрашивает двойное подтверждение перед запуском seed, если только `SKIP_CONFIRM=1`.

### shell
Интерактивный shell в pod приложения. Пример: `kubectl exec -it -n $APP_NS deploy/$APP -- bash`. Если задан `CONTAINER` — exec именно в этот контейнер.

## Пример Makefile приложения

```makefile
# Минимальный пример для приложения на Helm
APP_NS     ?= $(APP)
CHART_DIR  := deploy/helm
RELEASE    := $(APP)

infra-deploy:
	helm upgrade --install $(RELEASE) $(CHART_DIR) \
	  -n $(APP_NS) --create-namespace \
	  -f $(CHART_DIR)/values-$(ENV).yaml \
	  --set image.tag=$(shell git rev-parse --short HEAD)

infra-rollback:
	helm rollback $(RELEASE) $(REVISION) -n $(APP_NS)

infra-status:
	helm status $(RELEASE) -n $(APP_NS)
	kubectl get pods -n $(APP_NS) -l app=$(APP)

infra-logs:
	kubectl logs -n $(APP_NS) -l app=$(APP) \
	  $(if $(CONTAINER),--container $(CONTAINER)) \
	  $(if $(filter 1,$(FOLLOW)),-f --tail=100,--tail=200)

infra-migrate:
	kubectl exec -n $(APP_NS) deploy/$(RELEASE) -- php artisan migrate --force

infra-seed:
	kubectl exec -n $(APP_NS) deploy/$(RELEASE) -- php artisan db:seed --force

infra-shell:
	kubectl exec -it -n $(APP_NS) deploy/$(RELEASE) \
	  $(if $(CONTAINER),--container $(CONTAINER)) -- bash
```

## Использование из infra

```bash
# Просмотр capabilities и валидация
make app-capabilities APP=myapp

# Lifecycle
make app-deploy   APP=myapp ENV=prod
make app-rollback APP=myapp ENV=prod [REVISION=3]
make app-status   APP=myapp ENV=prod
make app-logs     APP=myapp ENV=prod [FOLLOW=1] [CONTAINER=php]
make app-migrate  APP=myapp ENV=prod
make app-seed     APP=myapp ENV=prod [SKIP_CONFIRM=1]
make app-shell    APP=myapp ENV=prod [CONTAINER=php]
```

Из TUI (`make infra`): пункт **«Lifecycle приложения»**.

## Как проверить локально (без кластера)

```bash
# Клонировать репо приложения
make apps-src-clone APP=myapp

# Проверить что interface файл корректен и все цели есть
make app-capabilities APP=myapp

# Dry-run деплоя (только если helm chart: добавьте --dry-run в infra-deploy)
make app-deploy APP=myapp ENV=local
```

## Версионирование

Версия в `infra-interface.yaml` определяет контракт. Текущая: **v1**.

При несовместимом изменении контракта версия будет повышена. Приложения, объявляющие версию > поддерживаемой, блокируются с сообщением «обновите infra или понизьте версию».

Понижение версии (приложение объявляет v1, infra поддерживает v1+) — всегда совместимо: infra вызывает только те методы, что задекларированы.
