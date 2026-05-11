// Общие helpers для wizard'ов.

import { note } from "../io.mjs";

/**
 * Создаёт step-функцию, привязанную к заголовку конкретного wizard'а.
 * Каждый вызов печатает breadcrumb "TITLE · шаг N/M" с описанием шага.
 *
 * Использование:
 *   const step = makeStep("Подключить приложение");
 *   step(1, 7, "Имя приложения.");
 *
 * @param {string} title
 */
export function makeStep(title) {
  return (cur, total, what) => {
    note(what, `${title} · шаг ${cur}/${total}`);
  };
}
