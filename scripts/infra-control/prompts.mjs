// Общие интерактивные prompts для TUI v2. Сознательно проще, чем в run.mjs:
// нет шага «Перейти / Справка» перед multiselect (лишний экран), нет двойных
// confirm-шагов кроме явно опасных операций.

import {
  cancel,
  confirm,
  isCancel,
  log,
  multiselect,
  select,
  text,
} from "./io.mjs";

import { runMake, reportMakeExit } from "../lib/make.mjs";
import { resolveYq } from "../lib/repo.mjs";
import { listRegistryApps } from "../lib/registry-yq.mjs";
import { HELM_OPTIONS } from "./meta.mjs";
import { setSessionApp } from "./context.mjs";

const MANUAL = "__manual__";
const CLEAR = "__clear__";

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
 * Универсальный prompt со списком подсказок.
 * - `suggestions.length === 0` → fallback к `text()` (поведение 1:1 как старый APP-prompt).
 * - Иначе показывает `select`: каждая подсказка (`value: name`, опционально `hint`),
 *   `initialValue = sessionValue` — под курсором сразу сессионное значение.
 *   Последним пунктом — «Ввести вручную…», открывает `text()`.
 *   При `requireValue === false` добавляется пункт «Очистить» → возвращает `null`.
 *
 * @param {{
 *   message: string,
 *   suggestions: Array<{ value: string, label?: string, hint?: string }>,
 *   sessionValue?: string|null,
 *   requireValue?: boolean,
 *   manualLabel?: string,
 *   clearLabel?: string,
 * }} opts
 * @returns {Promise<string|null>}
 */
export async function promptWithSuggestions(opts) {
  const {
    message,
    suggestions,
    sessionValue = null,
    requireValue = true,
    manualLabel = "Ввести вручную…",
    clearLabel = "Очистить (пусто)",
  } = opts;

  if (!suggestions || suggestions.length === 0) {
    return await textFallback({ message, initialValue: sessionValue, requireValue });
  }

  /** @type {{value: string, label: string, hint?: string}[]} */
  const options = suggestions.map((s) => ({
    value: s.value,
    label: s.label ?? s.value,
    ...(s.hint ? { hint: s.hint } : {}),
  }));
  options.push({ value: MANUAL, label: manualLabel });
  if (!requireValue) options.push({ value: CLEAR, label: clearLabel });

  // initialValue ставим только если действительно есть совпадающий пункт —
  // иначе clack нарисует курсор на первом элементе, что нам и нужно.
  const hasSessionMatch = !!sessionValue && options.some((o) => o.value === sessionValue);
  /** @type {Record<string, unknown>} */
  const selectArgs = { message, options };
  if (hasSessionMatch) selectArgs.initialValue = sessionValue;

  const picked = ensure(await select(selectArgs));
  if (picked === CLEAR) return null;
  if (picked === MANUAL) {
    return await textFallback({ message, initialValue: sessionValue, requireValue });
  }
  return String(picked);
}

async function textFallback({ message, initialValue, requireValue }) {
  const v = ensure(
    await text({
      message,
      initialValue: initialValue ?? "",
      validate: (s) =>
        !s || !String(s).trim()
          ? requireValue
            ? "Обязательное поле"
            : undefined
          : undefined,
    }),
  );
  return String(v ?? "").trim() || null;
}

/**
 * Запросить APP. Подтягивает список из apps/registry.yaml (если есть) и показывает
 * выбор; если реестра нет/он пуст — fallback к вводу строки. Сессионное APP
 * подсвечивается курсором по умолчанию. Возвращает строку или null.
 *
 * @param {{ env: string, app?: string|null }} session
 * @param {{ requireValue?: boolean, persist?: boolean, message?: string }} [opts]
 */
export async function promptAppFromSession(session, opts = {}) {
  const {
    requireValue = true,
    persist = true,
    message = "APP — выберите приложение или введите вручную:",
  } = opts;

  const apps = listRegistryApps(resolveYq());
  /** @type {Array<{value: string, label: string, hint?: string}>} */
  const suggestions = apps.map((a) => {
    const hintParts = [a.enabled ? "enabled" : "disabled"];
    if (a.app_ns && a.app_ns !== a.name) hintParts.push(`ns=${a.app_ns}`);
    return { value: a.name, label: a.name, hint: hintParts.join(", ") };
  });

  const picked = await promptWithSuggestions({
    message,
    suggestions,
    sessionValue: session.app ?? null,
    requireValue,
    manualLabel: "Ввести вручную (не из реестра)…",
  });

  if (persist) setSessionApp(session, picked);
  return picked;
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
