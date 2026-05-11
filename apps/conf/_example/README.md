# Шаблон `apps/conf` для приложения

Этот каталог коммитится в git как **образец**. Рабочие секреты — в `../<имя_приложения>/<ENV>/` (не в git, кроме зашифрованных `*.enc.yaml`).

## Структура: `apps/conf/<APP>/<ENV>/`

Каждое приложение хранит секреты **в подкаталоге по окружению**:

```
apps/conf/
  _example/          ← этот каталог (коммитится)
  myapp/
    local/
      secrets.yaml   ← gitignored
    prod/
      secrets.yaml   ← gitignored
      secrets.enc.yaml ← в git (зашифрован sops+age)
```

`ENV` задаётся при вызове make-целей (`ENV=local`, `ENV=prod`, `ENV=stage`).

## Два workflow для секретов

| Файл | В git? | Когда использовать |
|---|---|---|
| `apps/conf/<APP>/<ENV>/secrets.yaml` | **нет** (gitignored) | Простейший случай, секреты передаются вне git (rsync, env-backup-архив) |
| `apps/conf/<APP>/<ENV>/secrets.enc.yaml` | **да** (зашифрован sops+age) | Когда секреты должны жить в git (распределённая команда, history) |

Если в каталоге окружения есть **оба** файла — `secrets.yaml` имеет приоритет (override). Это удобно для локальной разработки: расшифровать в `secrets.yaml` через `make apps-conf-decrypt APP=... ENV=...`, отредактировать, потом `make apps-conf-encrypt APP=... ENV=...` обратно.

Включение sops+age — краткий cheat-sheet [docs/runbooks/sops-quickstart.md](../../../docs/runbooks/sops-quickstart.md), полный runbook [docs/runbooks/secrets-management.md](../../../docs/runbooks/secrets-management.md). Образец конфигурации — [.sops.yaml.example](./.sops.yaml.example).

## Быстрый старт

- Команда: **`make apps-conf-template APP=myapp ENV=local`** — копирует `*.yaml` / `*.yml` отсюда в `apps/conf/myapp/local/` и по умолчанию добавляет в [`apps/registry.yaml`](../../registry.yaml) запись `enabled: false`, `app_ns: myapp`.
- Только файлы, без правки registry: **`make apps-conf-template APP=myapp ENV=local SKIP_REGISTRY=1`**
- Интерактивно: **`make infra`** → **Сценарии → Подключить приложение** (шаг 2 — apps-conf-template, шаги 3-4 — секреты и конфигуратор).

## Дальше

1. Заполните пустые поля в `secrets.yaml` (или используйте конфигуратор `node scripts/configure-infra.mjs` для генерации паролей).
2. При необходимости выставьте **`enabled: true`** в `apps/registry.yaml` (среди `enabled: true` имена **`name`** должны быть уникальны).
3. Проверка: **`make apps-merge-print ENV=...`**, затем **`make apps-apply ENV=...`**.

Подробнее: корневой [README.md](../../../README.md) и [docs/pg-app.md](../../../docs/pg-app.md).
