# Шифрование `apps/conf/` через sops + age

Документ описывает **опциональный** workflow для хранения секретов приложений (`apps/conf/<APP>/secrets.enc.yaml`) в git в зашифрованном виде. Стандартный workflow с нешифрованными `secrets.yaml` (gitignored) продолжает работать без изменений — sops+age включается на проектах, где удобнее иметь секреты под контролем версий.

> 💡 Если нужны только команды без объяснений — см. **[sops-quickstart.md](./sops-quickstart.md)** (cheat-sheet).

## Зачем sops+age

| Альтернатива | Плюсы | Минусы |
|---|---|---|
| **`secrets.yaml` (текущий стандарт, gitignored)** | Простота, никакой инфраструктуры | Передача между админами вручную; легко забыть; нет истории |
| **sops+age (этот документ)** | Зашифрованные `secrets.enc.yaml` в git, история, можно дать доступ нескольким админам, нет внешних серверов | Нужны sops + age на каждой машине; нужна процедура ротации ключей при смене состава команды |
| **sealed-secrets (k8s controller)** | k8s-native, автоматический deploy | Требует controller в кластере; не подходит для секретов вне k8s (`apps/conf/`) |
| **vault / external secrets** | Полнофункциональный менеджер, динамические креды | Тяжёлая инфраструктура; для текущего масштаба избыточно |

**sops+age** — лучший компромисс для этого репозитория: один файл `.sops.yaml` в корне, ключи у каждого админа в `~/.config/sops/age/keys.txt`, шифрование без онлайн-сервисов.

## Принцип

- **age** генерирует пары приватный/публичный ключ (формат `age1...` для public, `AGE-SECRET-KEY-1...` для private).
- **`.sops.yaml`** в корне репо описывает: для пути `apps/conf/.*\.enc\.yaml$` шифровать **под все public-ключи** перечисленных админов (multi-recipient).
- Каждый админ может расшифровать своим private-ключом.
- При добавлении/удалении админа — ротация: обновить `.sops.yaml` + `sops updatekeys` для каждого `*.enc.yaml`.

## Установка

### sops

```bash
# Linux x86_64:
SOPS_VERSION=v3.9.0
curl -L "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64" \
  -o ~/.local/bin/sops && chmod +x ~/.local/bin/sops

# macOS:
brew install sops
```

### age

```bash
# Linux:
AGE_VERSION=v1.2.0
curl -L "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz" \
  | tar -xz -C ~/.local/bin --strip-components=1 age/age age/age-keygen

# macOS:
brew install age
```

Проверка:
```bash
make tools-check          # sops, age — опциональные, помечены OK при наличии
sops --version
age --version
```

## Первоначальная настройка (один раз для проекта)

### 1. Каждый админ генерирует пару ключей

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
# Файл содержит:
#   # created: 2026-05-08T10:00:00Z
#   # public key: age1abc...xyz
#   AGE-SECRET-KEY-1...
# Public key выводится в stderr и в файл — его можно показать всем.
```

Public-ключ можно прочитать обратно:
```bash
grep "public key" ~/.config/sops/age/keys.txt
# # public key: age1abc...xyz
```

### 2. Создать `.sops.yaml` в корне репо

```bash
cp apps/conf/_example/.sops.yaml.example .sops.yaml
$EDITOR .sops.yaml
```

Подставить **public-ключи всех админов** через запятую:
```yaml
creation_rules:
  - path_regex: apps/conf/.*\.enc\.ya?ml$
    encrypted_regex: '^(.*)$'
    age: >-
      age1adminAlice...,
      age1adminBob...,
      age1adminCarol...
```

`.sops.yaml` коммитится в git — это публичная конфигурация.

### 3. Зашифровать существующие `apps/conf/<APP>/secrets.yaml`

```bash
# Для каждого приложения с локальным secrets.yaml:
make apps-conf-encrypt APP=myapp
# → apps/conf/myapp/secrets.enc.yaml (зашифрованный, добавляется в git)
# Локальный secrets.yaml остаётся (gitignored). Он переопределяет .enc.yaml при apps-merge-print —
# удобно для локальной разработки. Если удалить — будет использоваться только .enc.yaml.

# Закоммитьте:
git add .sops.yaml apps/conf/<APP>/secrets.enc.yaml
git commit -m "secrets: enable sops+age, encrypt apps/conf/<APP>"
```

## Ежедневный workflow

### Просмотреть/отредактировать секреты

**Через sops (рекомендуется — без появления plain-файла на диске):**
```bash
make apps-conf-edit APP=myapp
# Открывает $EDITOR с расшифрованным содержимым; при сохранении — шифрует обратно.
# Поддерживает diff-мерж.
```

**Через decrypt → edit → encrypt** (если хотите видеть `secrets.yaml` локально):
```bash
make apps-conf-decrypt APP=myapp                 # → apps/conf/myapp/secrets.yaml (gitignored, chmod 600)
$EDITOR apps/conf/myapp/secrets.yaml
make apps-conf-encrypt APP=myapp                 # → apps/conf/myapp/secrets.enc.yaml
git add apps/conf/myapp/secrets.enc.yaml && git commit -m "..."
```

⚠️ Локальный `secrets.yaml` **переопределяет** `secrets.enc.yaml` в `apps-merge-config.sh`. Это by design (override для разработки). Удалите локальный `secrets.yaml` после `apps-conf-encrypt`, если хотите убедиться, что в `apps-apply` пойдёт ровно содержимое `.enc.yaml`.

### Применить секреты (`make apps-apply`)

Без изменений: `apps-merge-config.sh` теперь автоматически расшифровывает любые `*.enc.yaml`/`*.enc.yml` в `apps/conf/<APP>/` через sops перед deep-merge. Если sops не установлен и встречается `*.enc.yaml` — скрипт упадёт с явной ошибкой.

```bash
make apps-apply ENV=local                        # как обычно
make apps-apply-diff ENV=local                   # dry-run
```

### Просмотреть итоговый merge (для отладки)

```bash
make apps-merge-print                            # выводит plain merged YAML (с расшифрованными секретами!)
```

⚠️ `apps-merge-print` возвращает plain-секреты в stdout. Не пишите в публичные логи.

## Ротация ключей

### Добавление нового админа

1. Новый админ генерирует свой age-ключ (см. выше) и присылает **public-key**.
2. Существующий админ обновляет `.sops.yaml`, добавляя новый public-ключ в `age:`.
3. Существующий админ перешифровывает все `*.enc.yaml`:
   ```bash
   find apps/conf -name '*.enc.yaml' -exec sops updatekeys -y {} \;
   ```
4. Коммит:
   ```bash
   git add .sops.yaml apps/conf/**/*.enc.yaml
   git commit -m "secrets: add admin Alice to sops recipients"
   ```
5. Новый админ после `git pull` может расшифровать своим ключом.

### Удаление админа (увольнение)

То же что добавление, только удалить public-ключ из `.sops.yaml` и `sops updatekeys`. **После этого** удалённый админ:
- Не может расшифровать новые версии файлов.
- **Может** расшифровать старые версии (которые были зашифрованы до ротации) — git history содержит их.
- Поэтому **обязательно** ротировать сами секреты (поменять пароли в БД, в `apps/conf/<APP>/secrets.yaml`, перешифровать) после ротации ключей.

```bash
# Полная процедура смены состава команды:
# 1. Обновить .sops.yaml — убрать old admin
$EDITOR .sops.yaml
# 2. Обновить ключи в существующих файлах
find apps/conf -name '*.enc.yaml' -exec sops updatekeys -y {} \;
# 3. Сменить пароли в БД (через make pg-app-create заново или вручную)
# 4. Обновить *.enc.yaml с новыми паролями
make apps-conf-edit APP=<each>
# 5. apps-apply, чтобы новые пароли попали в k8s Secret
make apps-apply ENV=<env>
# 6. Commit + push
```

### Потеря private-ключа

Если админ потерял `~/.config/sops/age/keys.txt` (и у него нет бэкапа):
- Его доступ к новым `*.enc.yaml` — потерян.
- Если он был **единственным** получателем — `*.enc.yaml` нечитаемы навсегда.
- Поэтому: **минимум 2 админа** в `.sops.yaml`, или храните backup-ключ в shared secure storage (yubikey, hsm, password manager).

## Troubleshooting

### `Failed to get the data key required to decrypt the SOPS file`

Причины:
- `~/.config/sops/age/keys.txt` отсутствует или не читается → проверить `chmod 600`, путь.
- Ваш age public-key не добавлен в `.sops.yaml` → попросите админа сделать `sops updatekeys`.
- Переменная `SOPS_AGE_KEY_FILE` указывает на другой файл (если задана).

### `apps-merge-config.sh: Не удалось расшифровать ...`

То же. Проверьте `sops --decrypt apps/conf/<APP>/secrets.enc.yaml` напрямую — увидите внятную ошибку.

### Локальный `secrets.yaml` переопределяет `secrets.enc.yaml`

By design. Если запустили `apps-conf-decrypt` для редактирования и забыли удалить — merge возьмёт plain. Удалите `apps/conf/<APP>/secrets.yaml`:

```bash
rm apps/conf/<APP>/secrets.yaml
make apps-merge-print | yq ".apps[] | select(.name == \"<APP>\")"   # проверка
```

### Изменилась версия sops/age и encrypted-файлы перестали читаться

Маловероятно (формат стабилен). Помогает: вернуть на старую версию sops, расшифровать, обновить sops, перешифровать.

## Совместимость с env-backup

`make env-backup` (Этап 3) копирует `apps/conf/` в архив **как есть**: и `secrets.enc.yaml`, и (если есть) plain `secrets.yaml`. Это **корректно**:
- На новом сервере при `env-restore` восстанавливаются оба варианта.
- Если sops+age настроен — `apps-merge-config.sh` сам расшифрует `.enc.yaml`.
- Если новый сервер не имеет `~/.config/sops/age/keys.txt` для текущих ключей — `apps-apply` упадёт с явной ошибкой про sops; нужно перенести age-keys (вне env-backup-архива, отдельным каналом).

**Рекомендация для disaster recovery с sops+age**: храните age private-keys существующих админов **в нескольких независимых местах** (yubikey, password manager, encrypted USB).

## Связанные документы

- [docs/onboarding-admin.md](../onboarding-admin.md) — раздел про безопасные каналы передачи (sops+age — recommended, если настроен).
- [docs/runbooks/disaster-recovery.md](./disaster-recovery.md) — порядок восстановления; sops-decrypted secrets интегрируются автоматически.
- [apps/conf/_example/.sops.yaml.example](../../apps/conf/_example/.sops.yaml.example) — образец `.sops.yaml`.
- Sops upstream: https://github.com/getsops/sops
- Age upstream: https://github.com/FiloSottile/age
