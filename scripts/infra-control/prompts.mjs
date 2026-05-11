// Общие интерактивные prompts для TUI v2. Сознательно проще, чем в run.mjs:
// нет шага «Перейти / Справка» перед multiselect (лишний экран), нет двойных
// confirm-шагов кроме явно опасных операций.

import {
  cancel,
  confirm,
  isCancel,
  log,
  multiselect,
  text,
} from "./io.mjs";

import { runMake, reportMakeExit } from "../lib/make.mjs";
import { HELM_OPTIONS } from "./meta.mjs";
import { setSessionApp } from "./context.mjs";

/** Унифицированный обработчик отмены. Вызывает cancel + exit при Ctrl+C. */
export function ensure(value) {
  if (isCancel(value)) {
    cancel("Отменено.");
    process.exit(0);
  }
  return value;
}

export async function promptYesNo(message, initialValue = false) {
  return ensure(await confirm({ message, initialValue }));
}

/** Двойное подтверждение для деструктивных операций. */
export async function promptDangerous(message) {
  if (!(await promptYesNo(`${message} Продолжить?`, false))) return false;
  if (!(await promptYesNo("Точно выполнить?", false))) return false;
  return true;
}

/**
 * Выбор сервисов для helm-операции.
 * Возвращает { enabled, exclude } — каждое CSV-строка или null (=все/ничего не исключать).
 *
 * UX: один confirm («все или выборочно»), один-два multiselect. Никаких
 * дополнительных «справочных» экранов между ними.
 */
export async function promptServicesSelection({ kind = "operation" } = {}) {
  const all = await promptYesNo(
    `Применить «${kind}» ко всему набору сервисов? (Нет — выберу подмножество)`,
    true,
  );
  let enabled = null;
  if (!all) {
    const picked = ensure(
      await multiselect({
        message: "Сервисы для операции (остальные не трогаем):",
        options: HELM_OPTIONS,
        required: true,
      }),
    );
    enabled = picked.join(",");
  }

  let exclude = null;
  if (await promptYesNo("Исключить какие-то сервисы из набора?", false)) {
    const picked = ensure(
      await multiselect({
        message: "Исключить из операции:",
        options: HELM_OPTIONS,
        required: true,
      }),
    );
    exclude = picked.join(",");
  }
  return { enabled, exclude };
}

/**
 * Запросить APP. Если задан в сессии — предложить использовать его (по умолчанию да),
 * либо ввести другой и сохранить в кэш. Возвращает строку (не пустую) или null при отказе.
 *
 * @param {{ env: string, app?: string|null }} session
 * @param {{ requireValue?: boolean, persist?: boolean, message?: string }} [opts]
 */
export async function promptAppFromSession(session, opts = {}) {
  const {
    requireValue = true,
    persist = true,
    message = "APP — короткое имя как в apps/registry.yaml (без пробелов):",
  } = opts;

  if (session.app) {
    const keep = await promptYesNo(
      `Использовать APP=${session.app} из сессии?`,
      true,
    );
    if (keep) return session.app;
  }

  const v = ensure(
    await text({
      message,
      initialValue: session.app ?? "",
      validate: (s) =>
        !s || !String(s).trim()
          ? requireValue
            ? "Обязательное поле"
            : undefined
          : undefined,
    }),
  );
  const app = String(v ?? "").trim() || null;
  if (app && persist) setSessionApp(session, app);
  return app;
}

/**
 * Текстовый prompt с trim. Пустой ввод → пустая строка.
 * @param {string} message
 * @param {string} [initialValue]
 */
export async function optionalText(message, initialValue = "") {
  const v = ensure(await text({ message, initialValue, placeholder: "" }));
  return String(v ?? "").trim();
}

/**
 * Обязательный текстовый prompt. Пустой ввод → повтор.
 * @param {string} message
 * @param {(s: unknown) => string|undefined} [validate]
 *   Опциональный кастомный валидатор; если не задан — проверка только на непустоту.
 */
export async function requiredText(message, validate) {
  const v = ensure(
    await text({
      message,
      validate:
        validate ??
        ((s) => (s && String(s).trim() ? undefined : "Обязательное поле")),
    }),
  );
  return String(v).trim();
}

/**
 * Запустить make-цель с ENV из сессии. Возвращает true при exit code 0
 * (или 130 при `sigint: true`). Логирует step / success / error.
 *
 * @param {{ env: string }} session
 * @param {string} target
 * @param {Record<string,string|undefined>} [env]
 * @param {{ sigint?: boolean }} [opts]
 */
export async function runTarget(session, target, env = {}, opts = {}) {
  log.step(`→ make ${target} ENV=${session.env}`);
  const { code } = await runMake(target, {
    env: { ENV: session.env, ...env },
    handleSigint: opts.sigint === true,
  });
  if (opts.sigint && (code === 0 || code === 130)) {
    log.info("Поток остановлен (Ctrl+C), возврат в меню.");
    return code === 0 || code === 130;
  }
  reportMakeExit(target, code, log);
  return code === 0;
}
