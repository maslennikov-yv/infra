# Шаблон `apps/conf` для приложения

Этот каталог коммитится в git как **образец**. Рабочие секреты — в `../<имя_приложения>/` (не в git, кроме зашифрованных `*.enc.yaml`).

## Два workflow для секретов

| Файл | В git? | Когда использовать |
|---|---|---|
| `apps/conf/<APP>/secrets.yaml` | **нет** (gitignored) | Простейший случай, секреты передаются вне git (rsync, env-backup-архив) |
| `apps/conf/<APP>/secrets.enc.yaml` | **да** (зашифрован sops+age) | Когда секреты должны жить в git (распределённая команда, history) |

Если в каталоге приложения есть **оба** файла — `secrets.yaml` имеет приоритет (override). Это удобно для локальной разработки: расшифровать в `secrets.yaml` через `make apps-conf-decrypt APP=...`, отредактировать, потом `make apps-conf-encrypt APP=...` обратно.

Включение sops+age — см. [docs/runbooks/secrets-management.md](../../../docs/runbooks/secrets-management.md). Образец конфигурации — [.sops.yaml.example](./.sops.yaml.example).

## Быстрый старт

- Команда: **`make apps-conf-template APP=myapp`** — копирует `*.yaml` / `*.yml` отсюда в `apps/conf/myapp/` и по умолчанию добавляет в [`apps/registry.yaml`](../../registry.yaml) запись `enabled: false`, `app_ns: myapp`.
- Только файлы, без правки registry: **`make apps-conf-template APP=myapp SKIP_REGISTRY=1`**
- Интерактивно: **`node scripts/infra-lab.mjs`** → Конфигуратор → «Новое приложение: шаблон».

## Дальше

1. Проброс исходников в **чарт приложения** (hostPath на local): образец [helm-app-volumes-values.yaml](helm-app-volumes-values.yaml) и шаги в [docs/runbooks/app-local-sources-helm.md](../../docs/runbooks/app-local-sources-helm.md).
2. Заполните пустые поля в `secrets.yaml` (или используйте конфигуратор infra-lab для паролей).
3. При необходимости выставьте **`enabled: true`** в `apps/registry.yaml` (среди `enabled: true` имена **`name`** должны быть уникальны).
4. Проверка: **`make apps-merge-print`**, затем **`make apps-apply ENV=...`**.

Подробнее: корневой [README.md](../../../README.md) и [docs/pg-app.md](../../../docs/pg-app.md).
