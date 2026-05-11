// L2 — главный страж от опечаток. Все make-цели, которые TUI v2 вызывает
// через runTarget, должны существовать в корневом Makefile.
//
// Source of truth для динамических наборов берётся прямо из v2-модулей
// (ENGINE_PREFIX из accounts.mjs, STATEFUL из backup.mjs, ACCOUNT_SERVICES
// и DATA_SERVICES из meta.mjs) — это значит, что добавление нового движка
// автоматически попадает в тест.

import { test, describe, before } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { ACCOUNT_SERVICES } from "../meta.mjs";
import { DATA_SERVICES } from "../../lib/data-services.mjs";
import { ENGINES } from "../actions/accounts.mjs";
import { STATEFUL } from "../actions/backup.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(HERE, "..", "..", "..");
const MAKEFILE = path.join(REPO_ROOT, "Makefile");

/** Парсит Makefile и возвращает Set<string> известных целей. */
function parseMakefileTargets(src) {
  const targets = new Set();

  // 1) Строки .PHONY: foo bar baz \ (с продолжениями).
  //    Сшиваем подряд идущие \-строки, потом грепаем токены.
  const lines = src.split("\n");
  for (let i = 0; i < lines.length; i++) {
    if (!/^\.PHONY:/.test(lines[i])) continue;
    let chunk = lines[i].replace(/^\.PHONY:/, "");
    while (chunk.trimEnd().endsWith("\\") && i + 1 < lines.length) {
      chunk = chunk.replace(/\\\s*$/, " ") + lines[++i];
    }
    for (const tok of chunk.split(/\s+/)) {
      if (tok && /^[a-zA-Z][a-zA-Z0-9_-]*$/.test(tok)) targets.add(tok);
    }
  }

  // 2) Все строки вида `^target:` (без =, без двоеточия в имени).
  //    Это покрывает цели, которые могли быть не объявлены в .PHONY.
  for (const line of lines) {
    const m = /^([a-zA-Z][a-zA-Z0-9_-]+):(?!=)/.exec(line);
    if (m) targets.add(m[1]);
  }

  // 3) Static-pattern targets: `$(addsuffix -verify,$(SERVICES)):` etc.
  //    Извлекаем SERVICES (из определения SERVICES := ...) и для каждого
  //    суффикса разворачиваем имена.
  const svcMatch = /^SERVICES\s*:?=\s*([^\n]+)/m.exec(src);
  const SERVICES = svcMatch
    ? svcMatch[1].trim().split(/\s+/).filter(Boolean)
    : [];
  const suffixRe = /\$\(addsuffix\s+-([a-zA-Z][a-zA-Z0-9_-]*),\s*\$\(SERVICES\)\):/g;
  let m;
  while ((m = suffixRe.exec(src))) {
    const suffix = m[1];
    for (const s of SERVICES) targets.add(`${s}-${suffix}`);
  }

  return targets;
}

let TARGETS;

before(() => {
  const src = fs.readFileSync(MAKEFILE, "utf8");
  TARGETS = parseMakefileTargets(src);
});

/** Захардкоженный список всех явных целей runTarget(s, "name", ...) в TUI v2.
 *  Извлекался grep'ом; при добавлении новой явной цели в TUI — добавлять сюда. */
const STATIC_TARGETS = [
  // actions/apply.mjs, actions/diff.mjs, actions/accounts.mjs (apps-apply)
  "up", "diff", "apps-apply", "apps-merge-print",
  // actions/status.mjs
  "doctor", "status", "top-totals",
  "monitoring-events", "monitoring-pod-events", "monitoring-describe-pod",
  // actions/backup.mjs
  "backup-all", "env-backup", "env-restore",
  // actions/accounts.mjs (нестандартные)
  "pg-app-psql", "minio-app-append",
  // actions/accounts.mjs — kafka topics
  "kafka-topic-create", "kafka-topic-alter", "kafka-topic-describe", "kafka-topic-list",
  // wizards/connect-app.mjs
  "apps-conf-template", "apps-src-clone", "app-local-src-hostpath-mount",
  // wizards/disconnect-app.mjs (apps-apply уже есть)
  // wizards/bootstrap-env.mjs
  "env-new", "microk8s-setup", "kubeconfig-fetch", "kubeconfig-microk8s-local",
  "images-save", "images-push", "images-push-remote",
  // settings/environment.mjs
  "kubeconfig-info", "ssh", "microk8s-uninstall", "kafka-bootstrap", "down",
  // settings/tcp.mjs
  "k8s-port-expose-show", "k8s-port-expose-diff",
  "k8s-port-expose-apply", "k8s-port-expose-patch",
  // settings/charts.mjs
  "check-updates",
];

describe("парсер Makefile", () => {
  test("находит хотя бы 30 целей", () => {
    assert.ok(TARGETS.size >= 30, `найдено ${TARGETS.size}`);
  });

  test("распознаёт несколько якорных целей (sanity парсера)", () => {
    for (const t of ["up", "down", "diff", "doctor", "status", "env-new", "apps-apply"]) {
      assert.ok(TARGETS.has(t), `парсер пропустил ${t}`);
    }
  });
});

describe("явные make-цели TUI существуют в Makefile", () => {
  for (const t of STATIC_TARGETS) {
    test(t, () => {
      assert.ok(TARGETS.has(t), `Makefile не содержит цель "${t}"`);
    });
  }
});

describe("динамические цели по движкам", () => {
  const SUFFIXES = ["app-create", "app-show-creds", "app-verify", "app-drop"];
  for (const { prefix } of ENGINES) {
    for (const suffix of SUFFIXES) {
      const target = `${prefix}-${suffix}`;
      test(target, () => {
        assert.ok(TARGETS.has(target), `Makefile не содержит "${target}"`);
      });
    }
  }
});

describe("backup/restore цели по STATEFUL", () => {
  for (const s of STATEFUL) {
    test(`${s.value}: ${s.backup} + ${s.restore}`, () => {
      assert.ok(TARGETS.has(s.backup), `нет ${s.backup}`);
      assert.ok(TARGETS.has(s.restore), `нет ${s.restore}`);
    });
  }
});

describe("logs/shell для data-сервисов и netdata", () => {
  for (const s of DATA_SERVICES) {
    for (const kind of ["logs", "shell"]) {
      test(`${s}-${kind}`, () => {
        assert.ok(TARGETS.has(`${s}-${kind}`), `нет ${s}-${kind}`);
      });
    }
  }
  for (const t of ["monitoring-logs", "monitoring-port-forward", "monitoring-status"]) {
    test(t, () => {
      assert.ok(TARGETS.has(t), `нет ${t}`);
    });
  }
});

describe("verify/check-updates для всех data-сервисов", () => {
  for (const s of ACCOUNT_SERVICES) {
    test(`${s}-verify`, () => {
      assert.ok(TARGETS.has(`${s}-verify`), `нет ${s}-verify`);
    });
    test(`${s}-check-updates`, () => {
      assert.ok(TARGETS.has(`${s}-check-updates`), `нет ${s}-check-updates`);
    });
  }
});

describe("консистентность ENGINES", () => {
  test("ровно 6 движков, как в ACCOUNT_SERVICES", () => {
    // ENGINES содержит slug'и для make-целей (pg для postgres);
    // имена слегка отличаются от ACCOUNT_SERVICES (postgres), поэтому
    // сравниваем только количество, а покрытие make-целей проверено выше.
    assert.equal(ENGINES.length, ACCOUNT_SERVICES.length);
  });

  test("у каждого движка key, prefix, label — непустые строки", () => {
    for (const e of ENGINES) {
      for (const f of ["key", "prefix", "label"]) {
        assert.ok(typeof e[f] === "string" && e[f].length > 0, `пустой ${f} у ${JSON.stringify(e)}`);
      }
    }
  });

  test("key'и уникальны", () => {
    const keys = ENGINES.map((e) => e.key);
    assert.equal(new Set(keys).size, keys.length);
  });
});
