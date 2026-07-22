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

## ⚠️ НЕ auto-unseal — восстановление после рестарта vault-0

Хранилище `file`, seal ручной. Если под `vault-0` перезапустится, он поднимется
**SEALED** → `ota-api` при старте не заберёт pubkey → api не стартует (старые поды
живут при rolling). Расшить:

```bash
kubectl -n vault exec vault-0 -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 \
  vault operator unseal $(kubectl -n vault get secret vault-unseal \
  -o jsonpath='{.data.unseal_key}' | base64 -d)"
```

## Device-CA (mTLS) — тоже вне helm, ссылка по имени

Секрет `ota/ota-device-ca` (ключ `ca.crt`, **ECDSA P-256** CA — ⚠ Ed25519-CA
непарсим ESP32-mbedTLS, см. `ota-prod-vault-signing`) создаётся infra и лишь
**упоминается** чартом (`ingress.mtls.caSecretName=ota/ota-device-ca`). Материал CA —
вне git (session-local `pki/`). Клиентские серты устройств — EC P-256, `CN=<device_id>`,
подписаны этой CA; fingerprint = SHA-1(DER) hex lowercase = `registry.identity`.
