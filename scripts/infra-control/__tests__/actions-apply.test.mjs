// L3 — flow-тесты для actionApply ("Применить изменения").
// Проверяем что правильные ENV-переменные доходят до runMake.

import { test, describe, before } from "node:test";
import assert from "node:assert/strict";

import { setupHarness, runWith } from "./_harness.mjs";

const h = setupHarness(before, {
  extraMocks: {
    "../../lib/env-mk-persist.mjs": {
      persistHelmServiceVarsMk: () => ({ path: "fake", created: false }),
    },
  },
});

describe("actionApply", () => {
  test("весь набор, без флагов и без persist", async () => {
    const { makeCalls } = runWith(h, {
      answers: [
        true,   // confirm: use all services
        false,  // confirm: no exclude
        false,  // confirm: no SKIP_APPS_APPLY
        false,  // confirm: no APPS_APPLY_CONTINUE_ON_ERROR
      ],
    });
    const { actionApply } = await import("../actions/apply.mjs");

    await actionApply({ env: "local" });

    assert.equal(makeCalls.length, 1);
    assert.equal(makeCalls[0].target, "up");
    assert.deepEqual(makeCalls[0].env, { ENV: "local" });
  });

  test("подвыборка + exclude + persist=no", async () => {
    const persistCalls = [];
    const { makeCalls } = runWith(h, {
      answers: [
        false,                       // confirm: subset
        ["postgres", "redis"],       // multiselect: ENABLED_SERVICES
        true,                        // confirm: yes exclude
        ["kafka"],                   // multiselect: EXCLUDE_SERVICES
        false,                       // confirm: no SKIP_APPS_APPLY
        false,                       // confirm: no CONTINUE_ON_ERROR
        false,                       // confirm: no persist в <ENV>.mk
      ],
      extraMockOverrides: {
        "../../lib/env-mk-persist.mjs": {
          persistHelmServiceVarsMk: (root, env, spec) => {
            persistCalls.push({ env, spec });
            return { path: "fake", created: false };
          },
        },
      },
    });
    const { actionApply } = await import("../actions/apply.mjs");

    await actionApply({ env: "stage" });

    assert.equal(makeCalls.length, 1);
    assert.deepEqual(makeCalls[0].env, {
      ENV: "stage",
      ENABLED_SERVICES: "postgres,redis",
      EXCLUDE_SERVICES: "kafka",
    });
    assert.equal(persistCalls.length, 0, "persist отказан — не должен вызываться");
  });

  test("флаги SKIP_APPS_APPLY и APPS_APPLY_CONTINUE_ON_ERROR долетают", async () => {
    const { makeCalls } = runWith(h, {
      answers: [
        true,   // all
        false,  // no exclude
        true,   // SKIP_APPS_APPLY
        true,   // CONTINUE_ON_ERROR
      ],
    });
    const { actionApply } = await import("../actions/apply.mjs");

    await actionApply({ env: "prod" });

    assert.equal(makeCalls.length, 1);
    assert.deepEqual(makeCalls[0].env, {
      ENV: "prod",
      SKIP_APPS_APPLY: "1",
      APPS_APPLY_CONTINUE_ON_ERROR: "1",
    });
  });

  test("persist вызывается когда yes и есть выбор сервисов", async () => {
    const persistCalls = [];
    const { makeCalls } = runWith(h, {
      answers: [
        false,                  // subset
        ["postgres"],           // ENABLED_SERVICES
        false,                  // no exclude
        false,                  // no SKIP
        false,                  // no CONTINUE
        true,                   // YES persist
      ],
      extraMockOverrides: {
        "../../lib/env-mk-persist.mjs": {
          persistHelmServiceVarsMk: (root, env, spec) => {
            persistCalls.push({ env, spec });
            return { path: `environments/${env}.mk`, created: true };
          },
        },
      },
    });
    const { actionApply } = await import("../actions/apply.mjs");

    await actionApply({ env: "stage" });

    assert.equal(makeCalls.length, 1);
    assert.equal(persistCalls.length, 1);
    assert.deepEqual(persistCalls[0], {
      env: "stage",
      spec: { enabledCsv: "postgres" },
    });
  });
});
