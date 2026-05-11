// L1 — pure-unit тесты meta.mjs. Без IO, проверяем константы и функции-маппинги.

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import {
  HELM_SERVICES,
  ACCOUNT_SERVICES,
  DIAG_SERVICES,
  HELM_OPTIONS,
  DIAG_OPTIONS,
  ACCOUNT_OPTIONS,
  displayServiceName,
  helmTargetPrefix,
} from "../meta.mjs";
import { DATA_SERVICES } from "../../lib/data-services.mjs";

describe("сервисные множества", () => {
  test("HELM_SERVICES = DATA_SERVICES + 'netdata'", () => {
    assert.equal(HELM_SERVICES.length, DATA_SERVICES.length + 1);
    assert.ok(HELM_SERVICES.includes("netdata"));
    for (const s of DATA_SERVICES) assert.ok(HELM_SERVICES.includes(s), `нет ${s}`);
  });

  test("ACCOUNT_SERVICES не содержит netdata/monitoring", () => {
    assert.ok(!ACCOUNT_SERVICES.includes("netdata"));
    assert.ok(!ACCOUNT_SERVICES.includes("monitoring"));
  });

  test("ACCOUNT_SERVICES — все 6 движков", () => {
    assert.deepEqual(
      [...ACCOUNT_SERVICES].sort(),
      ["clickhouse", "kafka", "minio", "postgres", "rabbitmq", "redis"],
    );
  });

  test("DIAG_SERVICES = DATA_SERVICES + 'monitoring' (не 'netdata')", () => {
    assert.ok(DIAG_SERVICES.includes("monitoring"));
    assert.ok(!DIAG_SERVICES.includes("netdata"));
    assert.equal(DIAG_SERVICES.length, DATA_SERVICES.length + 1);
  });

  test("все множества заморожены (Object.freeze)", () => {
    assert.ok(Object.isFrozen(HELM_SERVICES));
    assert.ok(Object.isFrozen(ACCOUNT_SERVICES));
    assert.ok(Object.isFrozen(DIAG_SERVICES));
  });
});

describe("helmTargetPrefix", () => {
  test("netdata → monitoring", () => {
    assert.equal(helmTargetPrefix("netdata"), "monitoring");
  });

  test("остальные slug'и возвращаются без изменений", () => {
    for (const s of DATA_SERVICES) {
      assert.equal(helmTargetPrefix(s), s);
    }
  });
});

describe("displayServiceName", () => {
  test("маппит все известные id", () => {
    const cases = {
      postgres: "PostgreSQL",
      redis: "Redis",
      kafka: "Kafka",
      minio: "MinIO",
      clickhouse: "ClickHouse",
      rabbitmq: "RabbitMQ",
      netdata: "Netdata (мониторинг)",
      monitoring: "Netdata (мониторинг)",
    };
    for (const [id, want] of Object.entries(cases)) {
      assert.equal(displayServiceName(id), want, `id=${id}`);
    }
  });

  test("неизвестный id возвращается как есть", () => {
    assert.equal(displayServiceName("unknown-svc"), "unknown-svc");
  });
});

describe("OPTIONS массивы", () => {
  test("длины соответствуют исходным множествам", () => {
    assert.equal(HELM_OPTIONS.length, HELM_SERVICES.length);
    assert.equal(DIAG_OPTIONS.length, DIAG_SERVICES.length);
    assert.equal(ACCOUNT_OPTIONS.length, ACCOUNT_SERVICES.length);
  });

  test("у каждой опции есть value и label", () => {
    for (const opts of [HELM_OPTIONS, DIAG_OPTIONS, ACCOUNT_OPTIONS]) {
      for (const o of opts) {
        assert.ok(typeof o.value === "string" && o.value.length > 0);
        assert.ok(typeof o.label === "string" && o.label.length > 0);
      }
    }
  });

  test("value соответствует slug'ам исходного множества", () => {
    assert.deepEqual(
      HELM_OPTIONS.map((o) => o.value),
      [...HELM_SERVICES],
    );
    assert.deepEqual(
      ACCOUNT_OPTIONS.map((o) => o.value),
      [...ACCOUNT_SERVICES],
    );
  });
});
