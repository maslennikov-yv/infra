# Переход Redis (Bitnami) → Valkey

Сервис `redis` переезжает с Bitnami Redis (`redis/redis`, release `redis`, образы `bitnamilegacy` без
патчей CVE) на Valkey (официальный чарт `valkey-io/valkey-helm`, vendored в `redis/valkey`, release
`valkey`). Отрепетировано на `ENV=local` 2026-10-22.

## Что меняется для приложений

| | Bitnami Redis | Valkey |
|---|---|---|
| Хост в `<APP>-redis` | `redis-master.redis.svc.cluster.local` | `valkey.redis.svc.cluster.local` |
| Старый хост | — | работает: release `redis-compat` держит Service `redis-master` → поды valkey |
| Пароль admin / app-users | Secret `redis/redis`, `apps/conf` | те же (пароли не меняются) |
| ACL, префиксы, `REDIS_DB` | ACL `~<APP>:*`, `databases 128` | то же |
| Модули | ReJSON, RediSearch | valkey-json, valkey-search (`JSON.*`, `FT.*` TEXT/NUMERIC/TAG) |

Клиентский код не меняется. Приложению, которое берёт `REDIS_HOST` из Secret, достаточно рестарта, но
и без него оно продолжит работать через `redis-master`.

## Почему перенос данных — копированием, а не репликой

Valkey не читает RDB Redis 7.4+/8 (формат v12): `Can't handle RDB format version 12`. Поэтому не работают
`REPLICAOF` со старого мастера, восстановление из RDB-бэкапа Redis и `DUMP`/`RESTORE`. Данные переносит
`scripts/redis-copy-keys.py`: читает каждый ключ типизированными командами (string/hash/list/set/zset/
stream/JSON), пишет в Valkey с тем же TTL и сверяет ключ-в-ключ. Объёмы в наших окружениях — сотни
ключей (кэш, очереди, сессии), копирование занимает секунды.

## Порядок (на окружении)

0. **Подготовка (без простоя).**
   - `make images-push-remote ENV=<env> SERVICE=redis` (или `make -C redis images-sync` на ноде) — образы
     `valkey/valkey-bundle` и `oliver006/redis_exporter` в `localhost:32000`.
   - `make redis-backup ENV=<env>` — страховочный бэкап (RDB Redis 8 — для отката в Redis, не в Valkey).
   - Выяснить, кто пишет в Redis: приложения с `redis.password` в `apps/conf/*/<env>/`.
1. **Переход** (простой записи ≈ время копирования + рестарт приложений):
   ```bash
   make redis-migrate-to-valkey ENV=<env>
   ```
   Скрипт (`scripts/redis-migrate-to-valkey.sh`): preflight → release `valkey` рядом со старым →
   **⏸ просит остановить запись приложений** (scale 0 воркеров/API) → копирование + сверка →
   `helm uninstall redis` (PVC `redis-data-redis-master-0` остаётся) → `make up ENABLED_SERVICES=redis`
   (redis-compat + apps-apply, ACL) → `redis-app-verify` по приложениям.
2. **Вернуть приложения** (scale обратно). Новые поды читают `REDIS_HOST=valkey.redis.svc…`.
3. **Проверка:** `make doctor ENV=<env>`, `make backup-fingerprint` по приложениям, `make redis-backup`
   (снимок уже Valkey, заголовок `REDIS0011`), логи приложений без ошибок подключения.

## Откат

Возможен, пока не удалён PVC `redis-data-redis-master-0`. Откатываемся состоянием infra **до перехода**
(старый helmfile ставит release `redis` и подхватывает прежний PVC; release `valkey` он не трогает):

```bash
# 1. Остановить запись приложений.
# 2. Снять compat-Service (он держит имя redis-master).
helm -n redis uninstall redis-compat
# 3. infra на коммите до перехода (gitignored-файлы — ссылками из основного клона).
git worktree add ../infra-pre-valkey <коммит до перехода>
for f in apps/registry.yaml apps/conf k8s/config environments/<env>.mk; do
  ln -s "$PWD/$f" "../infra-pre-valkey/$f"; done
make -C ../infra-pre-valkey redis-up ENV=<env>     # release redis + ACL из apps/conf (старый формат overlay)
# 4. Данные, записанные в Valkey после перехода, — копированием обратно:
#    SRC_URL=<valkey> DST_URL=<redis-master> scripts/redis-copy-keys.py --allow-nonempty
# 5. helm -n redis uninstall valkey  (PVC valkey останется — keepPvc), вернуть приложения.
```

## После перехода (финал миграции)

- Когда все приложения перезапущены с новым `REDIS_HOST` — удалить release `redis-compat`
  (и блок в `helmfile.yaml.gotmpl`).
- Удалить PVC `redis-data-redis-master-0` и каталог `redis/redis` (Bitnami-чарт).
- NetworkPolicy: в `values-prod.yaml` перенесён эквивалент прежней (пропускающей всех) Bitnami-политики;
  жёсткая сегментация — `docs/runbooks/network-policy.md`.

## Известные отличия Valkey

- `INFO server`: `redis_version:7.2.4` (совместимость) + `valkey_version:9.1.x`.
- `ACL GETUSER` отдаёт `databases` и плоские `flags` — `fp_redis` в `backup-fingerprint.sh` сравнивает
  только смысловые поля (пароли, keys, channels, commands).
- Корень контейнера read-only: `redis-cli --rdb` — только в stdout (`--rdb -`).
- Восстановление RDB при `appendonly yes` — только через `make redis-restore-rdb` (см. `redis/BACKUP.md`):
  голый `dump.rdb` в PVC Valkey проигнорирует и стартует пустым.
