// L2 — promptWithSuggestions: select из suggestions, fallback к text(),
// __manual__ и __clear__ пункты. Harness ловит kind+message; полную форму
// опций select не проверяем (доступно только в ручном прогоне), здесь —
// поведение возвращаемого значения.

import { test, describe, before } from "node:test";
import assert from "node:assert/strict";

import { setupHarness, runWith } from "./_harness.mjs";

const h = setupHarness(before);

describe("promptWithSuggestions", () => {
  test("пустой suggestions → text() fallback, возвращает введённую строку", async () => {
    const { script } = runWith(h, { answers: ["myapp"] });
    const { promptWithSuggestions } = await import("../prompts.mjs");
    const out = await promptWithSuggestions({
      message: "APP:",
      suggestions: [],
      requireValue: true,
    });
    assert.equal(out, "myapp");
    assert.equal(script.events[0].kind, "text");
  });

  test("непустой suggestions → select; выбор существующего возвращается as-is", async () => {
    const { script } = runWith(h, { answers: ["bot"] });
    const { promptWithSuggestions } = await import("../prompts.mjs");
    const out = await promptWithSuggestions({
      message: "APP:",
      suggestions: [
        { value: "bot", label: "bot", hint: "enabled" },
        { value: "mcp", label: "mcp", hint: "enabled" },
      ],
      sessionValue: "mcp",
      requireValue: true,
    });
    assert.equal(out, "bot");
    assert.equal(script.events[0].kind, "select");
  });

  test("__manual__ → следом открывается text(), оттуда и берётся итог", async () => {
    const { script } = runWith(h, { answers: ["__manual__", "newapp"] });
    const { promptWithSuggestions } = await import("../prompts.mjs");
    const out = await promptWithSuggestions({
      message: "APP:",
      suggestions: [{ value: "bot", label: "bot" }],
      requireValue: true,
    });
    assert.equal(out, "newapp");
    assert.equal(script.events.length, 2);
    assert.deepEqual(
      script.events.map((e) => e.kind),
      ["select", "text"],
    );
  });

  test("requireValue=false: __clear__ → null", async () => {
    runWith(h, { answers: ["__clear__"] });
    const { promptWithSuggestions } = await import("../prompts.mjs");
    const out = await promptWithSuggestions({
      message: "APP:",
      suggestions: [{ value: "bot", label: "bot" }],
      sessionValue: "bot",
      requireValue: false,
    });
    assert.equal(out, null);
  });

  test("__manual__ + пустой ввод при requireValue=false → null (очистка)", async () => {
    runWith(h, { answers: ["__manual__", ""] });
    const { promptWithSuggestions } = await import("../prompts.mjs");
    const out = await promptWithSuggestions({
      message: "APP:",
      suggestions: [{ value: "bot", label: "bot" }],
      sessionValue: "bot",
      requireValue: false,
    });
    assert.equal(out, null);
  });
});
