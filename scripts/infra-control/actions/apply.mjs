// «Применить изменения» — helm up + apps-apply на выбранных сервисах.
// Объединяет `up` глобально и точечно (через мультивыбор одного сервиса).

import { log, note } from "../io.mjs";
import { REPO_ROOT } from "../../lib/repo.mjs";
import { persistHelmServiceVarsMk } from "../../lib/env-mk-persist.mjs";
import {
  promptYesNo,
  promptServicesSelection,
  runTarget,
} from "../prompts.mjs";

/**
 * @param {{ env: string }} session
 */
export async function actionApply(session) {
  note(
    [
      "Действие: helm up на выбранных сервисах + apps-apply (учётки приложений).",
      `ENV: ${session.env}.`,
    ].join("\n"),
    "Применить изменения",
  );

  const { enabled, exclude } = await promptServicesSelection({ kind: "up" });

  /** @type {Record<string, string>} */
  const env = {};
  if (enabled !== null) env.ENABLED_SERVICES = enabled;
  if (exclude !== null) env.EXCLUDE_SERVICES = exclude;

  if (
    await promptYesNo(
      "Пропустить apps-apply после helm up? (SKIP_APPS_APPLY=1)",
      false,
    )
  ) {
    env.SKIP_APPS_APPLY = "1";
  }

  if (
    await promptYesNo(
      "Если apps-apply упадёт на одном сервисе — продолжать остальные? (APPS_APPLY_CONTINUE_ON_ERROR=1)",
      false,
    )
  ) {
    env.APPS_APPLY_CONTINUE_ON_ERROR = "1";
  }

  const ok = await runTarget(session, "up", env);
  if (ok) await maybePersistMk(session, enabled, exclude);
}

async function maybePersistMk(session, enabled, exclude) {
  if (enabled === null && exclude === null) return;
  const yes = await promptYesNo(
    `Сохранить выбор сервисов в environments/${session.env}.mk (ENABLED_SERVICES / EXCLUDE_SERVICES)?`,
    false,
  );
  if (!yes) return;
  try {
    const spec =
      enabled !== null ? { enabledCsv: enabled } : { excludeCsv: exclude };
    const r = persistHelmServiceVarsMk(REPO_ROOT, session.env, spec);
    if (r.created) {
      note(
        "Файл создан с одной переменной. Для SSH_HOST/KUBECONFIG используйте `make env-new` или допишите вручную.",
        `environments/${session.env}.mk`,
      );
    }
    log.success(`Записано: ${r.path}`);
  } catch (e) {
    log.error(String(e?.message || e));
  }
}
