// «Сравнить с кластером» — helm diff на выбранных сервисах. Без побочек.

import { note } from "../io.mjs";
import { promptServicesSelection, runTarget } from "../prompts.mjs";

/**
 * @param {{ env: string }} session
 */
export async function actionDiff(session) {
  note(
    `Действие: helm diff на выбранных сервисах. ENV: ${session.env}.`,
    "Сравнить с кластером",
  );
  const { enabled, exclude } = await promptServicesSelection({ kind: "diff" });
  /** @type {Record<string, string>} */
  const env = {};
  if (enabled !== null) env.ENABLED_SERVICES = enabled;
  if (exclude !== null) env.EXCLUDE_SERVICES = exclude;
  await runTarget(session, "diff", env);
}
