import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const DATA_SERVICES_PATH = fileURLToPath(new URL("./data-services.txt", import.meta.url));

/**
 * Имена сервисов из data-services.txt (без netdata и прочих только-helm сервисов).
 * @returns {string[]}
 */
export function loadDataServices() {
  return readFileSync(DATA_SERVICES_PATH, "utf8")
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l.length > 0 && !l.startsWith("#"));
}

/** Кэш для импорта из infra-lab / configure-infra */
export const DATA_SERVICES = loadDataServices();
