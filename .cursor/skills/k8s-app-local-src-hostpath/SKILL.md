---
name: k8s-app-local-src-hostpath
description: >-
  Local/MicroK8s: hostPath каталога apps/src/<APP> в поды — Helm (app.volumes, make apps-local-src-helm-sets) или kubectl patch (app-local-src-hostpath-mount). Только ENV=local; runbook app-local-sources-helm.md и infra-lab.
---

# Локальный код в поды (hostPath, infra repo)

Предназначено для этого репозитория **`infra`** (`REPO_ROOT`, `Makefile`, `ENV`, `apps/registry.yaml`). Платформа (postgres/redis/…) живёт в **helmfile**; **чарт приложения** — во внешнем репо (кроме fallback-патча).

## Когда какой способ

| Подход | Когда |
|--------|--------|
| **Helm — предпочтительно** | В чарт приложения можно добавить условный `volume` / `volumeMount` и передать значения через `helm upgrade`. Никак не затирается следующим патчем. |
| **kubectl patch из infra — fallback** | Чарт приложения недоступен или менять долго; известны workload (`deployment`/`deploy`, `statefulset`/`sts`, `daemonset`/`ds`, `pod`) и namespace (`app_ns` из merge). |

## Способ A: Helm (`app.volumes.*`)

1. В чарт приложения: при **`.Values.app.volumes.enabled`** включать **`hostPath`** с **`.Values.app.volumes.hostPath`**, тип **`Directory`**; **`volumeMounts`** для нужных контейнеров (и при желании для **initContainers**).
2. В **values-local** приложения держите **`enabled: false`**, чтобы по умолчанию том не включался случайно.
3. Из **корня infra**: `make apps-local-src-helm-sets ENV=local APP=<name>` → на stdout строка **`--set app.volumes.enabled=true --set app.volumes.hostPath="<abs>"`** (абсолютный путь к **`apps/src/<APP>`**). Вставить в свой **`helm upgrade --install`**.
4. Если каталога **`apps/src/<APP>`** ещё нет, скрипт пишет предупреждение в stderr, но строку **`--set`** всё равно выводит. В самом чарте при типе **`Directory`** для **`hostPath`** каталог на ноде должен существовать до старта пода — иначе монтирование не будет работать как ожидается.

Образец values и текст шаблона: **[apps/conf/_example/helm-app-volumes-values.yaml](../../../apps/conf/_example/helm-app-volumes-values.yaml)** и **[docs/runbooks/app-local-sources-helm.md](../../../docs/runbooks/app-local-sources-helm.md)**.

**infra-lab** (сеанс **`ENV=local`**): **Конфигурирование → Приложение → Вывести helm --set для local hostPath**.

## Способ B: патч живого ресурса

Targets в корневом **`Makefile`** (см. **`help`**; переменные **`KUBECONFIG`** и **`ENV`** как для остального репозитория).

| Цель | Назначение |
|------|------------|
| **`make app-local-src-hostpath-mount ENV=local APP=<name>`** **`APP_LOCAL_K8S_WORKLOAD=<kind>/…`** — **`kind`**: **`deployment`**/`deploy`, **`statefulset`**/`sts`, **`daemonset`**/`ds`, **`pod`** | JSON Patch тома **`infra-apps-src-<app>`** + mount; патч использует **`DirectoryOrCreate`** на хосте. Переменные: **`APP_LOCAL_SRC_MOUNT_PATH`**; опционально **`APP_LOCAL_SRC_CONTAINER`** (если задан — маунт только в этот контейнер среди initContainers/containers, иначе во все); **`APP_LOCAL_SRC_READ_ONLY`**; опционально **`APP_NS`** / merge **`app_ns`**. |

Скрипты: **`scripts/app-local-src-hostpath-mount.sh`**, **`scripts/lib/app-local-src-hostpath-mount.py`**.

После патча возможен дрейф при **`helm upgrade`**, который не описывает тот же volume.

## Общие ограничения

- Работа ожидается при **`ENV=local`** однонодового **MicroK8s** на той же машине, где лежит путь **`apps/src/...`**; на других нодах **hostPath** — другая ФС.

- Клон в **`apps/src`**: **`make apps-src-clone APP=…`** (из **`repo_url`** в registry) или вручную.

## Быстрая связка имен

Реестр: **`apps/registry.yaml`** поле **`name`** = **`APP`**. Namespace приложения часто **`app_ns`** в merge (**`kubectl -n`**).
