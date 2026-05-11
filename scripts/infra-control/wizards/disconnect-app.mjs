// Wizard «Отключить приложение» — Сценарий 8 из docs/runbooks/usage-scenarios.md.
// Patch registry: enabled=false → apps-apply → опц. *-app-drop на выбранных
// движках. Двойное подтверждение для *-drop.

import { note, select, multiselect, log } from "../io.mjs";

import { resolveYq } from "../../lib/repo.mjs";
import { patchRegistryEnabled } from "../../lib/registry-yq.mjs";

import {
  ensure,
  promptDangerous,
  promptYesNo,
  promptAppFromSession,
  runTarget,
} from "../prompts.mjs";

import { makeStep } from "./lib.mjs";

const TITLE = "Отключить приложение";
const step = makeStep(TITLE);

const DROP_OPTIONS = [
  { value: "pg",  label: "PostgreSQL",  hint: "pg-app-drop" },
  { value: "rd",  label: "Redis",       hint: "redis-app-drop" },
  { value: "kf",  label: "Kafka",       hint: "kafka-app-drop" },
  { value: "mn",  label: "MinIO",       hint: "minio-app-drop" },
  { value: "ch",  label: "ClickHouse",  hint: "clickhouse-app-drop" },
  { value: "rmq", label: "RabbitMQ",    hint: "rabbitmq-app-drop" },
];

const DROP_TARGET = {
  pg: "pg-app-drop",
  rd: "redis-app-drop",
  kf: "kafka-app-drop",
  mn: "minio-app-drop",
  ch: "clickhouse-app-drop",
  rmq: "rabbitmq-app-drop",
};

/**
 * @param {{ env: string, app?: string|null }} session
 */
export async function wizardDisconnectApp(session) {
  note(
    [
      `ENV: ${session.env}.`,
      "Шаги: APP → enabled=false → apps-apply → опц. удаление учёток.",
    ].join("\n"),
    TITLE,
  );

  // 1. APP
  step(1, 4, "Имя приложения (как в apps/registry.yaml).");
  const app = await promptAppFromSession(session, { requireValue: true, persist: true });
  if (!app) return;

  // 2. enabled=false в registry
  step(2, 4, `Выставить .apps[name=${app}].enabled = false в apps/registry.yaml.`);
  if (await promptYesNo("Снять enabled у приложения в registry?", true)) {
    const ok = patchRegistryEnabled(resolveYq(), app, false);
    if (ok) log.success(`apps/registry.yaml: ${app}.enabled = false`);
    else log.error("Не удалось обновить registry (yq вернул ошибку). Шаг пропущен.");
  }

  // 3. apps-apply (чтобы изменения подхватились — в нашем случае ничего не сделает, но фиксирует state)
  step(3, 4, "Запустим apps-apply, чтобы зафиксировать новое состояние реестра.");
  if (await promptYesNo("Запустить apps-apply сейчас?", true)) {
    await runTarget(session, "apps-apply", {});
  }

  // 4. Опционально: drop учёток
  step(4, 4, "Опционально: удалить учётки приложения в выбранных сервисах.");
  if (
    !(await promptYesNo(
      "Удалить учётки (Secret <APP>-<service> + DB/ACL/policy/vhost)?",
      false,
    ))
  ) {
    note("Учётки оставлены. Wizard завершён.", `${TITLE} · готово`);
    return;
  }

  const picked = ensure(
    await multiselect({
      message: "В каких сервисах удалить учётку APP?",
      options: DROP_OPTIONS,
      required: true,
    }),
  );

  if (
    !(await promptDangerous(
      `Удаление учёток ${app} в: ${picked.map((p) => DROP_OPTIONS.find((o) => o.value === p)?.label).join(", ")}.`,
    ))
  ) {
    note("Отменено. Wizard завершён.", `${TITLE} · готово`);
    return;
  }

  const minioRm = picked.includes("mn")
    ? await promptYesNo("MinIO: также удалить бакеты приложения? (MINIO_REMOVE_BUCKETS=1)", false)
    : false;

  for (const p of picked) {
    /** @type {Record<string,string>} */
    const env = { APP: app, SKIP_CONFIRM: "1" };
    if (p === "mn" && minioRm) env.MINIO_REMOVE_BUCKETS = "1";
    await runTarget(session, DROP_TARGET[p], env);
  }

  note(
    `Приложение ${app} отключено. Если репо и hostPath больше не нужны — удалите apps/src/${app} и слот в registry вручную.`,
    `${TITLE} · готово`,
  );
}
