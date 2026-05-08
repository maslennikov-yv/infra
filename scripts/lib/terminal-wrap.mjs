/** Классическая ширина терминала для переноса длинных блоков TUI */

export const STANDARD_TERMINAL_COLUMNS = 80;

/**
 * Ширина «логического» экрана: не шире стандартного терминала и не шире реальных колонок.
 */
export function terminalDisplayWidth() {
  const tty = process.stdout.columns;
  if (!tty || tty < 40) return STANDARD_TERMINAL_COLUMNS;
  return Math.min(tty, STANDARD_TERMINAL_COLUMNS);
}

/**
 * Максимальная длина строки текста в промптах clack (рамки и префиксы символов состояния).
 */
export function clackContentWidth(gutter = 6) {
  return Math.max(terminalDisplayWidth() - gutter, 36);
}

/**
 * @param {string} line
 * @param {number} maxWidth
 * @returns {string[]}
 */
function wrapParagraphLine(line, maxWidth) {
  const out = [];
  let rest = line;
  while (rest.length > maxWidth) {
    const idx = rest.lastIndexOf(" ", maxWidth);
    if (idx > 0) {
      out.push(rest.slice(0, idx).trimEnd());
      rest = rest.slice(idx + 1).trimStart();
    } else {
      out.push(rest.slice(0, maxWidth));
      rest = rest.slice(maxWidth);
    }
  }
  if (rest.length > 0) out.push(rest);
  return out;
}

/**
 * Перенос по словам с сохранением явных разрывов строк.
 */
export function wrapCliText(text, maxWidth = clackContentWidth()) {
  if (text == null || text === "") return text;
  const paras = String(text).split(/\r?\n/);
  const wrapped = [];
  for (const para of paras) {
    if (para === "") {
      wrapped.push("");
      continue;
    }
    wrapped.push(...wrapParagraphLine(para, maxWidth));
  }
  return wrapped.join("\n");
}
