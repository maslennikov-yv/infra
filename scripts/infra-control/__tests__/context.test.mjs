// L1 — pure-unit тесты context.mjs. Изоляция через временный HOME,
// чтобы не трогать реальный `~/.cache/infra-tui/`.

import { test, describe, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

let realHome;
let tmpHome;
let context;

before(async () => {
  realHome = process.env.HOME;
  tmpHome = fs.mkdtempSync(path.join(os.tmpdir(), "infra-tui-test-"));
  process.env.HOME = tmpHome;
  // ВАЖНО: импортируем после подмены HOME, чтобы context.mjs увидел тестовый каталог.
  context = await import("../context.mjs");
});

after(() => {
  if (realHome !== undefined) process.env.HOME = realHome;
  else delete process.env.HOME;
  fs.rmSync(tmpHome, { recursive: true, force: true });
});

beforeEach(() => {
  // Очищаем кэш-каталог перед каждым тестом.
  const cacheDir = path.join(tmpHome, ".cache", "infra-tui");
  fs.rmSync(cacheDir, { recursive: true, force: true });
});

describe("loadCachedApp", () => {
  test("возвращает null если файла нет", () => {
    assert.equal(context.loadCachedApp("stage"), null);
  });

  test("возвращает null для пустого env", () => {
    assert.equal(context.loadCachedApp(""), null);
    assert.equal(context.loadCachedApp(undefined), null);
  });

  test("читает сохранённое значение", () => {
    context.saveCachedApp("stage", "myapp");
    assert.equal(context.loadCachedApp("stage"), "myapp");
  });

  test("возвращает null для пустого файла (whitespace only)", () => {
    const dir = path.join(tmpHome, ".cache", "infra-tui");
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, "last-app-x"), "   \n   ", "utf8");
    assert.equal(context.loadCachedApp("x"), null);
  });
});

describe("saveCachedApp", () => {
  test("создаёт каталог рекурсивно и пишет значение с newline", () => {
    context.saveCachedApp("local", "myapp");
    const file = path.join(tmpHome, ".cache", "infra-tui", "last-app-local");
    assert.equal(fs.readFileSync(file, "utf8"), "myapp\n");
  });

  test("trim'ит ведущие/хвостовые пробелы", () => {
    context.saveCachedApp("local", "  spacedapp  ");
    assert.equal(context.loadCachedApp("local"), "spacedapp");
  });

  test("пустое значение удаляет файл", () => {
    context.saveCachedApp("local", "x");
    assert.equal(context.loadCachedApp("local"), "x");
    context.saveCachedApp("local", "");
    assert.equal(context.loadCachedApp("local"), null);
  });

  test("очистка несуществующего файла — best-effort, без ошибок", () => {
    assert.doesNotThrow(() => context.saveCachedApp("nope", ""));
  });
});

describe("clearCachedApp", () => {
  test("то же что saveCachedApp(env, '')", () => {
    context.saveCachedApp("e", "v");
    context.clearCachedApp("e");
    assert.equal(context.loadCachedApp("e"), null);
  });
});

describe("ensureSessionShape", () => {
  test("подтягивает app из кэша если поле отсутствует", () => {
    context.saveCachedApp("stage", "cachedapp");
    const s = context.ensureSessionShape({ env: "stage" });
    assert.equal(s.app, "cachedapp");
  });

  test("сохраняет существующий app (даже null) без перезаписи", () => {
    context.saveCachedApp("stage", "cached");
    const s = context.ensureSessionShape({ env: "stage", app: null });
    assert.equal(s.app, null);
  });

  test("возвращает дефолт для не-объекта", () => {
    assert.deepEqual(context.ensureSessionShape(null), { env: "local", app: null });
    assert.deepEqual(context.ensureSessionShape("x"), { env: "local", app: null });
  });

  test("возвращает тот же объект (мутирует)", () => {
    const s = { env: "stage" };
    const r = context.ensureSessionShape(s);
    assert.equal(r, s);
  });
});

describe("setSessionApp", () => {
  test("устанавливает app в сессии и пишет в кэш", () => {
    const s = { env: "stage", app: null };
    context.setSessionApp(s, "newapp");
    assert.equal(s.app, "newapp");
    assert.equal(context.loadCachedApp("stage"), "newapp");
  });

  test("null/пустая строка очищают app и кэш", () => {
    context.saveCachedApp("stage", "x");
    const s = { env: "stage", app: "x" };
    context.setSessionApp(s, null);
    assert.equal(s.app, null);
    assert.equal(context.loadCachedApp("stage"), null);
  });
});

describe("setSessionEnv", () => {
  test("переключает env и перечитывает кэш для нового env", () => {
    context.saveCachedApp("stage", "appA");
    context.saveCachedApp("prod", "appB");
    const s = { env: "stage", app: "appA" };
    context.setSessionEnv(s, "prod");
    assert.equal(s.env, "prod");
    assert.equal(s.app, "appB");
  });

  test("для нового env без кэша — app становится null", () => {
    const s = { env: "stage", app: "appA" };
    context.setSessionEnv(s, "fresh-env");
    assert.equal(s.env, "fresh-env");
    assert.equal(s.app, null);
  });
});

describe("renderSessionHeader", () => {
  test("базовый формат без app", () => {
    assert.equal(
      context.renderSessionHeader({ env: "stage" }),
      "ENV: stage · APP: —",
    );
  });

  test("с app в сессии", () => {
    assert.equal(
      context.renderSessionHeader({ env: "stage", app: "myapp" }),
      "ENV: stage · APP: myapp",
    );
  });

  test("extras добавляются, null/пустое пропускается", () => {
    const h = context.renderSessionHeader(
      { env: "x", app: "y" },
      { kubeconfig: "ok", note: null, last: "" },
    );
    assert.equal(h, "ENV: x · APP: y · kubeconfig: ok");
  });

  test("session без env даёт '?'", () => {
    assert.equal(context.renderSessionHeader({}), "ENV: ? · APP: —");
  });
});

describe("getCacheDir", () => {
  test("возвращает путь под HOME", () => {
    assert.equal(context.getCacheDir(), path.join(tmpHome, ".cache", "infra-tui"));
  });
});
