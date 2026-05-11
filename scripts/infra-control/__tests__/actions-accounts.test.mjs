// L3 — flow-тесты для actionAccounts ("Учётки и топики"). Проверяем
// маршрутизацию по движкам и параметры в env.

import { test, describe, before } from "node:test";
import assert from "node:assert/strict";

import { setupHarness, runWith } from "./_harness.mjs";

const h = setupHarness(before);

describe("actionAccounts", () => {
  test("pg → show: APP из сессии, цель pg-app-show-creds", async () => {
    const { makeCalls } = runWith(h, {
      answers: [
        "myapp",        // select: APP из реестра (initialValue=session.app)
        "pg",           // select: engine
        "show",         // select: action
        "back",         // select: out of engine menu
        "back",         // select: out of accounts main
      ],
    });
    const { actionAccounts } = await import("../actions/accounts.mjs");

    await actionAccounts({ env: "stage", app: "myapp" });

    assert.equal(makeCalls.length, 1);
    assert.equal(makeCalls[0].target, "pg-app-show-creds");
    assert.deepEqual(makeCalls[0].env, { ENV: "stage", APP: "myapp" });
  });

  test("minio → create с bucket и ACCESS_MODE", async () => {
    const { makeCalls } = runWith(h, {
      answers: [
        "myapp",         // select: APP
        "mn",            // engine MinIO
        "create",        // action
        "",              // text APP_NS (пусто — не передаём)
        "mybucket",      // text BUCKET
        "private_rw",    // select ACCESS_MODE
        "",              // text APP_PUBLIC_ENDPOINT
        "back",          // select: out of engine menu
        "back",          // select: out of accounts main
      ],
    });
    const { actionAccounts } = await import("../actions/accounts.mjs");

    await actionAccounts({ env: "local", app: "myapp" });

    assert.equal(makeCalls.length, 1);
    assert.equal(makeCalls[0].target, "minio-app-create");
    assert.deepEqual(makeCalls[0].env, {
      ENV: "local",
      APP: "myapp",
      BUCKET: "mybucket",
      ACCESS_MODE: "private_rw",
    });
  });

  test("drop отменён: первый confirm в promptDangerous = false → make не вызывается", async () => {
    const { makeCalls } = runWith(h, {
      answers: [
        "myapp",        // select: APP
        "pg",           // engine
        "drop",         // action
        false,          // promptDangerous step 1: «Продолжить?» → нет
        "back",         // select: out of engine menu
        "back",         // select: out of accounts main
      ],
    });
    const { actionAccounts } = await import("../actions/accounts.mjs");

    await actionAccounts({ env: "stage", app: "myapp" });

    assert.equal(makeCalls.length, 0, "drop отменён → make не вызывается");
  });
});
