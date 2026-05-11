// L3 — happy path для wizardConfigureServices.
// Проверяет: запись политики в <env>.mk через persist/clear,
// корректные ENV-переменные diff, ветку отмены.

import { test, describe, before } from "node:test";
import assert from "node:assert/strict";

import { setupHarness, runWith } from "./_harness.mjs";

const h = setupHarness(before, {
  extraMocks: {
    "../../lib/env-mk-persist.mjs": {
      readHelmServiceVarsMk: () => ({
        path: "fake.mk",
        exists: true,
        enabledCsv: null,
        excludeCsv: null,
      }),
      persistHelmServiceVarsMk: () => ({ path: "fake.mk", created: false }),
      clearHelmServiceVarsMk: () => ({ path: "fake.mk", existed: true, changed: true }),
    },
  },
});

describe("wizardConfigureServices", () => {
  test("режим «весь набор»: clear + diff", async () => {
    const calls = { persist: [], clear: [] };
    const { makeCalls } = runWith(h, {
      answers: [
        "all",  // select mode
        true,   // confirm: «Очистить ENABLED_SERVICES и EXCLUDE_SERVICES?»
        true,   // confirm: «Показать helm diff?»
      ],
      extraMockOverrides: {
        "../../lib/env-mk-persist.mjs": {
          readHelmServiceVarsMk: () => ({
            path: "fake.mk", exists: true,
            enabledCsv: "postgres,redis", excludeCsv: null,
          }),
          persistHelmServiceVarsMk: (...a) => { calls.persist.push(a); return { path: "fake.mk", created: false }; },
          clearHelmServiceVarsMk: (...a) => { calls.clear.push(a); return { path: "fake.mk", existed: true, changed: true }; },
        },
      },
    });
    const { wizardConfigureServices } = await import("../wizards/configure-services.mjs");

    await wizardConfigureServices({ env: "local" });

    assert.equal(calls.clear.length, 1, "clearHelmServiceVarsMk вызван 1 раз");
    assert.equal(calls.persist.length, 0, "persist не должен вызываться в режиме all");
    assert.deepEqual(makeCalls.map((c) => c.target), ["diff"]);
    assert.deepEqual(makeCalls[0].env, { ENV: "local" });
  });

  test("режим «только указанные»: persist({enabledCsv}) + diff", async () => {
    const calls = { persist: [], clear: [] };
    const { makeCalls } = runWith(h, {
      answers: [
        "only",                  // mode
        ["postgres", "redis"],   // multiselect: какие оставить
        true,                    // confirm write
        true,                    // confirm diff
      ],
      extraMockOverrides: {
        "../../lib/env-mk-persist.mjs": {
          readHelmServiceVarsMk: () => ({
            path: "fake.mk", exists: false,
            enabledCsv: null, excludeCsv: null,
          }),
          persistHelmServiceVarsMk: (root, env, spec) => {
            calls.persist.push({ env, spec });
            return { path: `environments/${env}.mk`, created: true };
          },
          clearHelmServiceVarsMk: (...a) => { calls.clear.push(a); return { path: "fake.mk", existed: false, changed: false }; },
        },
      },
    });
    const { wizardConfigureServices } = await import("../wizards/configure-services.mjs");

    await wizardConfigureServices({ env: "stage" });

    assert.equal(calls.persist.length, 1);
    assert.deepEqual(calls.persist[0], { env: "stage", spec: { enabledCsv: "postgres,redis" } });
    assert.equal(calls.clear.length, 0);
    assert.deepEqual(makeCalls.map((c) => c.target), ["diff"]);
  });

  test("режим «кроме указанных»: persist({excludeCsv}), diff пропущен", async () => {
    const calls = { persist: [], clear: [] };
    const { makeCalls } = runWith(h, {
      answers: [
        "except",                // mode
        ["kafka", "clickhouse"], // multiselect: что исключить
        true,                    // confirm write
        false,                   // НЕ показывать diff
      ],
      extraMockOverrides: {
        "../../lib/env-mk-persist.mjs": {
          readHelmServiceVarsMk: () => ({
            path: "fake.mk", exists: true, enabledCsv: null, excludeCsv: null,
          }),
          persistHelmServiceVarsMk: (root, env, spec) => {
            calls.persist.push({ env, spec });
            return { path: `environments/${env}.mk`, created: false };
          },
          clearHelmServiceVarsMk: (...a) => { calls.clear.push(a); return { path: "fake.mk", existed: true, changed: false }; },
        },
      },
    });
    const { wizardConfigureServices } = await import("../wizards/configure-services.mjs");

    await wizardConfigureServices({ env: "prod" });

    assert.equal(calls.persist.length, 1);
    assert.deepEqual(calls.persist[0], { env: "prod", spec: { excludeCsv: "kafka,clickhouse" } });
    assert.deepEqual(makeCalls, []);
  });

  test("отмена режима — никаких записей и make-вызовов", async () => {
    const calls = { persist: [], clear: [] };
    const { makeCalls } = runWith(h, {
      answers: ["cancel"],
      extraMockOverrides: {
        "../../lib/env-mk-persist.mjs": {
          readHelmServiceVarsMk: () => ({ path: "fake.mk", exists: true, enabledCsv: null, excludeCsv: null }),
          persistHelmServiceVarsMk: (...a) => { calls.persist.push(a); return { path: "fake.mk", created: false }; },
          clearHelmServiceVarsMk: (...a) => { calls.clear.push(a); return { path: "fake.mk", existed: true, changed: false }; },
        },
      },
    });
    const { wizardConfigureServices } = await import("../wizards/configure-services.mjs");

    await wizardConfigureServices({ env: "local" });

    assert.equal(calls.persist.length, 0);
    assert.equal(calls.clear.length, 0);
    assert.deepEqual(makeCalls, []);
  });

  test("отказ от записи — persist/clear не вызываются", async () => {
    const calls = { persist: [], clear: [] };
    const { makeCalls } = runWith(h, {
      answers: [
        "only",          // mode
        ["postgres"],    // multiselect
        false,           // confirm write → нет
      ],
      extraMockOverrides: {
        "../../lib/env-mk-persist.mjs": {
          readHelmServiceVarsMk: () => ({ path: "fake.mk", exists: true, enabledCsv: null, excludeCsv: null }),
          persistHelmServiceVarsMk: (...a) => { calls.persist.push(a); return { path: "fake.mk", created: false }; },
          clearHelmServiceVarsMk: (...a) => { calls.clear.push(a); return { path: "fake.mk", existed: true, changed: false }; },
        },
      },
    });
    const { wizardConfigureServices } = await import("../wizards/configure-services.mjs");

    await wizardConfigureServices({ env: "local" });

    assert.equal(calls.persist.length, 0);
    assert.equal(calls.clear.length, 0);
    assert.deepEqual(makeCalls, []);
  });
});
