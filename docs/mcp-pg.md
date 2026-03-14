# PostgreSQL для проекта MCP

База данных PostgreSQL для MCP в окружениях **prod** и **stage**.

## Подключение к серверу

```bash
ssh root@77.246.158.37
```

## Окружения

| Окружение | Сервер        | Kubeconfig        |
|-----------|---------------|-------------------|
| stage     | 77.246.158.37 | k8s/config/stage  |
| prod      | (см. prod.mk) | k8s/config/prod   |

## Быстрые команды

### Получить kubeconfig (stage)

```bash
make kubeconfig-fetch ENV=stage SSH_HOST=77.246.158.37 SSH_USER=root
```

### Проверить поды

```bash
# Локально (с настроенным KUBECONFIG)
export KUBECONFIG=$(pwd)/k8s/config/stage
kubectl get pod -A

# Или через make
make postgres-status ENV=stage
```

### Развернуть PostgreSQL (stage)

```bash
make postgres-up ENV=stage
```

### Создать БД и пользователя для MCP

```bash
make pg-app-create APP=mcp ENV=stage
```

При несовпадении пароля postgres в Secret и в БД:
```bash
make pg-app-create APP=mcp ENV=prod POSTGRES_ADMIN_PASSWORD='фактический_пароль_postgres'
```

После создания Secret `mcp-postgres` в namespace `mcp`:
- `make pg-app-show-creds APP=mcp ENV=stage` — показать креды
- `make pg-app-verify APP=mcp ENV=stage` — проверить подключение
- `make pg-app-drop APP=mcp ENV=stage` — удалить БД, роль и Secret

## Параметры подключения

### Внутри кластера (из пода в Kubernetes)

```
Host: postgres-postgresql.postgres.svc.cluster.local
Port: 5432
Database: app_mcp
User: app_mcp
Password: (из Secret mcp/mcp-postgres, ключ PGPASSWORD)
```

Connection string (с `sslmode=disable`):
```
postgresql://app_mcp:<password>@postgres-postgresql.postgres.svc.cluster.local:5432/app_mcp?sslmode=disable
```

### С локальной машины (port-forward)

```bash
kubectl port-forward -n postgres svc/postgres-postgresql 5432:5432
```

Затем:
```
Host: localhost
Port: 5432
Database: app_mcp
User: app_mcp
Password: (из Secret)
```

## Получение пароля из Secret

```bash
kubectl get secret mcp-postgres -n mcp -o jsonpath='{.data.PGPASSWORD}' | base64 -d
```

Или все креды одной командой:
```bash
make pg-app-show-creds APP=mcp ENV=stage
```

Полный connection string:
```bash
kubectl get secret mcp-postgres -n mcp -o jsonpath='{.data.DATABASE_URL}' | base64 -d
```

## Чеклист деплоя MCP (stage)

1. `make kubeconfig-fetch ENV=stage SSH_HOST=77.246.158.37 SSH_USER=root`
2. `make images-save ENV=stage SERVICE=postgres` (если образы ещё не на сервере)
3. `make images-push-remote ENV=stage SERVICE=postgres`
4. `make postgres-up ENV=stage`
5. `make pg-app-create APP=mcp ENV=stage`
