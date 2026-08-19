# Vault (single-node Transit) — подпись OTA-артефактов

Одно-узловой HashiCorp Vault, обслуживающий **только** движок **Transit** для подписи
манифестов OTA-сервиса (`rh/ota`, ns `ota`, `appEnv=production`). Ключ подписи
`ota-signing` (Ed25519) — его публичная половина **запечена в прошивку всего флота**
(`main/ota_trust_anchor.c`, анкор `ota-signing`), поэтому потеря приватного ключа =
флот больше не примет ни одного подписанного обновления.

## ⚠️ Развёрнут вне helmfile — НАМЕРЕННО

Эти манифесты применяются **напрямую `kubectl apply`**, а не через helmfile/helm.
Причина: StatefulSet держит **единственную копию** keyring'а Transit на 1Gi PVC
(`data-vault-0`). Если Vault попадёт под helm/helmfile-управление, любой
`helm upgrade`/`uninstall`, пересоздающий StatefulSet или PVC, **сотрёт ключ
`ota-signing`** → каждое устройство с запечённым анкором окажется неспособно
обновиться. **Не добавлять в `helmfile.yaml.gotmpl`. Не трогать PVC `data-vault-0`.**

```bash
kubectl apply -f vault/namespace.yaml
kubectl apply -f vault/vault.yaml
```

## Инициализация (однократно, уже сделано в prod)

```bash
kubectl -n vault exec vault-0 -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 \
  vault operator init -key-shares=1 -key-threshold=1'
# → сохранить Unseal Key + Root Token в secret vault/vault-unseal
kubectl -n vault create secret generic vault-unseal \
  --from-literal=unseal_key=<UNSEAL> --from-literal=root_token=<ROOT>
```

Затем (с `VAULT_TOKEN=<root>`): включить движок и создать ключ/политику/токен:

```bash
vault secrets enable transit
vault write -f transit/keys/ota-signing type=ed25519
# политика ota-api: update на transit/sign/ota-signing, read на transit/keys/ota-signing
vault policy write ota-api - <<'HCL'
path "transit/sign/ota-signing"  { capabilities = ["update"] }
path "transit/keys/ota-signing"  { capabilities = ["read"]   }
HCL
# periodic-токен (720h) для ota-api → в APP_SECRETS api.signing.vaultToken
vault token create -policy=ota-api -period=720h -orphan
```

Публичный анкор (для сверки с запечённым в прошивку):
`vault read -field=keys transit/keys/ota-signing` → `public_key` (base64-std, 32 сырых
байта). Должен равняться `dOec4ywsQfPfg6Za5Lh0ohBSeqxBpnz46xb9KJe8r8Q=`.

## Auto-unseal (есть, с 2026-08-19) и что делать, если он не сработал

Хранилище `file`, seal шамировский, штатного auto-unseal у одноузлового Vault нет —
после **любого** рестарта пода (рестарт узла, смена образа, eviction) он поднимается
**SEALED**. Цена этого: `ota-api` забирает pubkey `ota-signing` на старте и без него
падает целиком. 2026-08-19 узел перезагрузился в 03:58 UTC, и `ota.rocket-home.ru`
отдавал 503 пять часов, пока это не заметили руками.

Поэтому распечатывание автоматизировано — `vault/unseal-cronjob.yaml`:

```bash
kubectl apply -f vault/vault-headless.yaml
kubectl apply -f vault/unseal-cronjob.yaml
```

CronJob `vault-unseal` раз в 2 минуты проверяет `vault status` и распечатывает Vault,
если тот запечатан. Проверено живьём: `kubectl -n vault delete pod vault-0` → под
поднимается SEALED/NotReady → через **37 секунд** он распечатан и Ready, без человека.

Три вещи, которые в этой связке неочевидны и которые нельзя «упростить»:

- **`vault-headless`** (`publishNotReadyAddresses: true`) существует именно потому, что
  `readinessProbe` теперь честная: запечатанный Vault выпадает из эндпоинтов обычного
  сервиса `vault` ровно тогда, когда его надо распечатать. CronJob ходит через headless.
- **`vault operator unseal -` не читает stdin** — CLI знает только `[KEY]` аргументом
  или интерактивный промпт, а литеральный `-` уезжает как ключ и ловит
  `400 'key' must be a valid hex or base64 string`. Поэтому задача зовёт
  `vault write sys/unseal key=@/tmp/k`: значение читается из файла, ключ не попадает
  ни в argv, ни в `ps`, ни в описание Job.
- **У задачи нет доступа к API кластера** (`automountServiceAccountToken: false`):
  ключ подмонтирован файлом из Secret `vault-unseal`, а не читается через API, поэтому
  ServiceAccount/Role/RoleBinding не нужны вовсе.

Автоматика **не ослабляет** защиту: unseal-ключ и так лежит Secret'ом в том же кластере,
что и сам Vault — кто дотянулся до одного, дотянулся и до второго. Seal здесь защищает
от кражи диска или бэкапа PVC, и это свойство сохраняется. Реальная граница — RBAC на
namespace `vault`.

**`vault-0` в состоянии `0/1` теперь читается однозначно: «запечатан».** Проба —
`/v1/sys/health?standbyok=true&sealedcode=503`. Если под висит `0/1` дольше пары минут,
смотреть логи задачи:

```bash
kubectl -n vault get jobs
kubectl -n vault logs -l job-name --tail=20 --prefix
```

Аварийный ручной путь (если задача не отработала):

```bash
kubectl -n vault exec vault-0 -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 \
  vault operator unseal $(kubectl -n vault get secret vault-unseal \
  -o jsonpath='{.data.unseal_key}' | base64 -d)"
```

После распечатывания `ota-api` выходит из CrashLoopBackOff сам (backoff до 5 мин);
ускорить — `kubectl -n ota rollout restart deploy/ota-api`.

## ⚠️ Единственная копия ключей

`unseal_key` и `root_token` живут в Secret `vault/vault-unseal`, офлайн-копия —
в `~/back/ota/` на машине владельца (рядом с PKI device-контура). Обе нужны: в PVC
`data-vault-0` лежит **единственная** копия приватного ключа `ota-signing`, публичная
половина которого запечена во всю прошивку флота. Потеря кластера без офлайн-копии
не восстанавливается — флот перестанет принимать обновления навсегда.

## Device-CA (mTLS) — тоже вне helm, ссылка по имени

Секрет `ota/ota-device-ca` (ключ `ca.crt`, **ECDSA P-256** CA — ⚠ Ed25519-CA
непарсим ESP32-mbedTLS, см. `ota-prod-vault-signing`) создаётся infra и лишь
**упоминается** чартом (`ingress.mtls.caSecretName=ota/ota-device-ca`). Материал CA —
вне git (session-local `pki/`). Клиентские серты устройств — EC P-256, `CN=<device_id>`,
подписаны этой CA; fingerprint = SHA-1(DER) hex lowercase = `registry.identity`.
