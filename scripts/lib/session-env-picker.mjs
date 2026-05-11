import { readdirSync } from "node:fs";

import { ENVIRONMENTS_DIR } from "./repo.mjs";

/** Жирный ярко-красный: production ENV в списке сессии (заметно в TUI). */
const ANSI_PROD_HIGHLIGHT = "\u001b[1;91m";
const ANSI_RESET = "\u001b[0m";

/**
 * Подпись пункта в select для окружения (value остаётся обычным именем файла).
 * @param {string} name
 */
export function formatSessionEnvOptionLabel(name) {
  if (name === "prod") return `${ANSI_PROD_HIGHLIGHT}prod${ANSI_RESET}`;
  return name;
}

/**
 * Валидатор имени ENV: латиница/цифры/`-`/`_`, начинать с буквы.
 * Используется пунктом env-new в TUI и тестами валидаторов.
 * @param {unknown} v
 * @returns {string|undefined}
 */
export function validateEnvName(v) {
  const t = String(v ?? "").trim();
  if (!t) return "ENV обязателен";
  if (!/^[a-z][a-z0-9_-]*$/.test(t))
    return "Только латиница/цифры/-/_, начинать с буквы";
  return undefined;
}

export function listEnvironmentNames() {
  try {
    const names = readdirSync(ENVIRONMENTS_DIR).filter((f) =>
      f.endsWith(".yaml"),
    );
    return names.map((f) => f.replace(/\.yaml$/, "")).sort();
  } catch {
    return [];
  }
}

/**
 * Выбор ENV для объекта сессии TUI (список environments/*.yaml или ввод текста).
 *
 * @param {{ env: string }} session
 * @param {{
 *   ensure: (v: unknown) => unknown,
 *   select: (opts: object) => Promise<unknown>,
 *   text: (opts: object) => Promise<unknown>,
 *   helpOption: { value: string, label: string },
 *   showHelp: () => void,
 *   selectMessage?: string,
 * }} ctx
 */
export async function pickSessionEnvInteractive(session, ctx) {
  const {
    ensure,
    select,
    text,
    helpOption,
    showHelp,
    selectMessage = "Окружение (ENV) для сессии меню:",
  } = ctx;

  const envNames = listEnvironmentNames();
  if (envNames.length > 0) {
    const initial = envNames.includes(session.env) ? session.env : envNames[0];
    for (;;) {
      const picked = ensure(
        await select({
          message: selectMessage,
          options: [
            ...envNames.map((e) => ({
              value: e,
              label: formatSessionEnvOptionLabel(e),
            })),
            helpOption,
          ],
          initialValue: initial,
        }),
      );
      if (picked === helpOption.value) {
        showHelp();
        continue;
      }
      session.env = String(picked);
      break;
    }
  } else {
    const e = ensure(
      await text({
        message: "ENV (в каталоге environments/ нет *.yaml):",
        initialValue: session.env || "local",
        validate: (v) =>
          v && String(v).trim() ? undefined : "ENV не может быть пустым",
      }),
    );
    session.env = String(e).trim();
  }
}
