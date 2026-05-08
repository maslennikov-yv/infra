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
