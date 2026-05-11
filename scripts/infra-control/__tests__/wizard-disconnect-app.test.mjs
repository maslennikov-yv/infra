// L3 — happy path для wizardDisconnectApp.
// Проверяем последовательность вызовов и что MINIO_REMOVE_BUCKETS долетает.

import { test, describe, before } from "node:test";
import assert from "node:assert/strict";

import { setupHarness, runWith } from "./_harness.mjs";

const h = setupHarness(before, {
  extraMocks: {
    "../../lib/registry-yq.mjs": {
      patchRegistryEnabled: () => true,
      // Возвращаем тестовый набор, чтобы promptAppFromSession показал select
      // и принял "myapp" как одну из опций (а не уходил в text() fallback).
      listRegistryApps: () => [
        { name: "myapp", enabled: true, app_ns: "myapp" },
      ],
    },
  },
});

describe("wizardDisconnectApp", () => {
  test("happy path с drop в pg + minio (REMOVE_BUCKETS)", async () => {
    const patchCalls = [];
    const { makeCalls } = runWith(h, {
      answers: [
        "myapp",       // select: APP="myapp" (initialValue=session.app, promptAppFromSession)
        true,          // confirm: «Снять enabled у приложения в registry?»
        true,          // confirm: «Запустить apps-apply сейчас?»
        true,          // confirm: «Удалить учётки?»
        ["pg", "mn"],  // multiselect: движки для drop
        true,          // confirm: promptDangerous step 1
        true,          // confirm: promptDangerous step 2
        true,          // confirm: MINIO_REMOVE_BUCKETS=1
      ],
      extraMockOverrides: {
        "../../lib/registry-yq.mjs": {
          patchRegistryEnabled: (yqBin, appName, enabledBool) => {
            patchCalls.push({ appName, enabledBool });
            return true;
          },
        },
      },
    });
    const { wizardDisconnectApp } = await import("../wizards/disconnect-app.mjs");

    await wizardDisconnectApp({ env: "stage", app: "myapp" });

    // 1) registry patched
    assert.equal(patchCalls.length, 1);
    assert.deepEqual(patchCalls[0], { appName: "myapp", enabledBool: false });

    // 2) make calls в правильном порядке
    assert.deepEqual(
      makeCalls.map((c) => c.target),
      ["apps-apply", "pg-app-drop", "minio-app-drop"],
    );

    // 3) у drop'ов SKIP_CONFIRM=1
    assert.equal(makeCalls[1].env.SKIP_CONFIRM, "1");
    assert.equal(makeCalls[2].env.SKIP_CONFIRM, "1");
    assert.equal(makeCalls[1].env.APP, "myapp");
    assert.equal(makeCalls[2].env.APP, "myapp");

    // 4) у minio-app-drop — MINIO_REMOVE_BUCKETS=1
    assert.equal(makeCalls[2].env.MINIO_REMOVE_BUCKETS, "1");
    assert.equal(makeCalls[1].env.MINIO_REMOVE_BUCKETS, undefined);
  });

  test("отказ от drop — wizard выходит после apps-apply", async () => {
    const { makeCalls } = runWith(h, {
      answers: [
        "myapp",        // select: APP
        true,           // patch registry
        true,           // apps-apply
        false,          // НЕ удалять учётки
      ],
    });
    const { wizardDisconnectApp } = await import("../wizards/disconnect-app.mjs");

    await wizardDisconnectApp({ env: "stage", app: "myapp" });

    assert.deepEqual(makeCalls.map((c) => c.target), ["apps-apply"]);
  });

  test("отмена promptDangerous — make-drop не вызывается", async () => {
    const { makeCalls } = runWith(h, {
      answers: [
        "myapp",        // select: APP
        true,           // patch
        true,           // apps-apply
        true,           // да, удалять
        ["pg"],         // multiselect
        false,          // promptDangerous step 1 → нет
      ],
    });
    const { wizardDisconnectApp } = await import("../wizards/disconnect-app.mjs");

    await wizardDisconnectApp({ env: "stage", app: "myapp" });

    assert.deepEqual(makeCalls.map((c) => c.target), ["apps-apply"]);
  });
});
