#!/usr/bin/env python3
"""
JSON Patch для hostPath (apps/src/<APP>) в Pod или в pod template workloads:
Deployment / StatefulSet / DaemonSet / Pod.

Читает настройку из переменных окружения (см. scripts/app-local-src-hostpath-mount.sh).
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys


def dns_subdomain_label(s: str) -> str:
    s = s.lower().replace("_", "-")
    s = re.sub(r"[^a-z0-9-]", "-", s)
    s = re.sub(r"-+", "-", s).strip("-")
    if not s:
        return "app"
    if not ("a" <= s[0] <= "z"):
        s = "app-" + s
    return s


def workload_kind_short(kind: str) -> str:
    k = kind.lower().replace(".apps", "").replace(".core", "").strip()
    if k in ("deploy", "deployment", "deployments"):
        return "deployment"
    if k in ("sts", "statefulset", "statefulsets"):
        return "statefulset"
    if k in ("ds", "daemonset", "daemonsets"):
        return "daemonset"
    if k in ("po", "pod", "pods"):
        return "pod"
    raise SystemExit(
        f"✗ неподдерживаемый kind workload: {kind!r} "
        "(deployment|statefulset|daemonset|pod)"
    )


def env_truthy(key: str) -> bool:
    return os.environ.get(key, "").strip().lower() in ("1", "true", "yes", "on")


def kubectl_get_json(kind: str, name: str, namespace: str) -> dict:
    try:
        proc = subprocess.run(
            ["kubectl", "get", kind, name, "-n", namespace, "-o", "json"],
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        print("✗ kubectl не найден в PATH", file=sys.stderr)
        raise SystemExit(1) from None
    if proc.returncode != 0:
        print(
            f"✗ kubectl get {kind}/{name} -n {namespace} (код {proc.returncode})",
            file=sys.stderr,
        )
        err = (proc.stderr or "").strip()
        if err:
            print(err, file=sys.stderr)
        raise SystemExit(1)
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        print(f"✗ ответ kubectl не JSON: {e}", file=sys.stderr)
        raise SystemExit(1) from e


def pod_spec_and_json_prefix(kind: str, obj: dict) -> tuple[dict, str]:
    """Возвращает (podSpec, json_pointer_prefix для patch)."""
    if kind == "pod":
        spec = obj.setdefault("spec", {})
        return spec, "/spec"
    spec = obj.setdefault("spec", {}).setdefault("template", {}).setdefault("spec", {})
    return spec, "/spec/template/spec"


def collect_container_names(template: dict) -> list[str]:
    names: list[str] = []
    for key in ("initContainers", "containers"):
        for c in template.get(key) or []:
            if isinstance(c, dict):
                n = c.get("name")
                if n:
                    names.append(str(n))
    return names


def volume_mount_value(vol_name: str, mount_path: str, read_only: bool) -> dict:
    vm: dict = {"name": vol_name, "mountPath": mount_path}
    if read_only:
        vm["readOnly"] = True
    return vm


def append_volume_mount_patches(
    patches: list[dict],
    template: dict,
    array_key: str,
    json_prefix: str,
    container_filter: str,
    vol_name: str,
    mount_value: dict,
) -> None:
    items = template.get(array_key) or []
    for i, c in enumerate(items):
        if not isinstance(c, dict):
            continue
        cname = c.get("name") or ""
        if container_filter and cname != container_filter:
            continue

        mounts = c.get("volumeMounts")
        base = f"{json_prefix}/{array_key}/{i}/volumeMounts"
        if mounts is None:
            patches.append(
                {
                    "op": "add",
                    "path": base,
                    "value": [dict(mount_value)],
                },
            )
        else:
            if any(isinstance(m, dict) and m.get("name") == vol_name for m in mounts):
                continue
            patches.append(
                {
                    "op": "add",
                    "path": f"{base}/-",
                    "value": dict(mount_value),
                },
            )


def append_readonly_fixup_patches(
    patches: list[dict],
    template: dict,
    json_prefix: str,
    container_filter: str,
    vol_name: str,
) -> None:
    """Если нужен readOnly, а volumeMount уже есть без readOnly — добавить операции patch."""
    for array_key in ("initContainers", "containers"):
        items = template.get(array_key) or []
        for i, c in enumerate(items):
            if not isinstance(c, dict):
                continue
            cname = c.get("name") or ""
            if container_filter and cname != container_filter:
                continue
            mounts = c.get("volumeMounts") or []
            for j, m in enumerate(mounts):
                if not isinstance(m, dict) or m.get("name") != vol_name:
                    continue
                base = f"{json_prefix}/{array_key}/{i}/volumeMounts/{j}/readOnly"
                if m.get("readOnly") is True:
                    continue
                if m.get("readOnly") is False:
                    patches.append({"op": "replace", "path": base, "value": True})
                else:
                    patches.append({"op": "add", "path": base, "value": True})


def kubectl_patch_json(
    kind: str, name: str, namespace: str, patches: list[dict],
) -> None:
    try:
        subprocess.run(
            [
                "kubectl",
                "patch",
                kind,
                name,
                "-n",
                namespace,
                "--type=json",
                "-p",
                json.dumps(patches),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        print("✗ kubectl не найден в PATH", file=sys.stderr)
        raise SystemExit(1) from None
    except subprocess.CalledProcessError as e:
        print(
            f"✗ kubectl patch {kind}/{name} -n {namespace} (код {e.returncode})",
            file=sys.stderr,
        )
        err = (e.stderr or "").strip()
        if err:
            print(err, file=sys.stderr)
        raise SystemExit(1) from None


def main() -> int:
    namespace = os.environ.get("APP_NS", "").strip()
    if not namespace:
        print("✗ APP_NS пустой", file=sys.stderr)
        return 1

    wk_raw = os.environ.get("APP_LOCAL_K8S_WORKLOAD", "").strip()
    if not wk_raw:
        print(
            "✗ задайте APP_LOCAL_K8S_WORKLOAD (например deployment/my-service)",
            file=sys.stderr,
        )
        return 1

    parts = wk_raw.split("/", 1)
    if len(parts) != 2 or not parts[0] or not parts[1]:
        print(
            "✗ APP_LOCAL_K8S_WORKLOAD ожидается как kind/name (например deployment/api)",
            file=sys.stderr,
        )
        return 1

    kind = workload_kind_short(parts[0])
    workload_name = parts[1]

    host_path = os.environ.get("APP_LOCAL_SRC_HOST_PATH", "").strip()
    if not host_path:
        print("✗ APP_LOCAL_SRC_HOST_PATH пустой", file=sys.stderr)
        return 1

    mount_path = os.environ.get("APP_LOCAL_SRC_MOUNT_PATH", "/work/src").strip() or "/work/src"

    app = os.environ.get("APP", "").strip()
    if not app:
        print("✗ APP пустой", file=sys.stderr)
        return 1

    container_filter = os.environ.get("APP_LOCAL_SRC_CONTAINER", "").strip()
    read_only = env_truthy("APP_LOCAL_SRC_READ_ONLY")

    vol_name = "infra-apps-src-" + dns_subdomain_label(app)
    mount_value = volume_mount_value(vol_name, mount_path, read_only)

    obj = kubectl_get_json(kind, workload_name, namespace)
    template, json_prefix = pod_spec_and_json_prefix(kind, obj)

    if container_filter:
        known = collect_container_names(template)
        if container_filter not in known:
            print(
                f"✗ контейнер {container_filter!r} не найден среди "
                f"initContainers/containers: {known or '(пусто)'}",
                file=sys.stderr,
            )
            return 1

    patches: list[dict] = []

    volumes = template.get("volumes") or []
    existing = None
    for v in volumes:
        if isinstance(v, dict) and v.get("name") == vol_name:
            existing = v
            break

    if existing:
        hp = existing.get("hostPath") or {}
        cur = hp.get("path") or ""
        if cur != host_path:
            print(
                f"✗ volume {vol_name!r} уже есть с другим hostPath ({cur!r} ≠ {host_path!r})",
                file=sys.stderr,
            )
            return 1
        if hp.get("type") not in ("Directory", "DirectoryOrCreate", "", None):
            print(
                f"✗ неожиданный hostPath.type у {vol_name!r}",
                file=sys.stderr,
            )
            return 1
    else:
        patches.append(
            {
                "op": "add",
                "path": f"{json_prefix}/volumes/-",
                "value": {
                    "name": vol_name,
                    "hostPath": {"path": host_path, "type": "DirectoryOrCreate"},
                },
            }
        )

    regular = template.get("containers") or []
    if not regular:
        print("✗ в pod spec нет containers (обязательное поле Pod)", file=sys.stderr)
        return 1

    for array_key in ("initContainers", "containers"):
        append_volume_mount_patches(
            patches,
            template,
            array_key,
            json_prefix,
            container_filter,
            vol_name,
            mount_value,
        )

    if read_only:
        append_readonly_fixup_patches(
            patches, template, json_prefix, container_filter, vol_name,
        )

    if not patches:
        ro = " readOnly" if read_only else ""
        print(
            f"✓ уже настроено: {kind}/{workload_name} namespace={namespace} "
            f"volume={vol_name} → {mount_path}{ro}",
            file=sys.stderr,
        )
        return 0

    kubectl_patch_json(kind, workload_name, namespace, patches)
    ro = " readOnly" if read_only else ""
    print(
        f"✓ patch применён: {kind}/{workload_name} ns={namespace} "
        f"hostPath={host_path} mountPath={mount_path}{ro} ({len(patches)} op)",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
