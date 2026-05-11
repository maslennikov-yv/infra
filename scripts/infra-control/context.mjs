// Контекст сессии TUI: ENV (как сейчас) + APP (новое, кэш per-ENV).
// APP сохраняется между запусками TUI в `~/.cache/infra-tui/last-app-<env>`,
// чтобы не вводить имя приложения в каждом действии (Сценарий 3 из usage-scenarios.md).

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const CACHE_DIR = path.join(os.homedir(), ".cache", "infra-tui");

/** @typedef {{ env: string, app?: string|null }} Session */

function appCachePath(env) {
  return path.join(CACHE_DIR, `last-app-${env}`);
}

/** Прочитать кэш APP для данного ENV. Возвращает null, если кэша нет/пуст. */
export function loadCachedApp(env) {
  if (!env) return null;
  const f = appCachePath(env);
  try {
    if (!fs.existsSync(f)) return null;
    const v = fs.readFileSync(f, "utf8").trim();
    return v || null;
  } catch {
    return null;
  }
}

/** Сохранить APP для ENV. Пустая строка = очистить кэш. Best-effort: ошибки I/O глотаем. */
export function saveCachedApp(env, app) {
  if (!env) return;
  const value = String(app ?? "").trim();
  try {
    if (!value) {
      fs.rmSync(appCachePath(env), { force: true });
      return;
    }
    fs.mkdirSync(CACHE_DIR, { recursive: true });
    fs.writeFileSync(appCachePath(env), value + "\n", "utf8");
  } catch {
    // не валим TUI из-за кэша
  }
}

/** Удалить кэш APP для ENV. */
export function clearCachedApp(env) {
  saveCachedApp(env, "");
}

/**
 * Гарантировать форму Session (наличие поля app). Подтягивает APP из кэша,
 * если поле отсутствует. Возвращает тот же объект (мутирует).
 * @param {Session} session
 */
export function ensureSessionShape(session) {
  if (!session || typeof session !== "object") {
    return /** @type {Session} */ ({ env: "local", app: null });
  }
  // Подтягиваем кэш только когда app не задан явно. `null` считаем явным
  // выбором "очистить", поэтому подмена идёт только для `undefined` или
  // отсутствующего поля.
  if (session.app === undefined) {
    session.app = loadCachedApp(session.env) ?? null;
  }
  return session;
}

/**
 * Применить новое APP к сессии и записать в кэш (если поменялось).
 * @param {Session} session
 * @param {string|null|undefined} app
 */
export function setSessionApp(session, app) {
  const v = app == null ? null : String(app).trim() || null;
  session.app = v;
  saveCachedApp(session.env, v ?? "");
}

/**
 * Сменить ENV в сессии, переподтянув APP-кэш для нового ENV.
 * Используется при выборе ENV в меню «Сессия» нового TUI.
 * @param {Session} session
 * @param {string} env
 */
export function setSessionEnv(session, env) {
  session.env = env;
  session.app = loadCachedApp(env) ?? null;
}

/**
 * Однострочный заголовок для шапки меню. Доп. поля передаются через `extras`.
 * Пример: `ENV: stage · APP: myapp · kubeconfig: ok`.
 * @param {Session} session
 * @param {Record<string, string|null|undefined>} [extras]
 */
export function renderSessionHeader(session, extras = {}) {
  const parts = [`ENV: ${session?.env ?? "?"}`];
  parts.push(`APP: ${session?.app ?? "—"}`);
  for (const [k, v] of Object.entries(extras)) {
    if (v != null && v !== "") parts.push(`${k}: ${v}`);
  }
  return parts.join(" · ");
}

/** Полный путь к каталогу кэша — для диагностики/инструментов. */
export function getCacheDir() {
  return CACHE_DIR;
}
