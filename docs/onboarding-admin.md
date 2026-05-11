# Онбординг нового администратора

Документ для случая «у нас уже есть рабочий кластер на сервере X, и мы добавляем нового админа Y, который должен иметь возможность работать с этой инфрой со своей машины». Описывает, **что и как** новый админ получает от существующего, какие проверки делает, в каком порядке.

Для другого сценария — «новый сервер от нуля + бэкапы → восстановить кластер» — см. [docs/runbooks/disaster-recovery.md](./runbooks/disaster-recovery.md).

## Контекст: что коммитится и что нет

Источник правды для разделения — корневой `.gitignore` и раздел «Файлы, которые не коммитятся» в `README.md`. Кратко:

| Категория | В git | Где взять новому админу |
|---|---|---|
| Helm-чарты, `helmfile.yaml.gotmpl`, `Chart.lock`, корневой `Makefile`, `<service>/Makefile`, `<service>/values-*.yaml`, `apps/registry.yaml`, `apps/conf/_example/`, скрипты `scripts/` | да | `git clone` |
| `environments/<env>.yaml` (реестр namespaces для `env-backup`) | да | `git clone` |
| `environments/<env>.mk` (SSH_HOST, SSH_KEY, REGISTRY, KUBECONFIG override) | **нет** | от существующего админа |
| `k8s/config/<env>` (kubeconfig — токен доступа к кластеру) | **нет** | `make kubeconfig-fetch` (по SSH) или от админа |
| `apps/conf/<APP>/*.yaml` (пароли приложений) | **нет** | от существующего админа или из env-backup-архива |
| `<service>/images/*.tar` (offline tar образов) | **нет** | пересоздаются `make images-save`, **или** от админа если `bitnamilegacy` уже недоступен |
| `<service>/backups/` (Postgres dump и т.д.) | **нет** | от существующего админа или из бэкапов |
| `environments/backups/` (env-backup tar.gz) | **нет** | от существующего админа |

---

## Что нужно админу для работы с конкретным окружением

| Файл | Содержимое | Чувствительность |
|---|---|---|
| `environments/<env>.mk` | `SSH_HOST`, `SSH_USER`, `SSH_PORT`, `SSH_KEY`, `REGISTRY`, опционально `KUBECONFIG`, `MICROK8S_CHANNEL` | низкая (host + путь к ключу) |
| `~/.ssh/<key>` | приватный SSH-ключ для доступа к ноде microk8s | **высокая** |
| `k8s/config/<env>` | kubeconfig (token, CA-cert, server URL) | **высокая** (даёт полный доступ к кластеру) |
| `apps/conf/<APP>/*.yaml` (для каждого приложения) | пароли приложений к Postgres/Redis/Kafka/MinIO/ClickHouse/RabbitMQ | **очень высокая** |

---

## Безопасные каналы передачи

⚠️ **Не использовать** для передачи sensitive-файлов: email, незашифрованные мессенджеры, публичные git-репозитории, S3-бакеты без шифрования.

Допустимые варианты в порядке предпочтения:

1. **`scp` поверх SSH** через известный публичный ключ нового админа:
   ```bash
   # на стороне отправителя:
   scp environments/<env>.mk \
       environments/backups/<env>-YYYYMMDD-HHMMSS.tar.gz \
       k8s/config/<env> \
       newadmin@workstation:/tmp/infra-onboarding/
   ```
   Получатель сразу `chmod 600` на чувствительные файлы и переносит в `/opt/infra/`.

2. **`ssh-copy-id` + rsync**:
   ```bash
   rsync -avz --rsync-path="sudo rsync" \
     existing-admin@host:/opt/infra/{environments,k8s,apps/conf} /tmp/restore/
   ```

3. **Менеджер секретов sops+age** — **рекомендуемый канал**, если в репо есть `.sops.yaml`. Существующий админ добавляет ваш age public-key в `.sops.yaml`, делает `sops updatekeys` и `git push` — после `git pull` вы расшифровываете секреты своим private-ключом. Не требует ручной передачи sensitive-файлов между админами. См. [docs/runbooks/secrets-management.md](./runbooks/secrets-management.md).

4. **Зашифрованный tar (`gpg --symmetric`) поверх любого канала**:
   ```bash
   tar -czf - environments/<env>.mk apps/conf/ | gpg --symmetric -o env.tar.gz.gpg
   # передать env.tar.gz.gpg любым способом, парольную фразу — отдельно (например, голосом)
   gpg -d env.tar.gz.gpg | tar -xzf -
   ```

**Никогда** не коммитить эти файлы в git, даже в private репо (история git хранит forever).

---

## Сценарий А: онбординг к существующему кластеру

Стандартный путь — кластер уже работает, новый админ получает доступ:

```bash
# 1. Клон репо
git clone <git-url-of-this-repo> ~/projects/infra
cd ~/projects/infra

# 2. Тулинг
make tools-check
# Установите всё, что < минимума.

# 3. От существующего админа получите (любым из безопасных способов):
#    - environments/<env>.mk
#    - k8s/config/<env>           (если SSH-доступ к ноде нет — иначе можно kubeconfig-fetch)
#    - apps/conf/<APP>/secrets.yaml для каждого активного приложения

mkdir -p k8s/config apps/conf
cp /received/<env>.mk environments/<env>.mk
cp /received/k8s-config-<env> k8s/config/<env>
chmod 600 k8s/config/<env>

# (или, если есть SSH-доступ через переданный environments/<env>.mk:)
make kubeconfig-fetch ENV=<env>

# Применить apps/conf/:
for app in <app1> <app2> ...; do
  mkdir -p apps/conf/$app
  cp /received/apps-conf-$app/*.yaml apps/conf/$app/
  chmod 600 apps/conf/$app/*.yaml
done

# 4. Проверка доступа
make kubeconfig-info ENV=<env>     # kubectl cluster-info
make status ENV=<env>              # ноды, поды, helm releases
make doctor ENV=<env>              # полная диагностика (5 шагов)
```

После `make doctor ENV=<env>` с `✓` новый админ может:
- Делать обычные операции: `make up / diff / down / status / logs / shell / *-backup`.
- Создавать/удалять учётки приложений (`make pg-app-create`, `*-app-drop`).
- Проводить деплои.

---

## Сценарий Б: онбординг через env-backup-архив

Если у существующего админа есть свежий `env-backup` и он передаёт его (вместо разрозненных файлов) — это проще:

```bash
# 1-2 как в сценарии А.
# 3. Получите от админа:
#    - environments/<env>.mk
#    - k8s/config/<env> (или используйте kubeconfig-fetch)
#    - environments/backups/<env>-YYYYMMDD-HHMMSS.tar.gz   (env-backup-архив)

mkdir -p environments/backups k8s/config
cp /received/<env>.mk environments/<env>.mk
cp /received/<env>-YYYYMMDD-HHMMSS.tar.gz environments/backups/

# 4. Восстановите apps/conf/ ИЗ АРХИВА (env-restore, не трогая k8s):
make env-restore \
  BACKUP_FILE=environments/backups/<env>-YYYYMMDD-HHMMSS.tar.gz \
  ENV=<env> \
  SKIP_K8S=1 \
  CONFIRM=1
# Будут скопированы apps/conf/<APP>/ для отсутствующих локально приложений
# и apps/registry.yaml, если локально его нет.

# 5. Проверка.
make doctor ENV=<env>
```

⚠️ `SKIP_K8S=1` важен — без него `env-restore` попытается **применить Secrets/ConfigMaps в кластер**, перезаписав живые. Для онбординга к работающему кластеру это нежелательно. Только для disaster recovery (см. [disaster-recovery.md](./runbooks/disaster-recovery.md)).

---

## Сценарий В: новый админ получает SSH-ключ к ноде (recommended)

Самый чистый вариант — добавить публичный SSH-ключ нового админа на ноду microk8s (через `~/.ssh/authorized_keys` или ansible/cloud-init). Тогда новый админ:

```bash
# В environments/<env>.mk:
SSH_HOST=<host>
SSH_USER=ubuntu
SSH_KEY=~/.ssh/id_<own-key>

# Получает kubeconfig автоматически:
make kubeconfig-fetch ENV=<env>

# apps/conf/ всё равно нужно получить отдельно (в env-backup или прямой передачей).
```

Это устраняет необходимость передавать kubeconfig вручную (и риск его утечки). `kubeconfig-fetch` забирает свежий конфиг с ноды через `microk8s config`.

---

## Передача apps/conf/ через регулярный env-backup

В команде, где админов несколько и они часто меняются, регулярный `make env-backup` + хранение архивов в зашифрованном виде на shared storage упрощает жизнь:

1. На главной ноде/CI:
   ```cron
   0 4 * * * cd /opt/infra && make env-backup ENV=prod CONFIRM=1
   0 5 * * * gpg --symmetric --batch --passphrase-file /etc/secret/env-backup.pass \
              environments/backups/prod/$(date +\%Y\%m\%d)*.tar.gz
   0 6 * * * rsync -a environments/backups/*/*.tar.gz.gpg admin-storage:/backups/
   ```
2. Новый админ получает `env-backup.pass` отдельным каналом (одним разом).
3. При онбординге: `gpg -d /storage/prod-latest.tar.gz.gpg | tar -xzf - -C /tmp/` + `make env-restore SKIP_K8S=1`.

Этот workflow можно автоматизировать через **sops + age** — см. [secrets-management.md](./runbooks/secrets-management.md).

---

## Что админ обязан проверить после онбординга

Минимальный чек-лист:

- [ ] `kubectl get nodes` (через `make kubeconfig-info`) — кластер доступен.
- [ ] `make status ENV=<env>` — все expected helm-релизы в Deployed; поды Running.
- [ ] `make doctor ENV=<env>` — `✓` (5 шагов).
- [ ] `make apps-apply-diff ENV=<env>` — нет drift.
- [ ] Локальный `~/.ssh/<key>` имеет права `600`, `apps/conf/<APP>/*.yaml` — `600`.
- [ ] Понимает, **что нельзя коммитить** (см. таблицу выше).

---

## Что админ обязан НЕ делать

- **Не коммитить** `apps/conf/<APP>/`, `environments/<env>.mk`, `k8s/config/<env>` в git (даже в private репо).
- **Не передавать** kubeconfig и `apps/conf/` через email, неэнкриптованные мессенджеры, public S3, чаты.
- **Не делать `kubectl apply` в namespace `kube-system`** или другие платформенные namespaces без явной задачи.
- **Не запускать `make microk8s-uninstall`** без согласования.
- **Не запускать `make kafka-reset`** на prod (полная потеря данных Kafka).
- **Не выполнять `make postgres-recreate-prep`** без свежего бэкапа и согласования.

---

## Связанные документы

- [docs/runbooks/disaster-recovery.md](./runbooks/disaster-recovery.md) — восстановление кластера на новом сервере.
- [docs/runbooks/usage-scenarios.md](./runbooks/usage-scenarios.md) — обычные сценарии эксплуатации.
- `<service>/BACKUP.md` — backup/restore детали.
- `README.md` — общая документация репозитория.
