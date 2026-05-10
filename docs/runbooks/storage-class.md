# StorageClass и reclaimPolicy: текущее состояние и план явного управления

## TL;DR

Сейчас во всех `<svc>/values-*.yaml`:

```yaml
persistence:
  storageClass: ""      # → дефолтный SC кластера
```

В microk8s default-SC — `microk8s-hostpath` с `reclaimPolicy: Delete`.
При удалении PVC (например, `make <svc>-recreate-prep`, `kubectl delete
pvc`, `make down`) — PV удаляется автоматически и каталог
`/var/snap/microk8s/common/default-storage/<volume>` стирается. **Данные
теряются безвозвратно** (вне бэкапов в `<svc>/backups/`).

Целевое состояние — **явный SC** в каждом values + **`reclaimPolicy:
Retain`** для prod, чтобы случайное удаление PVC не уничтожало данные.

## Threat model

Ситуации, в которых текущая `Delete`-policy теряет данные:

- **`make <svc>-recreate-prep`** — задокументированная процедура, но
  если что-то пошло не так в середине (упал backup, неверная команда
  `restore-meta`), данные уже удалены и восстановление возможно только
  из бэкапа.
- **Случайный `kubectl delete pvc -n <ns> <pvc>`** — нет undo.
- **`make down`** — да, удаляет StatefulSet, но Helm НЕ удаляет PVC по
  умолчанию (Bitnami chart). Так что прямого риска от `down` нет.
  Но: pre-cleanup-tag вы потом случайно удалите вручную.
- **Неверный `helm uninstall` без `--keep-history`** — теоретически.

При `reclaimPolicy: Retain`:

- Удаление PVC оставляет PV в состоянии `Released` с данными в hostpath.
- Восстановление: либо `kubectl edit pv <pv> → удалить claimRef → bind
  на новый PVC`, либо `cp -a /var/snap/.../<volume> /var/snap/.../<new>`
  + создать PV вручную.

## Целевое состояние

```yaml
persistence:
  enabled: true
  size: <Gi>
  storageClass: "microk8s-hostpath-retain"   # явный SC, reclaimPolicy: Retain
```

## Текущий аудит кластера

```bash
kubectl get storageclass
kubectl get pvc -A
```

Перед миграцией убедитесь, что:

1. SC `microk8s-hostpath-retain` ещё не существует (см. Шаг 1).
2. PVC инфра-сервисов сейчас используют `microk8s-hostpath` (default).
3. Сторонние PVC (приложения вне `apps/registry.yaml`) тоже на
   `microk8s-hostpath` — **не трогаем** их, только инфра-сервисы.

## Возможные подходы

| # | Подход | Эффект | Риск |
|---|--------|--------|------|
| **A** | Новый SC `microk8s-hostpath-retain` + recreate всех 6 инфра-PVC | Полная защита для инфра-сервисов | Downtime + backup/restore цикл для каждого |
| **B** | `kubectl patch sc microk8s-hostpath -p '{"reclaimPolicy":"Retain"}'` | Глобально для всех PVC в кластере | **Высокий** — затронет gitlab, janus, registry, чужие приложения; их recreate-prep может работать иначе |
| **C** | Только новые сервисы — оставить существующие, для следующих использовать новый SC | Низкое усилие | Защита только для будущих |
| **D** | Документация без runtime-изменений (этот runbook) | Нулевое изменение прямо сейчас | Нулевой защиты — миграция в backlog |

**Рекомендуется подход A** для prod, когда есть maintenance-окно. Сейчас
репо в режиме «D» — ничего не меняется в коде.

## План миграции (подход A)

Делать **сервис за сервисом** в maintenance-окне (downtime ~10–30 минут
на сервис в зависимости от объёма данных).

### Шаг 1. Создать новый StorageClass

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: microk8s-hostpath-retain
provisioner: microk8s.io/hostpath
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
EOF
```

Не делайте его default'ом — пусть default остаётся `microk8s-hostpath`
(чтобы сторонние приложения не наследовали `Retain` неявно).

### Шаг 2. Бэкап данных текущего сервиса

```bash
make <svc>-backup ENV=prod
# Или специфичная цель: postgres-backup, kafka-backup-meta, и т.д.
# Смотри <svc>/BACKUP.md для деталей.
```

### Шаг 3. Обновить values-prod.yaml

В соответствующем `<svc>/values-prod.yaml`:

```yaml
persistence:
  enabled: true
  size: <existing>Gi      # ВАЖНО: размер должен совпадать с текущим
  storageClass: "microk8s-hostpath-retain"
```

Менять размер тут нельзя — у существующего StatefulSet новый PVC должен
быть с тем же размером. Изменение размера — отдельная процедура.

### Шаг 4. Recreate

```bash
make <svc>-recreate-prep ENV=prod
# Сохраняет актуальные Secret'ы, удаляет StatefulSet и старые PVC.
# (PV тоже удалится — у него reclaimPolicy: Delete пока что.)

make up ENV=prod ENABLED_SERVICES=<svc>
# Создаст новый StatefulSet с PVC на microk8s-hostpath-retain.
# PV у него уже будет reclaimPolicy: Retain.
```

### Шаг 5. Restore

```bash
make <svc>-restore<-meta|...> BACKUP_FILE=<path> ENV=prod
# Параметры зависят от сервиса — см. <svc>/BACKUP.md.
```

### Шаг 6. Smoke test

```bash
make <svc>-status ENV=prod
make doctor ENV=prod        # комплексная проверка тулинга + helm vs kafka

# Проверить, что новый PV имеет Retain:
kubectl get pv $(kubectl get pvc -n <ns> -o jsonpath='{.items[0].spec.volumeName}') \
  -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'
# ожидание: Retain
```

### Шаг 7. Repeat для каждого сервиса

postgres → redis → kafka → rabbitmq → minio → clickhouse.

## Smoke-тест защиты от случайного удаления

После миграции проверить, что Retain работает (на dev/stage перед prod):

```bash
# 1. Удалить PVC одного из инфра-сервисов
kubectl delete pvc -n redis redis-data-redis-master-0

# 2. Проверить, что PV остался в Released, не Terminated
kubectl get pv | grep redis
# ожидание: STATUS=Released, RECLAIM POLICY=Retain

# 3. Проверить, что данные ещё на диске
ls /var/snap/microk8s/common/default-storage/redis-redis-data-*

# 4. Восстановление: kubectl edit pv <pv> → удалить spec.claimRef →
# создать новый PVC с volumeName: <pv-name> → данные re-attach.
```

Документировать процедуру восстановления в `<svc>/TROUBLESHOOTING.md`.

## Откат

Если что-то сломалось во время миграции:

1. **Прерывание после Шага 4 без Restore**: `make <svc>-recreate-prep` +
   `make up` + использовать backup из Шага 2 как обычно.
2. **Возврат на старый SC**: вернуть `storageClass: ""` в values,
   повторить Шаги 4-5. Новый SC `microk8s-hostpath-retain` можно оставить
   в кластере — он не используется.

## Risks

- **`storageClass`-у PVC нельзя поменять без recreate**. `kubectl edit
  pvc` с изменением `storageClassName` отказывается:
  `field is immutable`. Только через recreate-prep.
- **Размер PVC тоже immutable** в большинстве SC. При создании нового
  PVC указывайте тот же `size`, иначе Bitnami chart перепишет values
  и StatefulSet попытается создать PVC другого размера.
- **`Retain` не освобождает место автоматически**. Если случайно
  удалили PVC и не восстановили — PV в `Released` остаётся занимать
  диск. Регулярный аудит: `kubectl get pv | grep Released`.
- **На multi-node кластере** hostpath не годится: PV привязан к ноде, и
  при перепланировании pod на другую ноду PV становится недоступен.
  Для multi-node — переходите на NFS / CSI с network storage. Этот
  runbook — для single-node microk8s.
- **Сторонние PVC (gitlab, janus, registry)** остаются на старом SC с
  `Delete` — намеренно, чтобы не затронуть их recreate-сценарии.

## Альтернатива: бэкапы

`reclaimPolicy: Retain` — это **last resort**, не замена бэкапов:

- При уничтожении ноды (диск умер) Retain не помогает. Только
  off-cluster бэкап (`make <svc>-backup`, потом `scp` на другой хост).
- При повреждении данных (corrupted Postgres datafile) Retain даёт
  старые corrupted-данные, бэкап даёт точку до повреждения.

Регулярная задача: `make backup-all ENV=prod` + хранение архивов вне
ноды (S3, другой сервер). Подробности — `<svc>/BACKUP.md` и
`docs/runbooks/disaster-recovery.md`.
