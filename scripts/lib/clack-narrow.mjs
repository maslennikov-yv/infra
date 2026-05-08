/**
 * Обёртка @clack/prompts: перенос длинных подписей под «стандартную» ширину терминала.
 */
import "./clack-escape-patch.mjs";
import {
  intro as rawIntro,
  outro as rawOutro,
  cancel as rawCancel,
  select as rawSelect,
  multiselect as rawMultiselect,
  confirm as rawConfirm,
  text as rawText,
  password as rawPassword,
  note as rawNote,
  isCancel,
  log,
} from "@clack/prompts";

import { wrapCliText } from "./terminal-wrap.mjs";

export { isCancel, log };

export const intro = (t) => {
  rawIntro(wrapCliText(t ?? ""));
  process.stdout.write("\n");
};

export const outro = (m) => rawOutro(wrapCliText(m ?? ""));
export const cancel = (m) => rawCancel(wrapCliText(m ?? ""));

export const note = (body, title) => {
  rawNote(wrapCliText(body ?? ""), title);
  process.stdout.write("\n");
};

export const select = (opts) =>
  rawSelect({ ...opts, message: wrapCliText(opts.message ?? "") });

export const multiselect = (opts) =>
  rawMultiselect({ ...opts, message: wrapCliText(opts.message ?? "") });

export const confirm = (opts) =>
  rawConfirm({ ...opts, message: wrapCliText(opts.message ?? "") });

export const text = (opts) =>
  rawText({ ...opts, message: wrapCliText(opts.message ?? "") });

export const password = (opts) =>
  rawPassword({ ...opts, message: wrapCliText(opts.message ?? "") });
