// Wizard «Конфигурирование сервисов» — управляет составом релизов helm в
// environments/<ENV>.mk через переменные ENABLED_SERVICES / EXCLUDE_SERVICES.
// Делает только две вещи: фиксирует политику в .mk и показывает diff.
// Сам apply остаётся за пунктом «Применить изменения», destroy — за
// «Окружение и образы → Helm: уничтожить релизы».

import { note, select, multiselect, log } from "../io.mjs";
import {
  ensure,
  promptYesNo,
  runTarget,
} from "../prompts.mjs";

import { REPO_ROOT } from "../../lib/repo.mjs";
import {
  readHelmServiceVarsMk,
  persistHelmServiceVarsMk,
  clearHelmServiceVarsMk,
} from "../../lib/env-mk-persist.mjs";

import { HELM_OPTIONS } from "../meta.mjs";

const TITLE = "Конфигурирование сервисов";

/**
 * @param {{ env: string }} session
 */
export async function wizardConfigureServices(session) {
  const current = readHelmServiceVarsMk(REPO_ROOT, session.env);

  note(
    [
      `ENV: ${session.env}.`,
      `Файл: environments/${session.env}.mk${current.exists ? "" : " (отсутствует — будет создан при записи)"}.`,
      `Сейчас: ENABLED_SERVICES=${formatCsv(current.enabledCsv)}, EXCLUDE_SERVICES=${formatCsv(current.excludeCsv)}.`,
      "",
      "Wizard зафиксирует политику в .mk и покажет diff. Apply — отдельным пунктом «Применить изменения».",
    ].join("\n"),
    TITLE,
  );

  // 1. Режим состава
  const mode = ensure(
    await select({
      message: "Какой состав сервисов хотите зафиксировать?",
      options: [
        {
          value: "all",
          label: "Весь набор",
          hint: "очистить ENABLED_SERVICES и EXCLUDE_SERVICES",
        },
        {
          value: "only",
          label: "Только указанные",
          hint: "записать ENABLED_SERVICES, удалить EXCLUDE_SERVICES",
        },
        {
          value: "except",
          label: "Кроме указанных",
          hint: "записать EXCLUDE_SERVICES, удалить ENABLED_SERVICES",
        },
        { value: "cancel", label: "Отмена" },
      ],
    }),
  );
  if (mode === "cancel") return;

  // 2. Если не «весь набор» — мультивыбор
  /** @type {string|null} */
  let csv = null;
  if (mode !== "all") {
    const initial = pickInitial(mode, current);
    const picked = ensure(
      await multiselect({
        message:
          mode === "only"
            ? "Какие сервисы оставить включёнными:"
            : "Какие сервисы исключить из набора:",
        options: HELM_OPTIONS,
        initialValues: initial,
        required: true,
      }),
    );
    csv = picked.join(",");
  }

  // 3. Запись политики в <env>.mk
  const writeMsg =
    mode === "all"
      ? `Очистить ENABLED_SERVICES и EXCLUDE_SERVICES в environments/${session.env}.mk?`
      : mode === "only"
        ? `Записать ENABLED_SERVICES=${csv} в environments/${session.env}.mk?`
        : `Записать EXCLUDE_SERVICES=${csv} в environments/${session.env}.mk?`;
  if (await promptYesNo(writeMsg, true)) {
    try {
      if (mode === "all") {
        const r = clearHelmServiceVarsMk(REPO_ROOT, session.env);
        if (!r.existed) {
          log.info(`Файл ${r.path} отсутствует — нечего очищать.`);
        } else if (r.changed) {
          log.success(`Очищены ENABLED_SERVICES/EXCLUDE_SERVICES: ${r.path}`);
        } else {
          log.info(`Переменные уже отсутствовали: ${r.path}`);
        }
      } else {
        const spec =
          mode === "only" ? { enabledCsv: csv } : { excludeCsv: csv };
        const r = persistHelmServiceVarsMk(REPO_ROOT, session.env, spec);
        if (r.created) {
          note(
            "Файл создан с одной переменной. Для SSH_HOST/KUBECONFIG используйте «Окружение и образы → Создать рыбу окружения (env-new)» или допишите вручную.",
            `environments/${session.env}.mk`,
          );
        }
        log.success(`Записано: ${r.path}`);
      }
    } catch (e) {
      log.error(String(e?.message || e));
      return;
    }
  } else {
    note("Запись отменена. Wizard завершён без изменений.", `${TITLE} · готово`);
    return;
  }

  // 4. Diff (без env-переменных — make сам подтянет .mk)
  if (await promptYesNo("Показать helm diff с новой политикой?", true)) {
    await runTarget(session, "diff", {});
  }

  // 5. Сводка
  note(
    [
      "Политика зафиксирована.",
      "• Применить состав в кластер — «Применить изменения».",
      "• Образы для нового сервиса — «Окружение и образы → Образы: …».",
      "• Удалить выпавшие релизы — «Окружение и образы → Helm: уничтожить релизы (опасно)».",
      "• Учётки приложений для нового сервиса — «Учётки и топики → движок → Создать учётку».",
    ].join("\n"),
    `${TITLE} · готово`,
  );
}

/**
 * @param {string|null} csv
 */
function formatCsv(csv) {
  return csv && csv.trim() ? csv : "—";
}

/**
 * Если режим совпадает с тем, что уже в .mk, — подставляем те же сервисы как
 * initialValues для multiselect. Иначе — пусто.
 *
 * @param {"only"|"except"} mode
 * @param {{ enabledCsv: string|null, excludeCsv: string|null }} current
 * @returns {string[]}
 */
function pickInitial(mode, current) {
  const csv = mode === "only" ? current.enabledCsv : current.excludeCsv;
  if (!csv) return [];
  return csv
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}
