// L3 — flow-тесты для settingsTcp::patchFlow.
// Проверяем что параметры маршрута/порта правильно мапятся в env.

import { test, describe, before } from "node:test";
import assert from "node:assert/strict";

import { setupHarness, runWith } from "./_harness.mjs";

const h = setupHarness(before);

describe("settingsTcp::patchFlow", () => {
  test("TCP: добавление маршрута", async () => {
    const { makeCalls } = runWith(h, {
      answers: [
        "patch",                  // главное меню → patch
        "tcp",                    // LAYER
        "1883",                   // HOST_PORT
        false,                    // confirm: НЕ удалять (значит BACKEND спросится)
        "mqtt/mosquitto:1883",    // BACKEND
        "",                       // DRY_RUN: off
        "back",                   // выход из подменю
      ],
    });
    const { settingsTcp } = await import("../settings/tcp.mjs");

    await settingsTcp({ env: "prod" });

    assert.equal(makeCalls.length, 1);
    assert.equal(makeCalls[0].target, "k8s-port-expose-patch");
    assert.deepEqual(makeCalls[0].env, {
      ENV: "prod",
      LAYER: "tcp",
      HOST_PORT: "1883",
      BACKEND: "mqtt/mosquitto:1883",
    });
  });

  test("hostport: OP=add с CONTAINER_PORT и PORT_NAME", async () => {
    const { makeCalls } = runWith(h, {
      answers: [
        "patch",       // patchFlow
        "hostport",    // LAYER
        "1883",        // HOST_PORT
        "add",         // OP
        "1883",        // CONTAINER_PORT
        "mqtt",        // PORT_NAME
        "",            // PROTO (пусто — не передаём)
        "",            // DRY_RUN off
        "back",
      ],
    });
    const { settingsTcp } = await import("../settings/tcp.mjs");

    await settingsTcp({ env: "prod" });

    assert.equal(makeCalls.length, 1);
    assert.deepEqual(makeCalls[0].env, {
      ENV: "prod",
      LAYER: "hostport",
      HOST_PORT: "1883",
      OP: "add",
      CONTAINER_PORT: "1883",
      PORT_NAME: "mqtt",
    });
  });

  test("TCP: удаление маршрута (RM=1 без BACKEND)", async () => {
    const { makeCalls } = runWith(h, {
      answers: [
        "patch",
        "tcp",
        "1883",
        true,          // confirm: УДАЛИТЬ маршрут
        "",            // DRY_RUN off
        "back",
      ],
    });
    const { settingsTcp } = await import("../settings/tcp.mjs");

    await settingsTcp({ env: "stage" });

    assert.equal(makeCalls.length, 1);
    assert.deepEqual(makeCalls[0].env, {
      ENV: "stage",
      LAYER: "tcp",
      HOST_PORT: "1883",
      RM: "1",
    });
    assert.equal(makeCalls[0].env.BACKEND, undefined);
  });

  test("DRY_RUN=server долетает", async () => {
    const { makeCalls } = runWith(h, {
      answers: [
        "patch",
        "tcp",
        "1883",
        false,
        "ns/svc:1883",
        "server",   // DRY_RUN
        "back",
      ],
    });
    const { settingsTcp } = await import("../settings/tcp.mjs");

    await settingsTcp({ env: "local" });

    assert.equal(makeCalls[0].env.DRY_RUN, "server");
  });
});
