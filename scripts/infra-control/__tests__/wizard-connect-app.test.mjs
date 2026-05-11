// L3 — happy path для wizardConnectApp.
// Внутри использует fs.existsSync(apps/conf/<app>/) — используем заведомо
// несуществующее имя, чтобы поток шёл по ветке "alreadyExists=false".

import { test, describe, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { REPO_ROOT } from "../../lib/repo.mjs";
import { setupHarness, runWith } from "./_harness.mjs";

const TEST_APP = "test-no-such-app-12345";
const TEST_DIR = path.join(REPO_ROOT, "apps", "conf", TEST_APP);

// Изолируем HOME, чтобы setSessionApp не писал в реальный кэш пользователя.
let realHome;
let tmpHome;
before(() => {
  realHome = process.env.HOME;
  tmpHome = fs.mkdtempSync(path.join(os.tmpdir(), "infra-tui-test-"));
  process.env.HOME = tmpHome;
});
after(() => {
  if (realHome !== undefined) process.env.HOME = realHome;
  else delete process.env.HOME;
  fs.rmSync(tmpHome, { recursive: true, force: true });
});

const h = setupHarness(before, {
  extraMocks: {
    "../../configure-infra.mjs": {
      runConfigure: async () => {},  // no-op в тестах
    },
  },
});

// Гарантируем что каталог не существует — это инвариант happy-path-ветки.
if (fs.existsSync(TEST_DIR)) {
  throw new Error(`Тестовое окружение: apps/conf/${TEST_APP}/ существует — удалите перед прогоном`);
}

describe("wizardConnectApp", () => {
  test("happy path: template → edit → skip configurator → merge → apply → no clone/hostpath", async () => {
    const { makeCalls } = runWith(h, {
      answers: [
        // 1. text APP
        TEST_APP,
        // 2. confirm "Создать шаблон через apps-conf-template?" (default true для нового)
        true,
        // 3. confirm "Файл отредактирован — продолжать?" (default true)
        true,
        // 4. confirm "Запустить конфигуратор сейчас?" (default false)
        false,
        // 5. confirm "Показать итоговый merge?" (default true)
        true,
        // 6. confirm "Запустить apps-apply сейчас?" (default true)
        true,
        //   promptServicesSelection: confirm(all=yes)
        true,
        //   confirm(exclude=no)
        false,
        //   confirm(continue on error=no)
        false,
        // 7a. confirm "Клонировать репозиторий?" (default false)
        false,
        // 7b. (для ENV != local clone-вопрос и всё)
      ],
    });
    const { wizardConnectApp } = await import("../wizards/connect-app.mjs");

    await wizardConnectApp({ env: "stage", app: null });

    // Ожидаемая последовательность make-целей.
    assert.deepEqual(
      makeCalls.map((c) => c.target),
      ["apps-conf-template", "apps-merge-print", "apps-apply"],
    );
    assert.equal(makeCalls[0].env.APP, TEST_APP);
    assert.equal(makeCalls[0].env.SKIP_REGISTRY, undefined);
    assert.equal(makeCalls[2].env.ENV, "stage");
  });

  test("skip template — wizard остановлен после неудачи (логика 'если apps-conf-template ok'); шаг 2 без template", async () => {
    // При отказе от template wizard продолжает (без runMake apps-conf-template).
    const { makeCalls } = runWith(h, {
      answers: [
        TEST_APP,         // APP
        false,            // confirm template? NO
        true,             // edit?
        false,            // configurator?
        false,            // merge?
        false,            // apps-apply?
        false,            // clone?
      ],
    });
    const { wizardConnectApp } = await import("../wizards/connect-app.mjs");

    await wizardConnectApp({ env: "stage", app: null });

    // Без template и apps-apply журнал должен быть пуст.
    assert.deepEqual(makeCalls, []);
  });

  test("ENV=local: задаёт вопрос hostpath после clone", async () => {
    const { makeCalls } = runWith(h, {
      answers: [
        TEST_APP,
        false,    // template
        true,     // edit
        false,    // configurator
        false,    // merge
        false,    // apps-apply
        false,    // clone
        false,    // hostpath (только при ENV=local)
      ],
    });
    const { wizardConnectApp } = await import("../wizards/connect-app.mjs");

    await wizardConnectApp({ env: "local", app: null });

    assert.deepEqual(makeCalls, []);
  });
});
