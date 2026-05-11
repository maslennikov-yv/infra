import { existsSync } from "node:fs";
import { spawnSync } from "node:child_process";

import { REGISTRY_PATH } from "./repo.mjs";

/** @returns {boolean} */
export function patchRegistryEnabled(yqBin, appName, enabledBool) {
  const lit = enabledBool ? "true" : "false";
  const r = spawnSync(
    yqBin,
    ["-i", `(.apps[] | select(.name == strenv(APPNAME))).enabled = ${lit}`, REGISTRY_PATH],
    { encoding: "utf8", env: { ...process.env, APPNAME: appName } },
  );
  return r.status === 0;
}

/**
 * Перечислить приложения из apps/registry.yaml. Возвращает `[]`, если файла нет
 * (свежий клон до `cp registry.yaml.example registry.yaml`) или yq упал —
 * вызывающая сторона трактует это как «suggest недоступен, fallback на text()».
 *
 * @param {string} yqBin
 * @param {string} [registryPath]
 * @returns {Array<{name: string, enabled: boolean, app_ns: string|null}>}
 */
export function listRegistryApps(yqBin, registryPath = REGISTRY_PATH) {
  if (!existsSync(registryPath)) return [];
  const r = spawnSync(
    yqBin,
    ["-o=json", '[.apps[] | {"name": .name, "enabled": .enabled, "app_ns": .app_ns}]', registryPath],
    { encoding: "utf8" },
  );
  if (r.status !== 0 || !r.stdout) return [];
  let parsed;
  try {
    parsed = JSON.parse(r.stdout);
  } catch {
    return [];
  }
  if (!Array.isArray(parsed)) return [];
  return parsed
    .filter((x) => x && typeof x.name === "string" && x.name.trim())
    .map((x) => ({
      name: String(x.name).trim(),
      enabled: x.enabled === true,
      app_ns: typeof x.app_ns === "string" && x.app_ns.trim() ? x.app_ns.trim() : null,
    }));
}
