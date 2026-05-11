// L2 — динамические импорты всех модулей TUI v2 + структурная проверка ACTIONS.
// Ловит сломанные специфайеры и удалённые экспорты на этапе загрузки.

import { test, describe } from "node:test";
import assert from "node:assert/strict";

const MODULES = [
  "../io.mjs",
  "../main.mjs",
  "../context.mjs",
  "../meta.mjs",
  "../prompts.mjs",
  "../actions/apply.mjs",
  "../actions/diff.mjs",
  "../actions/status.mjs",
  "../actions/accounts.mjs",
  "../actions/backup.mjs",
  "../wizards/connect-app.mjs",
  "../wizards/disconnect-app.mjs",
  "../wizards/bootstrap-env.mjs",
  "../settings/environment.mjs",
  "../settings/tcp.mjs",
  "../settings/charts.mjs",
];

describe("ESM импорты всех модулей TUI v2", () => {
  for (const m of MODULES) {
    test(m, async () => {
      const mod = await import(m);
      assert.ok(mod, `${m} вернул falsy`);
    });
  }
});

describe("структура ACTIONS из main.mjs", () => {
  test("экспортируется массив", async () => {
    const { ACTIONS } = await import("../main.mjs");
    assert.ok(Array.isArray(ACTIONS));
    assert.ok(ACTIONS.length >= 10, "минимум 10 пунктов");
  });

  test("уникальные value", async () => {
    const { ACTIONS } = await import("../main.mjs");
    const values = ACTIONS.map((a) => a.value);
    const uniq = new Set(values);
    assert.equal(uniq.size, values.length, `дубликаты: ${values.filter((v, i) => values.indexOf(v) !== i)}`);
  });

  test("у каждого пункта есть label", async () => {
    const { ACTIONS } = await import("../main.mjs");
    for (const a of ACTIONS) {
      assert.ok(typeof a.label === "string" && a.label.length > 0, `пустой label у ${a.value}`);
    }
  });

  test("последний пункт — exit", async () => {
    const { ACTIONS } = await import("../main.mjs");
    assert.equal(ACTIONS.at(-1).value, "exit");
  });

  test("обязательные value присутствуют", async () => {
    const { ACTIONS } = await import("../main.mjs");
    const required = [
      "apply", "diff", "status", "accts",
      "wiz_connect", "wiz_disconnect", "wiz_bootstrap",
      "backup",
      "set_env", "set_tcp", "set_charts",
      "session", "exit",
    ];
    const values = ACTIONS.map((a) => a.value);
    for (const r of required) {
      assert.ok(values.includes(r), `нет пункта "${r}" в ACTIONS`);
    }
  });
});
