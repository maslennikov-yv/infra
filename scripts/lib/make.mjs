import { spawn } from "node:child_process";
import { REPO_ROOT } from "./repo.mjs";

/**
 * @param {string} target
 * @param {{ env?: Record<string, string | undefined>, extraArgs?: string[], handleSigint?: boolean, stdio?: import("node:child_process").StdioOptions }} [options]
 * @returns {Promise<{ code: number }>}
 */
export function runMake(target, options = {}) {
  const {
    env = {},
    extraArgs = [],
    handleSigint = false,
    stdio = "inherit",
  } = options;

  const mergedEnv = { ...process.env };
  for (const [k, v] of Object.entries(env)) {
    if (v !== undefined) mergedEnv[k] = v;
  }

  /* Clack оставляет stdin в raw mode — вывод make не виден и кажется «зависание». */
  try {
    if (process.stdin.isTTY && typeof process.stdin.setRawMode === "function") {
      process.stdin.setRawMode(false);
    }
  } catch {
    /* ignore */
  }

  const child = spawn("make", [target, ...extraArgs], {
    cwd: REPO_ROOT,
    stdio,
    env: mergedEnv,
  });

  return new Promise((resolveP, rejectP) => {
    let killed = false;
    const onSigint = () => {
      if (killed) return;
      killed = true;
      child.kill("SIGINT");
    };

    if (handleSigint) process.on("SIGINT", onSigint);

    child.on("error", (err) => {
      if (handleSigint) process.off("SIGINT", onSigint);
      rejectP(err);
    });

    child.on("exit", (code, signal) => {
      if (handleSigint) process.off("SIGINT", onSigint);
      resolveP({ code: code ?? (signal ? 130 : 1) });
    });
  });
}

export function reportMakeExit(label, code, log) {
  if (code === 0) log.success(`${label}: OK`);
  else log.error(`${label}: exit ${code}`);
}
