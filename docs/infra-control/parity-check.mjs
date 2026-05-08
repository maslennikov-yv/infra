#!/usr/bin/env node
/**
 * Makefile ↔ docs/infra-control/targets.json parity checker.
 *
 * Exit 1 if .PHONY (minus help, infra-lab) + Postgres extras mismatch manifest.
 */

import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "../..");

const EXTRA_TARGETS = [
  "postgres-backup",
  "postgres-restore",
  "postgres-delete-pvcs",
  "postgres-recreate-prep",
  "pg-app-verify",
];

const EXCLUDED_PHONY = new Set(["help", "infra-lab", "infra-control-parity-check"]);

function parseMakefilePhony(mkPath) {
  const lines = readFileSync(mkPath, "utf8").split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith(".PHONY:")) continue;
    const block = [];
    let j = i;
    while (j < lines.length) {
      block.push(lines[j]);
      if (!lines[j].replace(/\s+$/, "").endsWith("\\")) break;
      j++;
    }
    const merged = block.join(" ");
    const [, rest = ""] = merged.split(/^\.PHONY:\s*/);
    const names = [];
    for (const token of rest.split(/[\s\\]+/).map((x) => x.trim()).filter(Boolean))
      names.push(token);
    return names;
  }
  throw new Error(`.PHONY not found in ${mkPath}`);
}

function makefileHasGoal(makefileLines, goal) {
  const escaped = goal.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(`^${escaped}:`);
  return makefileLines.some((ln) => re.test(ln.trim()));
}

function main() {
  const mkPath = path.join(REPO_ROOT, "Makefile");
  const manifestPath = path.join(REPO_ROOT, "docs", "infra-control", "targets.json");

  const phonyTokens = parseMakefilePhony(mkPath);
  const phonySet = phonyTokens.filter((t) => !EXCLUDED_PHONY.has(t));
  const makefileLines = readFileSync(mkPath, "utf8").split(/\r?\n/).map((l) => l.trim());

  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const entries = manifest.targets;
  if (!Array.isArray(entries)) {
    console.error("targets.json: expected { targets: [...] }");
    process.exit(1);
  }

  const manifestTargets = new Set(entries.map((e) => e.makeTarget));

  const required = new Set(phonySet);
  for (const e of EXTRA_TARGETS) required.add(e);

  const missingInManifest = [...required].filter((t) => !manifestTargets.has(t)).sort();

  const extraInManifest = [...manifestTargets].filter((t) => !required.has(t)).sort();

  let bad = false;
  if (missingInManifest.length) {
    console.error(
      `Missing from targets.json (expected by Makefile parity): ${missingInManifest.join(", ")}`,
    );
    bad = true;
  }
  if (extraInManifest.length) {
    console.error(
      `targets.json describes unknown makefile goals (not in union): ${extraInManifest.join(", ")}`,
    );
    bad = true;
  }

  const missingRecipes = [...manifestTargets]
    .filter((t) => !makefileHasGoal(makefileLines, t))
    .sort();

  if (missingRecipes.length) {
    console.error(
      `Manifest entries without matching Makefile rule prefix: ${missingRecipes.join(", ")}`,
    );
    bad = true;
  }

  if (bad) process.exit(1);
  console.log(`OK: ${manifestTargets.size} makefile goals covered by infra-control manifest.`);
}

main();
