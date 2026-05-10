---
name: k8s-port-expose-microk8s
description: >-
  Открытие/закрытие TCP-портов на ноде microk8s через nginx ingress controller:
  hostPort на DaemonSet и ConfigMap nginx-ingress-tcp-microk8s-conf (HOST_PORT →
  "ns/svc:port"). Покрывает императивные патчи (LAYER=tcp|hostport),
  config-driven apply из k8s-port-expose/ports-<env>.yaml, drift-detection,
  правильный порядок add/remove, риски kubectl patch и перезаписи аддоном
  microk8s. Использовать при работе с microk8s ingress TCP, MQTT/иными
  TCP-сервисами за nginx ingress, а также правилами k8s-port-expose в Makefile.
---

# k8s port expose (microk8s ingress TCP)

## Путь трафика

Трафик попадает в **`<hostIp>:HOST_PORT`** ноды (биндится через **`hostPort`** на поде ingress-контроллера). Контроллер читает **`ConfigMap/nginx-ingress-tcp-microk8s-conf`** в namespace **`ingress`**: каждый ключ в **`data`** — номер host-порта, значение — **`"<namespace>/<service>:<svcPort>"`**. Кластер маршрутизирует на указанный **Service**.

Пример: **`1883: "hmq2/hmq:1883"`**.

## Команды репозитория

Используется тот же **`KUBECONFIG`**-конвейер, что и везде (`ENV`, `kubeconfig-fetch`, `environments/$(ENV).mk`). См. корневой **`Makefile`**.

| Make target | Назначение |
|-------------|------------|
| **`make k8s-port-expose-show ENV=<env>`** | Дамп **`DaemonSet/nginx-ingress-microk8s-controller`** и **`ConfigMap/nginx-ingress-tcp-microk8s-conf`** в namespace **`ingress`**. |
| **`make k8s-port-expose-patch ENV=<env> LAYER=tcp …`** | **ConfigMap**: upsert **`HOST_PORT`** + **`BACKEND=ns/svc:port`**, либо удаление **`HOST_PORT`** + **`RM=1`**. |
| **`make k8s-port-expose-patch ENV=<env> LAYER=hostport …`** | **DaemonSet**: **`OP=add`** с **`HOST_PORT`**, **`CONTAINER_PORT`**, **`PORT_NAME`**, **`PROTO`** (по умолчанию **`TCP`**), либо **`OP=rm`** с **`HOST_PORT`** (удаление по совпадению **`hostPort`**). |
| **`make k8s-port-expose-apply ENV=<env>`** | Локальный YAML **`k8s-port-expose/ports-<env>.yaml`** (либо **`PORT_EXPOSE_CONFIG=/path/file.yaml`**): для каждого элемента **`exposes`** сначала **`hostPort`** в DaemonSet (пропуск, если уже есть), затем запись в TCP ConfigMap. **Не удаляет** порты, отсутствующие в файле — только доводит до состояния по списку. |
| **`make k8s-port-expose-diff ENV=<env>`** | Drift-detection: дельта между **`ports-<env>.yaml`** и живыми DaemonSet + ConfigMap. Ничего не меняет. |

Override полей кластера (нестандартный layout): **`INGRESS_NS`**, **`INGRESS_DS`**, **`INGRESS_TCP_CM`**, **`INGRESS_CONTAINER`** — через CLI/make или соответствующие необязательные поля в YAML.

Реализация — в **`k8s-port-expose/Makefile`**; **`patch`** требует **`kubectl`** и **`jq`**. **`apply-config`** дополнительно проверяет **mikefarah/yq** (через **`scripts/apps-yq-probe.sh`**); формат полей — **`k8s-port-expose/ports.example.yaml`** и **`scripts/k8s-port-expose-apply-config.sh`**.

## Валидация (make)

- **`HOST_PORT`** / **`CONTAINER_PORT`**: целое **1–65535** (`tonumber` в jq).
- **`BACKEND`** (только upsert TCP): форма **`ns/svc:port`** — один **`/`** до имени сервиса, один **`:`** перед портом; порт сервиса тоже **1–65535** (DNS-имя в кластере не проверяется — это на стороне apiserver).
- **`PROTO`**: **`TCP`** | **`UDP`** | **`SCTP`**.
- **`OP=add`**: запрет, если у выбранного контейнера уже есть тот же **`hostPort`** или такое же имя **`PORT_NAME`**.

## Dry-run

**`DRY_RUN=client`** или **`DRY_RUN=server`** пробрасывается в **`kubectl patch --dry-run=…`**: изменения не сохраняются; **`server`** прогоняет admission на API. С корня: **`make k8s-port-expose-patch … DRY_RUN=client`** или **`make k8s-port-expose-apply … DRY_RUN=client`** (dry-run на каждый патч в цикле).

## Порядок действий

- **Открытие нового TCP-порта:** если соответствующий **`hostPort`** ещё не объявлен на **`nginx-ingress-microk8s-controller`** — сначала **`LAYER=hostport OP=add`**, затем **`LAYER=tcp`** с **`BACKEND`** на ваш Service/port.
- **Удаление:** обычно сначала запись из **ConfigMap** (**`RM=1`**), потом **`hostPort`** из DaemonSet (**`OP=rm`**), если ничего другого больше не должно слушать тот же host-порт.

## Проверки

Сверить **имя Service и namespace** с **`BACKEND`**: **`kubectl get svc -n <ns>`**. Убедиться, что host-порт не конфликтует на ноде. После патчей **DaemonSet** поды контроллера перезапускаются — соединения могут кратковременно прерваться.

## Риски

- Обновление аддона **microk8s ingress** может перезаписать манифесты — храните бэкапы (**`kubectl get -o yaml`**) для кастомизированных ресурсов.
- **JSON Patch remove** падает, если path не существует — при отладке смотрите вывод **`k8s-port-expose-show`**.
