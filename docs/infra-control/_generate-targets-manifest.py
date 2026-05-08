#!/usr/bin/env python3
"""Emit docs/infra-control/targets.json (run from repo root)."""

from __future__ import annotations

import json
import re
import sys


EXTRA = (
    "postgres-backup postgres-restore postgres-delete-pvcs postgres-recreate-prep pg-app-verify"
).split()

EXCLUDED_PHONY = frozenset(["help", "infra-lab", "infra-control-parity-check"])

SIGINT_TARGETS = frozenset(
    """
    postgres-logs redis-logs kafka-logs minio-logs clickhouse-logs rabbitmq-logs monitoring-logs
    monitoring-port-forward
    """.split()
)


def dangerous(t: str) -> bool:
    if t in {"microk8s-uninstall", "kafka-reset", "postgres-restore"}:
        return True
    if t.endswith("-down") or "-drop" in t:
        return True
    if t in {"postgres-delete-pvcs", "postgres-recreate-prep"}:
        return True
    return False


# Синхронизировать с `scripts/infra-control/run.mjs` (NAV.TASK / NAV.OBJECT).
T_BOOT = "Бутстрап"
T_CFG = "Конфигурирование"
T_MGMT = "Управление"
O_ENV = "Среда"
O_SVC = "Сервис"
O_APP = "Приложение"


def p(task: str, obj: str, *rest: str) -> list[str]:
    return [task, obj, *rest]


def menu_path(make_target: str) -> list[str]:
    t = make_target

    if t == "env-new":
        return p(T_BOOT, O_ENV, "Окружения", t)
    if t == "env-backup":
        return p(T_MGMT, O_ENV, "Окружения", t)

    cluster = {
        "status",
        "top-totals",
        "kubeconfig-fetch",
        "kubeconfig-microk8s-local",
        "kubeconfig-info",
        "microk8s-setup",
        "microk8s-uninstall",
        "ssh",
    }
    if t in cluster:
        return p(T_MGMT, O_ENV, "Кластер и доступ", t)

    if t in {"up", "diff", "down"}:
        return p(T_MGMT, O_ENV, "Helm / релизы", t)

    helm_one = re.match(
        r"^(postgres|redis|kafka|minio|clickhouse|rabbitmq|monitoring)-(up|diff|down)$", t
    )
    if helm_one:
        return p(T_MGMT, O_SVC, "Helm / релизы", "Поштучно", helm_one.group(1), t)

    if t.startswith("images-"):
        return p(T_MGMT, O_ENV, "Образы", t)

    if t == "apps-merge-print":
        return p(T_CFG, O_APP, "Приложения и registry", t)
    if t == "apps-local-src-helm-sets":
        return p(T_CFG, O_APP, "Приложения и registry", t)
    if t == "apps-apply":
        return p(T_MGMT, O_APP, "Приложения и registry", t)
    if t in {"apps-conf-template", "apps-src-clone"}:
        return p(T_BOOT, O_APP, "Приложения и registry", t)
    if t == "app-local-src-hostpath-mount":
        return p(T_MGMT, O_APP, "Локально (MicroK8s)", t)

    if t.endswith("-verify") or t == "check-updates" or t.endswith("-check-updates"):
        return p(T_MGMT, O_SVC, "Проверки и обновления", t)

    pg_accounts = {
        "pg-app-create",
        "pg-app-show-creds",
        "pg-app-psql",
        "pg-app-drop",
        "pg-app-verify",
        "postgres-db",
    }
    if t in pg_accounts:
        return p(T_MGMT, O_APP, "Учётки приложений", "PostgreSQL", t)

    if t.startswith("redis-app-"):
        return p(T_MGMT, O_APP, "Учётки приложений", "Redis", t)

    kafka_accounts = {"kafka-app-create", "kafka-app-show-creds", "kafka-app-drop"}
    if t in kafka_accounts:
        return p(T_MGMT, O_APP, "Учётки приложений", "Kafka (учётки)", t)

    if t.startswith("minio-app"):
        return p(T_MGMT, O_APP, "Учётки приложений", "MinIO", t)

    if t.startswith("clickhouse-app-"):
        return p(T_MGMT, O_APP, "Учётки приложений", "ClickHouse", t)

    if t.startswith("rabbitmq-app-"):
        return p(T_MGMT, O_APP, "Учётки приложений", "RabbitMQ", t)

    if t == "kafka-bootstrap":
        return p(T_BOOT, O_SVC, "Kafka (кластер и топики)", t)
    if t == "kafka-reset":
        return p(T_MGMT, O_SVC, "Kafka (кластер и топики)", t)

    if t == "kafka-topic-create":
        return p(T_MGMT, O_APP, "Kafka (кластер и топики)", t)
    if t.startswith("kafka-topic-"):
        return p(T_MGMT, O_SVC, "Kafka (кластер и топики)", t)

    if t.startswith("k8s-port-expose-"):
        return p(T_CFG, O_ENV, "Сеть — TCP ingress", t)

    mongo = re.match(r"^monitoring-(.+)$", t)
    if mongo:
        return p(T_MGMT, O_SVC, "Диагностика и данные", "Monitoring (netdata)", t)

    svc_diag = (
        "postgres-backup postgres-restore postgres-delete-pvcs postgres-recreate-prep "
        "postgres-status postgres-logs postgres-shell"
    ).split()

    if t in svc_diag:
        return p(T_MGMT, O_SVC, "Диагностика и данные", "PostgreSQL", "Данные и доступ", t)

    for prefix, segs in [
        ("postgres-", ("PostgreSQL",)),
        ("redis-", ("Redis",)),
        ("kafka-status", ("Kafka",)),
        ("kafka-logs", ("Kafka",)),
        ("kafka-shell", ("Kafka",)),
        ("minio-", ("MinIO",)),
        ("clickhouse-", ("ClickHouse",)),
        ("rabbitmq-", ("RabbitMQ",)),
    ]:
        if prefix.endswith("-") and t.startswith(prefix):
            label = segs[0]
            tail = t[len(prefix) :]
            if tail:
                return p(T_MGMT, O_SVC, "Диагностика и данные", label, t)
            break

    for label, prefixes in (
        ("PostgreSQL", ("postgres-",)),
        ("Redis", ("redis-",)),
        ("Kafka", ("kafka-",)),
        ("MinIO", ("minio-",)),
        ("ClickHouse", ("clickhouse-",)),
        ("RabbitMQ", ("rabbitmq-",)),
    ):
        if t.startswith(prefixes[0]) and not t.startswith("kafka-topic") and not t.startswith("kafka-app"):
            return p(T_MGMT, O_SVC, "Диагностика и данные", label, t)

    raise ValueError(f"no menu mapping for {t!r}")


def parse_phony(path: str) -> list[str]:
    lines = open(path, encoding="utf8").read().splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith(".PHONY:"):
            block = []
            j = i
            while True:
                block.append(lines[j])
                if not lines[j].rstrip().endswith("\\"):
                    break
                j += 1
            merged = " ".join(block)
            blob = merged.split(":", 1)[1]
            return [x.strip() for x in re.split(r"[\s\\]+", blob) if x.strip()]
            excluded = {"help", "infra-lab", "infra-control-parity-check"}
            return [n for n in names if n not in excluded]
        i += 1
    raise RuntimeError(".PHONY not found")


def main() -> None:
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    makefile = f"{root}/Makefile"
    out_path = f"{root}/docs/infra-control/targets.json"

    phony = [n for n in parse_phony(makefile) if n not in EXCLUDED_PHONY]
    all_targets = sorted(set(phony).union(EXTRA))
    failures: list[str] = []
    manifest = []

    makefile_full = open(makefile, encoding="utf8").read()
    mf_lines = makefile_full.splitlines()

    defined = {}
    pattern = re.compile(r"^([\w.-]+):")

    def has_recipe(token: str) -> bool:
        for ln in mf_lines:
            m = pattern.match(ln.strip())
            if m and m.group(1) == token:
                return True
        return False

    for t in sorted(all_targets):
        try:
            path = menu_path(t)
        except ValueError:
            failures.append(t)
            path = ["UNMAPPED", t]
        if not failures or path[0] != "UNMAPPED":
            manifest.append(
                {
                    "id": t,
                    "makeTarget": t,
                    "menuPath": path,
                    "dangerous": dangerous(t),
                    "sigint": t in SIGINT_TARGETS,
                }
            )

    with open(out_path, "w", encoding="utf8") as fh:
        json.dump({"version": 1, "targets": manifest}, fh, indent=2, ensure_ascii=False)
        fh.write("\n")

    for t in sorted(all_targets):
        if not has_recipe(t):
            print(f"warn: makefile has no rule line for {t}", file=sys.stderr)

    if failures:
        raise SystemExit(f"unmapped: {failures}")

    print(f"wrote {out_path} ({len(manifest)} targets)")


if __name__ == "__main__":
    main()
