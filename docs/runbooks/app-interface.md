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

Дополнительные переменные по методу:

| Метод | Доп. переменные |
|---|---|
| `rollback` | `REVISION` — номер ревизии (может быть пустым: откат к предыдущему) |
| `logs` | `FOLLOW=1` — следить за потоком; `CONTAINER` — имя контейнера |
| `shell` | `CONTAINER` — имя контейнера |
| `seed` | `SKIP_CONFIRM=1` — пропустить подтверждение (уже подтверждено TUI/Makefile) |

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
