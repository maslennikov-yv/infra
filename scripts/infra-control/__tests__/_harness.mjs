// Тестовый harness для TUI v2.
//
// Главная идея: подменяем `io.mjs` (UI-функции @clack) и `lib/make.mjs`
// (spawn make) ОДИН раз на тестовый файл (через mock.module из node:test).
// Поведение под-тестов выбирается через mutable ref: `scriptRef.current`,
// `makeCallsRef.current`. Это обходит ограничение node:test 20.x:
// нельзя дважды `mock.module(sameSpecifier)` в одном процессе, а `cache: false`
// не пересоздаёт closure уже-импортированных тестируемых модулей.
//
// Запуск с флагом `--experimental-test-module-mocks` (Node 20.x).
//
// Использование:
//
//   import { before, test, describe } from "node:test";
//   import { setupHarness, runWith } from "./_harness.mjs";
//
//   const h = setupHarness(before, {
//     extraMocks: { "../../lib/env-mk-persist.mjs": { persistHelmServiceVarsMk: ... } },
//   });
//
//   test("сценарий 1", async () => {
//     const { makeCalls } = runWith(h, { answers: [true, false, ...] });
//     const { actionApply } = await import("../actions/apply.mjs");
//     await actionApply({ env: "local" });
//     // assert makeCalls
//   });

import { mock } from "node:test";

/**
 * @param {unknown[]} answers
 */
export function createScript(answers) {
  let idx = 0;
  const events = [];
  function next(kind, opts) {
    if (idx >= answers.length) {
      const tail = events
        .slice(-3)
        .map((e) => `${e.kind}(${JSON.stringify(e.message ?? "")})→${JSON.stringify(e.answer)}`)
        .join(", ");
      throw new Error(
        `prompt #${idx} (${kind}): сценарий исчерпан. Последние: ${tail || "(нет)"}; текущий opts.message=${JSON.stringify(opts?.message ?? "")}`,
      );
    }
    const a = answers[idx++];
    events.push({ kind, message: opts?.message, answer: a });
    return a;
  }
  return {
    next,
    events,
    get index() { return idx; },
    get remaining() { return answers.length - idx; },
  };
}

/**
 * Устанавливает моки io.mjs + lib/make.mjs один раз на файл. Привязывается
 * к hook `before` (импортируется из node:test). Поведение в каждом тесте
 * меняется через `runWith(h, { answers, makeReturns })`.
 *
 * @param {Function} beforeHook — функция before из node:test
 * @param {{ extraMocks?: Record<string, Record<string, unknown>> }} [opts]
 */
export function setupHarness(beforeHook, opts = {}) {
  const harness = {
    scriptRef: { current: null },
    makeCallsRef: { current: null },
    makeReturnsRef: { current: {} },
    extraMockState: {},
  };

  const noopLog = {
    step: () => {},
    success: () => {},
    error: () => {},
    info: () => {},
    warn: () => {},
    message: () => {},
  };

  beforeHook(() => {
    mock.module("../io.mjs", {
      namedExports: {
        select:      async (o) => harness.scriptRef.current.next("select", o),
        text:        async (o) => harness.scriptRef.current.next("text", o),
        multiselect: async (o) => harness.scriptRef.current.next("multiselect", o),
        confirm:     async (o) => harness.scriptRef.current.next("confirm", o),
        note:        () => {},
        log:         noopLog,
        intro:       () => {},
        outro:       () => {},
        cancel:      () => {},
        isCancel:    (v) => v === CANCEL_SYM,
      },
    });

    mock.module("../../lib/make.mjs", {
      namedExports: {
        runMake: async (target, mkOpts) => {
          harness.makeCallsRef.current?.push({
            target,
            env: { ...(mkOpts?.env || {}) },
            extraArgs: mkOpts?.extraArgs ?? [],
          });
          return { code: harness.makeReturnsRef.current[target] ?? 0 };
        },
        reportMakeExit: () => {},
      },
    });

    // Доп. модули — мокаем через ref, чтобы поведение меняли тесты.
    if (opts.extraMocks) {
      for (const [specifier, exports] of Object.entries(opts.extraMocks)) {
        // exports — это карта name → factory(harness)
        const dyn = {};
        harness.extraMockState[specifier] = dyn;
        const proxied = {};
        for (const [name, factory] of Object.entries(exports)) {
          dyn[name] = factory; // default
          proxied[name] = (...args) => dyn[name](...args);
        }
        mock.module(specifier, { namedExports: proxied });
      }
    }
  });

  return harness;
}

/**
 * Перед каждым тестом задать новый script + сбросить журнал runMake.
 * Возвращает живые ссылки на массив makeCalls и сам script (для events).
 *
 * @param {ReturnType<typeof setupHarness>} h
 * @param {{
 *   answers: unknown[],
 *   makeReturns?: Record<string, number>,
 *   extraMockOverrides?: Record<string, Record<string, Function>>,
 * }} opts
 */
export function runWith(h, { answers, makeReturns = {}, extraMockOverrides = {} }) {
  const script = createScript(answers);
  const makeCalls = [];
  h.scriptRef.current = script;
  h.makeCallsRef.current = makeCalls;
  h.makeReturnsRef.current = makeReturns;

  for (const [specifier, overrides] of Object.entries(extraMockOverrides)) {
    const dyn = h.extraMockState[specifier];
    if (!dyn) {
      throw new Error(`extraMockOverrides: модуль ${specifier} не объявлен в setupHarness({extraMocks})`);
    }
    for (const [name, fn] of Object.entries(overrides)) dyn[name] = fn;
  }

  return { script, makeCalls };
}

/** Символ для эмуляции "пользователь нажал Ctrl+C". */
export const CANCEL_SYM = Symbol("test-cancel");
