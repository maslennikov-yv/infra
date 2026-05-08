import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const LIB_DIR = dirname(fileURLToPath(import.meta.url));

/** Корень репозитория infra (на уровень выше scripts/). */
export const REPO_ROOT = resolve(LIB_DIR, "..", "..");

/** Как в корневом Makefile: встроенный yq или из PATH. */
export function resolveYq() {
  const bundled = resolve(REPO_ROOT, ".tools/yq-mikefarah");
  if (existsSync(bundled)) return bundled;
  return "yq";
}

export const REGISTRY_PATH = resolve(REPO_ROOT, "apps/registry.yaml");
export const APPS_SRC = resolve(REPO_ROOT, "apps", "src");
export const APPS_SRC_CLONE = resolve(REPO_ROOT, "scripts", "apps-src-clone.sh");
export const ENVIRONMENTS_DIR = resolve(REPO_ROOT, "environments");
export const APP_CONF_SET = resolve(REPO_ROOT, "scripts/app-conf-set.sh");
export const APPS_CONF_TEMPLATE = resolve(REPO_ROOT, "scripts/apps-conf-template.sh");
