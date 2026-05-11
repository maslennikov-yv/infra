// «Настройка → Чарты: verify / updates» — проверка чартов и обновлений.
// Цели:
//   <svc>-verify         — images-verify для сервиса (dry-run, без деплоя)
//   check-updates        — сводка по всем bitnami-чартам
//   <svc>-check-updates  — только конкретный чарт
//
// SERVICES в Makefile: postgres kafka redis minio clickhouse rabbitmq (без Netdata).

import { select, note } from "../io.mjs";
import { ensure, runTarget } from "../prompts.mjs";
import { ACCOUNT_OPTIONS, displayServiceName } from "../meta.mjs";

/**
 * @param {{ env: string }} session
 */
export async function settingsCharts(session) {
  for (;;) {
    const choice = ensure(
      await select({
        message: `Чарты: проверка и обновления · ENV: ${session.env}`,
        options: [
          { value: "updates_all", label: "Обновления: сводка по всем чартам",      hint: "check-updates" },
          { value: "updates_one", label: "Обновления: один чарт",                  hint: "<svc>-check-updates" },
          { value: "verify_one",  label: "Verify: один чарт",                      hint: "<svc>-verify — images-verify dry-run" },
          { value: "back",        label: "Назад" },
        ],
      }),
    );
    if (choice === "back") return;

    if (choice === "updates_all") {
      await runTarget(session, "check-updates", {});
      continue;
    }
    const svc = await pickService(choice === "verify_one" ? "verify" : "check-updates");
    if (!svc) continue;
    const target = choice === "verify_one" ? `${svc}-verify` : `${svc}-check-updates`;
    await runTarget(session, target, {});
  }
}

async function pickService(suffix) {
  const svc = ensure(
    await select({
      message: `Чарт для ${suffix}:`,
      options: [...ACCOUNT_OPTIONS, { value: "back", label: "Назад" }],
    }),
  );
  if (svc === "back") return null;
  return svc;
}
