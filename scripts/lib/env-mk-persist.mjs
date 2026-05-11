import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const TARGET_VARS = new Set(["ENABLED_SERVICES", "EXCLUDE_SERVICES"]);

/**
 * @param {string} line
 */
function declaresTargetVar(line) {
  const m = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\?=/.exec(line);
  if (!m) return false;
  return TARGET_VARS.has(m[1]);
}

/**
 * Прочитать действующие значения `ENABLED_SERVICES ?=` / `EXCLUDE_SERVICES ?=`
 * из `environments/<envName>.mk`. Если файла нет или переменная не задана —
 * соответствующее поле = null.
 *
 * @param {string} repoRoot
 * @param {string} envName
 * @returns {{ path: string, exists: boolean, enabledCsv: string|null, excludeCsv: string|null }}
 */
export function readHelmServiceVarsMk(repoRoot, envName) {
  const pathMk = join(repoRoot, "environments", `${envName}.mk`);
  if (!existsSync(pathMk)) {
    return { path: pathMk, exists: false, enabledCsv: null, excludeCsv: null };
  }
  const raw = readFileSync(pathMk, "utf8");
  let enabledCsv = null;
  let excludeCsv = null;
  const re = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\?=\s*(.*)$/;
  for (const line of raw.split(/\r?\n/)) {
    const m = re.exec(line);
    if (!m) continue;
    if (m[1] === "ENABLED_SERVICES") enabledCsv = m[2].trim() || null;
    else if (m[1] === "EXCLUDE_SERVICES") excludeCsv = m[2].trim() || null;
  }
  return { path: pathMk, exists: true, enabledCsv, excludeCsv };
}

/**
 * @param {string} repoRoot
 * @param {string} envName
 * @param {{ enabledCsv?: string, excludeCsv?: string }} spec
 */
export function persistHelmServiceVarsMk(repoRoot, envName, spec) {
  const enabledCsv = spec.enabledCsv;
  const excludeCsv = spec.excludeCsv;
  if (
    (!enabledCsv || !String(enabledCsv).trim()) &&
    (!excludeCsv || !String(excludeCsv).trim())
  ) {
    throw new Error("persistHelmServiceVarsMk: нужно enabledCsv или excludeCsv");
  }

  const pathMk = join(repoRoot, "environments", `${envName}.mk`);
  const raw = existsSync(pathMk) ? readFileSync(pathMk, "utf8") : "";
  const kept = raw.split(/\r?\n/).filter((ln) => !declaresTargetVar(ln));
  while (kept.length && kept[kept.length - 1] === "") kept.pop();

  const block =
    enabledCsv != null && String(enabledCsv).trim()
      ? `ENABLED_SERVICES ?= ${String(enabledCsv).trim()}`
      : `EXCLUDE_SERVICES ?= ${String(excludeCsv).trim()}`;

  const head = kept.join("\n");
  const out = head ? `${head}\n\n${block}\n` : `${block}\n`;
  writeFileSync(pathMk, out, "utf8");
  return {
    path: pathMk,
    created: raw === "",
  };
}

/**
 * Удалить обе переменные `ENABLED_SERVICES ?=` / `EXCLUDE_SERVICES ?=` из
 * `environments/<envName>.mk`. Остальные строки сохраняются. Если файла нет —
 * ничего не делаем. Если после фильтра обе переменные отсутствовали — записи
 * тоже нет (changed=false).
 *
 * @param {string} repoRoot
 * @param {string} envName
 * @returns {{ path: string, existed: boolean, changed: boolean }}
 */
export function clearHelmServiceVarsMk(repoRoot, envName) {
  const pathMk = join(repoRoot, "environments", `${envName}.mk`);
  if (!existsSync(pathMk)) {
    return { path: pathMk, existed: false, changed: false };
  }
  const raw = readFileSync(pathMk, "utf8");
  const lines = raw.split(/\r?\n/);
  const hadTarget = lines.some((ln) => declaresTargetVar(ln));
  if (!hadTarget) {
    return { path: pathMk, existed: true, changed: false };
  }
  const kept = lines.filter((ln) => !declaresTargetVar(ln));
  while (kept.length && kept[kept.length - 1] === "") kept.pop();
  const out = kept.length ? `${kept.join("\n")}\n` : "";
  writeFileSync(pathMk, out, "utf8");
  return { path: pathMk, existed: true, changed: true };
}
