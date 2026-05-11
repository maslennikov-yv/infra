// L1 — юнит-тесты для read/persist/clear helm service vars в <env>.mk.
// Работают на временном каталоге, не трогают реальный environments/.

import { test, describe, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import {
  readHelmServiceVarsMk,
  persistHelmServiceVarsMk,
  clearHelmServiceVarsMk,
} from "../../lib/env-mk-persist.mjs";

let tmpRoot;
const ENV = "test-env";

before(() => {
  tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "env-mk-persist-"));
  fs.mkdirSync(path.join(tmpRoot, "environments"));
});
after(() => {
  fs.rmSync(tmpRoot, { recursive: true, force: true });
});
beforeEach(() => {
  // Каждый тест начинает с чистого <env>.mk
  const p = path.join(tmpRoot, "environments", `${ENV}.mk`);
  if (fs.existsSync(p)) fs.unlinkSync(p);
});

describe("readHelmServiceVarsMk", () => {
  test("файла нет → exists=false, оба null", () => {
    const r = readHelmServiceVarsMk(tmpRoot, ENV);
    assert.equal(r.exists, false);
    assert.equal(r.enabledCsv, null);
    assert.equal(r.excludeCsv, null);
  });

  test("читает обе переменные", () => {
    fs.writeFileSync(
      path.join(tmpRoot, "environments", `${ENV}.mk`),
      "SSH_HOST ?= example.com\nENABLED_SERVICES ?= postgres,redis\nEXCLUDE_SERVICES ?= kafka\n",
    );
    const r = readHelmServiceVarsMk(tmpRoot, ENV);
    assert.equal(r.exists, true);
    assert.equal(r.enabledCsv, "postgres,redis");
    assert.equal(r.excludeCsv, "kafka");
  });

  test("пустое значение → null", () => {
    fs.writeFileSync(
      path.join(tmpRoot, "environments", `${ENV}.mk`),
      "ENABLED_SERVICES ?= \nEXCLUDE_SERVICES ?=\n",
    );
    const r = readHelmServiceVarsMk(tmpRoot, ENV);
    assert.equal(r.enabledCsv, null);
    assert.equal(r.excludeCsv, null);
  });
});

describe("persistHelmServiceVarsMk", () => {
  test("записывает ENABLED_SERVICES, удаляет EXCLUDE_SERVICES, сохраняет SSH_HOST", () => {
    fs.writeFileSync(
      path.join(tmpRoot, "environments", `${ENV}.mk`),
      "SSH_HOST ?= example.com\nEXCLUDE_SERVICES ?= old\n",
    );
    const r = persistHelmServiceVarsMk(tmpRoot, ENV, { enabledCsv: "postgres,redis" });
    assert.equal(r.created, false);
    const out = fs.readFileSync(r.path, "utf8");
    assert.match(out, /SSH_HOST \?= example\.com/);
    assert.match(out, /ENABLED_SERVICES \?= postgres,redis/);
    assert.doesNotMatch(out, /EXCLUDE_SERVICES/);
  });

  test("создаёт файл с одной переменной если его нет", () => {
    const r = persistHelmServiceVarsMk(tmpRoot, ENV, { excludeCsv: "kafka" });
    assert.equal(r.created, true);
    const out = fs.readFileSync(r.path, "utf8");
    assert.equal(out, "EXCLUDE_SERVICES ?= kafka\n");
  });

  test("без enabled/exclude — throw", () => {
    assert.throws(() => persistHelmServiceVarsMk(tmpRoot, ENV, {}));
  });
});

describe("clearHelmServiceVarsMk", () => {
  test("файла нет → existed=false, changed=false", () => {
    const r = clearHelmServiceVarsMk(tmpRoot, ENV);
    assert.equal(r.existed, false);
    assert.equal(r.changed, false);
  });

  test("обе переменные есть → удаляет, сохраняет остальное", () => {
    fs.writeFileSync(
      path.join(tmpRoot, "environments", `${ENV}.mk`),
      "SSH_HOST ?= example.com\nENABLED_SERVICES ?= postgres\nEXCLUDE_SERVICES ?= kafka\nKUBECONFIG ?= path\n",
    );
    const r = clearHelmServiceVarsMk(tmpRoot, ENV);
    assert.equal(r.existed, true);
    assert.equal(r.changed, true);
    const out = fs.readFileSync(r.path, "utf8");
    assert.match(out, /SSH_HOST \?= example\.com/);
    assert.match(out, /KUBECONFIG \?= path/);
    assert.doesNotMatch(out, /ENABLED_SERVICES/);
    assert.doesNotMatch(out, /EXCLUDE_SERVICES/);
  });

  test("переменных нет → changed=false, файл не трогаем", () => {
    fs.writeFileSync(
      path.join(tmpRoot, "environments", `${ENV}.mk`),
      "SSH_HOST ?= example.com\n",
    );
    const before = fs.readFileSync(path.join(tmpRoot, "environments", `${ENV}.mk`), "utf8");
    const r = clearHelmServiceVarsMk(tmpRoot, ENV);
    assert.equal(r.existed, true);
    assert.equal(r.changed, false);
    const after = fs.readFileSync(r.path, "utf8");
    assert.equal(after, before);
  });

  test("единственной переменной была ENABLED_SERVICES → файл становится пустым", () => {
    fs.writeFileSync(
      path.join(tmpRoot, "environments", `${ENV}.mk`),
      "ENABLED_SERVICES ?= postgres\n",
    );
    const r = clearHelmServiceVarsMk(tmpRoot, ENV);
    assert.equal(r.changed, true);
    const out = fs.readFileSync(r.path, "utf8");
    assert.equal(out, "");
  });
});
