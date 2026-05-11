// Adapter: единая точка для UI-функций в TUI v2.
//
// Реэкспорт через lib/clack-narrow.mjs (обёртка над @clack/prompts с
// wrapCliText для переноса длинных подписей под ширину терминала).
//
// Тесты подменяют этот модуль через node:test mock.module — все 13 файлов
// TUI v2 импортируют UI-функции отсюда, поэтому одна точка перехвата
// заменяет все интерактивные взаимодействия.
export {
  intro,
  outro,
  cancel,
  select,
  multiselect,
  confirm,
  text,
  note,
  log,
  isCancel,
} from "../lib/clack-narrow.mjs";
