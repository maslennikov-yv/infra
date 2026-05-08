---
name: k8s-port-expose-microk8s
description: >-
  Exposes arbitrary TCP ports on Kubernetes nodes via microk8s nginx ingress: DaemonSet hostPort bindings and the nginx-ingress-tcp-microk8s-conf ConfigMap mapping host ports to "namespace/service:port". Covers imperative patches (LAYER=tcp|hostport), config-driven apply from local YAML (make k8s-port-expose-apply), ordered add/remove workflows, kubectl patch risks, microk8s addon upgrades overwriting edits. Use when working with microk8s ingress TCP, hostPort propagation, MQTT or other TCP services behind nginx ingress, or k8s-port-expose rules in Makefile.
---

# k8s port expose (microk8s ingress TCP)

## Traffic path

Traffic hits the node's **`<hostIp>:HOST_PORT`** (bound by **`hostPort`** on the ingress controller pod). The controller reads **`ConfigMap/nginx-ingress-tcp-microk8s-conf`** in **`ingress`**; each **`data`** key is a host port number, value is **`"<namespace>/<service>:<svcPort>"`**. The cluster routes to the referenced **Service**.

Example: **`1883: "hmq2/hmq:1883"`**.

## Repo commands

Uses the same **`KUBECONFIG`** convention as the rest of the repo (`ENV`, `kubeconfig-fetch`, `environments/$(ENV).mk`). See the root **`Makefile`** in the repository root.

| Make target | Purpose |
|-------------|---------|
| **`make k8s-port-expose-show ENV=<env>`** | Dump **`DaemonSet/nginx-ingress-microk8s-controller`** and **`ConfigMap/nginx-ingress-tcp-microk8s-conf`** in namespace **`ingress`**. |
| **`make k8s-port-expose-patch ENV=<env> LAYER=tcp …`** | **ConfigMap**: upsert **`HOST_PORT`** + **`BACKEND=ns/svc:port`**, or remove with **`HOST_PORT`** + **`RM=1`**. |
| **`make k8s-port-expose-patch ENV=<env> LAYER=hostport …`** | **DaemonSet**: **`OP=add`** with **`HOST_PORT`**, **`CONTAINER_PORT`**, **`PORT_NAME`**, **`PROTO`** (default **`TCP`**), or **`OP=rm`** with **`HOST_PORT`** (match by **`hostPort`**). |
| **`make k8s-port-expose-apply ENV=<env>`** | Локальный YAML **`k8s-port-expose/ports-<env>.yaml`** (или **`PORT_EXPOSE_CONFIG=/path/file.yaml`**): для каждого элемента **`exposes`** сначала **`hostPort`** в DaemonSet (пропуск, если уже есть), затем запись в TCP ConfigMap. **Не удаляет** порты, которых нет в файле — только доброс до желаемого состояния по списку. |

Overrides (non-default cluster layout): **`INGRESS_NS`**, **`INGRESS_DS`**, **`INGRESS_TCP_CM`**, **`INGRESS_CONTAINER`** (CLI/make или необязательные поля в том же YAML).

Internals live in **`k8s-port-expose/Makefile`**; **`patch`** depends on **`kubectl`** and **`jq`**. **`apply-config`** дополнительно проверяет **mikefarah/yq** (**`scripts/apps-yq-probe.sh`**); формат полей см. **`k8s-port-expose/ports.example.yaml`** и **`scripts/k8s-port-expose-apply-config.sh`**.

## Validation (make)

- **`HOST_PORT`** / **`CONTAINER_PORT`**: целое число **1–65535** (`tonumber` в jq).
- **`BACKEND`** (только upsert TCP): форма **`ns/svc:port`**, один **`/`** до имени сервиса, один **`:`** перед портом; порт сервиса тоже в диапазоне **1–65535** (строгое имя DNS в кластере не проверяется — это остаётся на apiserver).
- **`PROTO`**: только **`TCP`**, **`UDP`**, **`SCTP`**.
- **`OP=add`**: запрет, если у выбранного контейнера уже есть тот же **`hostPort`** или то же имя **`PORT_NAME`**.

## Dry-run

Переменная **`DRY_RUN=client`** или **`DRY_RUN=server`** передаётся в **`kubectl patch --dry-run=…`**: изменения не сохраняются; **`server`** прогоняет admission на API. С корня: **`make k8s-port-expose-patch … DRY_RUN=client`** или **`make k8s-port-expose-apply … DRY_RUN=client`** (dry-run на каждый патч в цикле).

## Typical order

- **Opening a new TCP port**: if **`hostPort`** for that numeric port does not yet exist on **`nginx-ingress-microk8s-controller`**, **`LAYER=hostport OP=add`** first; then **`LAYER=tcp`** with **BACKEND** pointing at your Service/port.
- **Removing**: often remove the **ConfigMap** entry first (**`RM=1`**), then remove **hostPort** from the DaemonSet (**`OP=rm`**) if nothing else should serve that host port.

## Checks

Confirm **Service name and namespace** match **BACKEND**; **`kubectl get svc -n <ns>`**. Ensure the host port does not collide on the node. After **DaemonSet** patches, ingress controller Pods roll and connections may flap briefly.

## Risks

- **microk8s** ingress addon upgrades may replace manifests — keep backups (**`kubectl get -o yaml`**) for customised resources.
- **JSON Patch remove** fails if the path is missing — inspect **`k8s-port-expose-show`** output when debugging.
