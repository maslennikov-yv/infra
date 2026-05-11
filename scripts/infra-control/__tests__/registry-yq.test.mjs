// L1 — listRegistryApps: парсинг apps/registry.yaml через yq.
// Использует встроенный .tools/yq-mikefarah; временные файлы — в os.tmpdir().

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { resolveYq } from "../../lib/repo.mjs";
import { listRegistryApps } from "../../lib/registry-yq.mjs";

function writeTmpYaml(content) {
  const f = path.join(os.tmpdir(), `infra-tui-registry-${Date.now()}-${Math.random().toString(36).slice(2)}.yaml`);
  fs.writeFileSync(f, content);
  return f;
}

describe("listRegistryApps", () => {
  test("несуществующий файл → []", () => {
    const apps = listRegistryApps(resolveYq(), "/no/such/path/registry.yaml");
    assert.deepEqual(apps, []);
  });

  test("валидный реестр: enabled/disabled + app_ns", () => {
    const f = writeTmpYaml(`apps:
  - name: alpha
    enabled: true
    app_ns: alpha
  - name: beta
    enabled: false
    app_ns: beta-ns
  - name: gamma
    enabled: true
`);
    try {
      const apps = listRegistryApps(resolveYq(), f);
      assert.deepEqual(apps, [
        { name: "alpha", enabled: true, app_ns: "alpha" },
        { name: "beta", enabled: false, app_ns: "beta-ns" },
        { name: "gamma", enabled: true, app_ns: null },
      ]);
    } finally {
      fs.rmSync(f, { force: true });
    }
  });

  test("пустой apps → []", () => {
    const f = writeTmpYaml("apps: []\n");
    try {
      assert.deepEqual(listRegistryApps(resolveYq(), f), []);
    } finally {
      fs.rmSync(f, { force: true });
    }
  });

  test("битый yaml → []", () => {
    const f = writeTmpYaml("apps:\n  - name: x\n   bad-indent: y\n");
    try {
      assert.deepEqual(listRegistryApps(resolveYq(), f), []);
    } finally {
      fs.rmSync(f, { force: true });
    }
  });

  test("запись без name → отфильтрована", () => {
    const f = writeTmpYaml(`apps:
  - name: ok
    enabled: true
  - enabled: true
  - name: ""
    enabled: true
`);
    try {
      const apps = listRegistryApps(resolveYq(), f);
      assert.deepEqual(apps.map((a) => a.name), ["ok"]);
    } finally {
      fs.rmSync(f, { force: true });
    }
  });
});
