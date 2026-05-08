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
