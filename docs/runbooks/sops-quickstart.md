# sops+age — быстрый старт

Краткий cheat-sheet. Полный runbook с деталями и troubleshooting — в [secrets-management.md](./secrets-management.md).

## Установка (один раз)

```bash
# Linux (~/.local/bin должен быть в PATH):
curl -L "https://github.com/getsops/sops/releases/download/v3.9.0/sops-v3.9.0.linux.amd64" \
  -o ~/.local/bin/sops && chmod +x ~/.local/bin/sops
curl -L "https://github.com/FiloSottile/age/releases/download/v1.2.0/age-v1.2.0-linux-amd64.tar.gz" \
  | tar -xz -C ~/.local/bin --strip-components=1 age/age age/age-keygen

# macOS:
brew install sops age
```

Проверка: `make tools-check` — sops/age должны быть OK.

## Свой age-ключ (один раз)

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
grep "public key" ~/.config/sops/age/keys.txt
# # public key: age1...
```

Public-ключ (`age1...`) **передайте админу проекта** — он добавит вас в `.sops.yaml`.

## Включить sops+age в проекте (один раз для проекта)

```bash
cp apps/conf/_example/.sops.yaml.example .sops.yaml
$EDITOR .sops.yaml
# подставить age public-ключи всех админов через запятую
git add .sops.yaml && git commit -m "secrets: enable sops+age"
```

## Зашифровать секреты приложения

```bash
# 1. Создать/отредактировать plain-файл (gitignored):
$EDITOR apps/conf/myapp/secrets.yaml

# 2. Зашифровать → secrets.enc.yaml (коммитится в git):
make apps-conf-encrypt APP=myapp

# 3. Закоммитить:
git add apps/conf/myapp/secrets.enc.yaml
git commit -m "myapp: encrypted secrets"

# 4. (Опц.) удалить plain — он gitignored, но переопределяет .enc.yaml в merge:
rm apps/conf/myapp/secrets.yaml
```

## Просмотреть/отредактировать существующий зашифрованный файл

```bash
# Через sops (без появления plain на диске; рекомендуется):
make apps-conf-edit APP=myapp

# Через расшифровку → редактирование → шифрование:
make apps-conf-decrypt APP=myapp
$EDITOR apps/conf/myapp/secrets.yaml
make apps-conf-encrypt APP=myapp
git add apps/conf/myapp/secrets.enc.yaml && git commit -m "myapp: rotate secrets"
```

## Применить (как обычно)

```bash
make apps-apply ENV=local              # apps-merge-config.sh сам расшифрует .enc.yaml
make apps-apply-diff ENV=local         # dry-run без изменений
```

## Добавить нового админа

```bash
# Существующий админ:
$EDITOR .sops.yaml                                                    # добавить age1... нового
find apps/conf -name '*.enc.yaml' -exec sops updatekeys -y {} \;     # перешифровать под новый ключ
git add .sops.yaml apps/conf/**/*.enc.yaml
git commit -m "secrets: add admin <name> to sops recipients"
```

После `git pull` новый админ может расшифровать своим private-ключом.

## Удалить админа (при увольнении)

```bash
$EDITOR .sops.yaml                                                    # убрать age1...
find apps/conf -name '*.enc.yaml' -exec sops updatekeys -y {} \;
# ⚠ Старые версии в git history остаются доступны удалённому админу.
# Поэтому **обязательно** также сменить сами пароли (apps-conf-edit + apps-apply).
```

## Troubleshooting (одной строкой)

| Проблема | Решение |
|---|---|
| `Failed to get the data key` | `chmod 600 ~/.config/sops/age/keys.txt`; ваш age-ключ должен быть в `.sops.yaml` |
| `apps-merge-config.sh: Не удалось расшифровать` | проверьте `sops --decrypt apps/conf/<APP>/secrets.enc.yaml` напрямую |
| `error loading config: no matching creation rules` | имя файла должно соответствовать `path_regex` в `.sops.yaml` (по умолчанию `*.enc.yaml`) |
| Plain `secrets.yaml` не обновляет merge | помните, что plain переопределяет `.enc.yaml` — удалите plain или обновите оба |

Полные сценарии и нюансы: [secrets-management.md](./secrets-management.md).
