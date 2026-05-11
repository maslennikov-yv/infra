// L1 — тесты валидаторов (pure-функции). Защищают регекспы и текст ошибок
// от случайного редактирования.

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { validateAppName } from "../wizards/connect-app.mjs";
import { validateEnvName } from "../wizards/bootstrap-env.mjs";
import { validatePortNumber, validateBackendAddr } from "../settings/tcp.mjs";

describe("validateAppName", () => {
  test("принимает валидные имена", () => {
    for (const v of ["a", "myapp", "my-app", "my_app", "app1", "a1b2c3"]) {
      assert.equal(validateAppName(v), undefined, `должно быть валидно: ${v}`);
    }
  });

  test("пробелы по краям обрезаются", () => {
    assert.equal(validateAppName("  myapp  "), undefined);
  });

  test("отклоняет пустое", () => {
    assert.match(validateAppName(""), /обязательно/i);
    assert.match(validateAppName("   "), /обязательно/i);
    assert.match(validateAppName(null), /обязательно/i);
    assert.match(validateAppName(undefined), /обязательно/i);
  });

  test("отклоняет невалидные имена", () => {
    for (const v of ["1app", "App", "my.app", "my app", "-app", "_app", "app!"]) {
      const r = validateAppName(v);
      assert.ok(r && /латиница/i.test(r), `должно отклониться: ${v}`);
    }
  });
});

describe("validateEnvName", () => {
  test("принимает валидные имена", () => {
    for (const v of ["local", "prod", "stage", "dev-1", "env_2"]) {
      assert.equal(validateEnvName(v), undefined, `должно быть валидно: ${v}`);
    }
  });

  test("отклоняет пустое и невалидное", () => {
    assert.ok(validateEnvName(""));
    assert.ok(validateEnvName("Prod"));   // заглавные не разрешены
    assert.ok(validateEnvName("1env"));   // начинать с буквы
    assert.ok(validateEnvName("env.x"));
  });
});

describe("validatePortNumber", () => {
  test("принимает цифры", () => {
    for (const v of ["1", "22", "1883", "65535"]) {
      assert.equal(validatePortNumber(v), undefined);
    }
  });

  test("обрезает пробелы", () => {
    assert.equal(validatePortNumber("  1883  "), undefined);
  });

  test("отклоняет нецифры", () => {
    for (const v of ["", "abc", "1a", "1.5", "-1", "1 2"]) {
      assert.ok(validatePortNumber(v));
    }
  });
});

describe("validateBackendAddr", () => {
  test("принимает корректные ns/svc:port", () => {
    for (const v of [
      "mqtt/mosquitto:1883",
      "default/postgres:5432",
      "ns-1/svc-2:65535",
    ]) {
      assert.equal(validateBackendAddr(v), undefined, `должно быть валидно: ${v}`);
    }
  });

  test("отклоняет неверный формат", () => {
    for (const v of [
      "",
      "mqtt:1883",            // нет ns/
      "mqtt/mosquitto",       // нет :port
      "MQTT/mosquitto:1883",  // заглавные
      "ns_1/svc:1883",        // подчёркивание не разрешено
      "ns/svc:abc",           // порт не число
      "ns//svc:1883",         // двойной слэш
    ]) {
      assert.ok(validateBackendAddr(v), `должно отклониться: ${v}`);
    }
  });
});
