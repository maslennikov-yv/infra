#!/usr/bin/env node
// Интерактивное заполнение apps/conf/<APP>/ через app-conf-set.sh (как AI-Lab configure.mjs).

import { randomBytes } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import { resolve as pathResolve } from "node:path";

import {
  intro,
  outro,
  cancel,
  isCancel,
  select,
  multiselect,
  text,
  password,
  note,
  log,
  confirm,
} from "./lib/clack-narrow.mjs";

import { patchRegistryEnabled } from "./lib/registry-yq.mjs";

import {
  REPO_ROOT,
  resolveYq,
  REGISTRY_PATH,
  APP_CONF_SET,
  APPS_CONF_TEMPLATE,
  APPS_SRC,
  APPS_SRC_CLONE,
} from "./lib/repo.mjs";
import { DATA_SERVICES } from "./lib/data-services.mjs";
import { HELP_VALUE, MENU_HELP } from "./infra-control/menu-hints.mjs";
import {
  pickSessionEnvInteractive,
} from "./lib/session-env-picker.mjs";

const hex = (n) => randomBytes(n).toString("hex");

const ensure = (value) => {
  if (isCancel(value)) {
    cancel("Отменено.");
    process.exit(0);
  }
  return value;
};

function yamlEscape(s) {
  return String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

function maskShort(s) {
  const t = String(s);
  if (t.length <= 4) return "••••";
  return `${t.slice(0, 2)}…${t.slice(-2)}`;
}

function listAppNames(yqBin) {
  const r = spawnSync(yqBin, ["-r", ".apps[].name", REGISTRY_PATH], {
    encoding: "utf8",
  });
  if (r.status !== 0) {
    throw new Error(r.stderr || `yq failed (${r.status})`);
  }
  return r.stdout
    .split("\n")
    .map((x) => x.trim())
    .filter(Boolean);
}

function readRegistryAppMeta(yqBin, appName) {
  const r = spawnSync(
    yqBin,
    ["-o", "json", ".apps[] | select(.name == strenv(APPNAME))", REGISTRY_PATH],
    {
      encoding: "utf8",
      env: { ...process.env, APPNAME: appName },
    },
  );
  if (r.status !== 0) throw new Error(r.stderr || "yq registry lookup failed");
  const line = r.stdout.trim();
  if (!line || line === "null") return null;
  return JSON.parse(line);
}

/** @returns {string|null} сообщение об ошибке или null если ок (пустая строка — ок) */
function validateRepoUrl(u) {
  const s = String(u || "").trim();
  if (!s) return null;
  if (
    /^https:\/\//i.test(s) ||
    /^http:\/\//i.test(s) ||
    /^git@/i.test(s) ||
    /^ssh:\/\//i.test(s)
  ) {
    return null;
  }
  return "Укажите URL вида https://, http://, git@… или ssh://";
}

function patchRegistrySource(yqBin, appName, repoUrlTrimmed, branchTrimmed) {
  const envBase = { ...process.env, APPNAME: appName };
  if (!repoUrlTrimmed) {
    const r1 = spawnSync(
      yqBin,
      ["-i", "del(.apps[] | select(.name == strenv(APPNAME)) | .repo_url)", REGISTRY_PATH],
      { encoding: "utf8", env: envBase },
    );
    if (r1.status !== 0) return false;
    const r2 = spawnSync(
      yqBin,
      ["-i", "del(.apps[] | select(.name == strenv(APPNAME)) | .repo_branch)", REGISTRY_PATH],
      { encoding: "utf8", env: envBase },
    );
    return r2.status === 0;
  }

  const envUrl = { ...envBase, REPOURL: repoUrlTrimmed };
  let r = spawnSync(
    yqBin,
    [
      "-i",
      "(.apps[] | select(.name == strenv(APPNAME))).repo_url = strenv(REPOURL)",
      REGISTRY_PATH,
    ],
    { encoding: "utf8", env: envUrl },
  );
  if (r.status !== 0) return false;

  if (branchTrimmed) {
    r = spawnSync(
      yqBin,
      [
        "-i",
        "(.apps[] | select(.name == strenv(APPNAME))).repo_branch = strenv(REPOBRANCH)",
        REGISTRY_PATH,
      ],
      { encoding: "utf8", env: { ...envBase, REPOBRANCH: branchTrimmed } },
    );
  } else {
    r = spawnSync(
      yqBin,
      ["-i", "del(.apps[] | select(.name == strenv(APPNAME)) | .repo_branch)", REGISTRY_PATH],
      { encoding: "utf8", env: envBase },
    );
  }
  return r.status === 0;
}

function readAppsJson(yqBin) {
  const r = spawnSync(yqBin, ["-o", "json", ".apps", REGISTRY_PATH], {
    encoding: "utf8",
  });
  if (r.status !== 0) {
    throw new Error(r.stderr || "yq .apps failed");
  }
  const raw = r.stdout.trim();
  if (!raw || raw === "null") return [];
  const data = JSON.parse(raw);
  return Array.isArray(data) ? data : [];
}

/** @returns {string|undefined} */
function validateAppNs(v) {
  const t = String(v ?? "").trim();
  if (!t) return "app_ns не может быть пустым";
  if (t.length > 63) return "app_ns не длиннее 63 символов (DNS-label)";
  if (!/^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/.test(t)) {
    return "app_ns: строчные буквы, цифры и дефис (как имя Kubernetes namespace)";
  }
  return undefined;
}

/** Пустая строка — ок (удалить redis_db); иначе 0..127. @returns {string|undefined} */
function validateRedisDbField(v) {
  const raw = String(v ?? "").trim();
  if (!raw) return undefined;
  if (!/^\d+$/.test(raw)) return "redis_db: целое число 0..127 или пусто";
  const n = parseInt(raw, 10);
  if (n < 0 || n > 127) return "redis_db: допустимо 0..127 или пусто";
  return undefined;
}

/** @returns {string|null} */
function duplicateEnabledAppNamesConflict(apps) {
  /** @type {Record<string, number>} */
  const counts = {};
  for (const a of apps) {
    if (!a || a.enabled !== true) continue;
    const name = String(a.name ?? "").trim();
    if (!name) continue;
    counts[name] = (counts[name] ?? 0) + 1;
  }
  const dup = Object.entries(counts).find(([, n]) => n > 1);
  return dup ? `Несколько строк enabled: true с name «${dup[0]}».` : null;
}

/**
 * @param {unknown[]} apps
 * @param {string} appName
 * @param {{
 *   enabled: boolean,
 *   app_ns: string,
 *   clearRedisDb: boolean,
 *   redis_db?: number,
 * }} draft
 */
function buildRegistryDraftApps(apps, appName, draft) {
  return apps.map((e) => {
    if (!e || typeof e !== "object") return e;
    const row = /** @type {{ name?: string }} */ (e);
    if (row.name !== appName) return e;
    /** @type {Record<string, unknown>} */
    const copy = { ...(/** @type {object} */ (e)), enabled: draft.enabled, app_ns: draft.app_ns };
    if (draft.clearRedisDb) delete copy.redis_db;
    else copy.redis_db = draft.redis_db;
    return copy;
  });
}

/**
 * @param {unknown[]} apps
 * @param {string} appName
 * @param {{
 *   enabled: boolean,
 *   app_ns: string,
 *   clearRedisDb: boolean,
 *   redis_db?: number,
 * }} draft
 * @returns {string|null}
 */
function simulateRegistryPatchesError(apps, appName, draft) {
  if (!apps.some((x) => x && typeof x === "object" && (/** @type {{name?:string}} */ (x)).name === appName)) {
    return `В registry нет приложения «${appName}».`;
  }
  const nsErr = validateAppNs(draft.app_ns);
  if (nsErr) return nsErr;
  return duplicateEnabledAppNamesConflict(buildRegistryDraftApps(apps, appName, draft));
}

function patchRegistryAppNs(yqBin, appName, appNsTrimmed) {
  const r = spawnSync(
    yqBin,
    [
      "-i",
      "(.apps[] | select(.name == strenv(APPNAME))).app_ns = strenv(APPNST)",
      REGISTRY_PATH,
    ],
    { encoding: "utf8", env: { ...process.env, APPNAME: appName, APPNST: appNsTrimmed } },
  );
  return r.status === 0;
}

function patchRegistryRedisDb(yqBin, appName, redisDbTrimmed) {
  const envBase = { ...process.env, APPNAME: appName };
  const t = String(redisDbTrimmed ?? "").trim();
  if (!t) {
    const r = spawnSync(
      yqBin,
      ["-i", "del(.apps[] | select(.name == strenv(APPNAME)) | .redis_db)", REGISTRY_PATH],
      { encoding: "utf8", env: envBase },
    );
    return r.status === 0;
  }
  const db = parseInt(t, 10);
  const r = spawnSync(
    yqBin,
    ["-i", `(.apps[] | select(.name == strenv(APPNAME))).redis_db = ${db}`, REGISTRY_PATH],
    { encoding: "utf8", env: envBase },
  );
  return r.status === 0;
}

function runAppsSrcCloneShell(appName, url, branch) {
  return new Promise((resolveP) => {
    const args = [REPO_ROOT, appName, url];
    if (branch) args.push(branch);
    const child = spawn(APPS_SRC_CLONE, args, {
      cwd: REPO_ROOT,
      stdio: "inherit",
    });
    child.on("error", () => resolveP(1));
    child.on("exit", (c) => resolveP(c ?? 1));
  });
}

function gitPullAppFfOnly(appName) {
  return new Promise((resolveP) => {
    const dest = pathResolve(APPS_SRC, appName);
    const child = spawn("git", ["-C", dest, "pull", "--ff-only"], {
      cwd: REPO_ROOT,
      stdio: "inherit",
    });
    child.on("error", () => resolveP(1));
    child.on("exit", (c) => resolveP(c ?? 1));
  });
}

function runAppConfSet(app, yamlBody) {
  return new Promise((resolveP, rejectP) => {
    const child = spawn(APP_CONF_SET, [REPO_ROOT, app], {
      cwd: REPO_ROOT,
      stdio: ["pipe", "inherit", "inherit"],
    });
    child.stdin.write(yamlBody, "utf8");
    child.stdin.end();
    child.on("error", rejectP);
    child.on("exit", (code) => resolveP(code ?? 1));
  });
}

const BACKEND_LABELS = {
  postgres: "PostgreSQL (postgres.password)",
  kafka: "Kafka (kafka.password)",
  redis: "Redis (redis.password)",
  minio: "MinIO (access_key + secret_key)",
  clickhouse: "ClickHouse (clickhouse.password)",
  rabbitmq: "RabbitMQ (rabbitmq.password)",
};

const BACKENDS = DATA_SERVICES.map((value) => ({
  value,
  label: BACKEND_LABELS[value] ?? value,
}));

function registryNameCount(yqBin, appName) {
  const r = spawnSync(
    yqBin,
    ["[.apps[] | select(.name == strenv(APPNAME))] | length", REGISTRY_PATH],
    {
      encoding: "utf8",
      env: { ...process.env, APPNAME: appName },
    },
  );
  if (r.status !== 0) return -1;
  const n = parseInt(r.stdout.trim(), 10);
  return Number.isFinite(n) ? n : -1;
}

function validateAppName(v) {
  const s = String(v ?? "").trim();
  if (!s) return "Имя не может быть пустым";
  if (s === "_example") return "Зарезервировано";
  if (!/^[a-z0-9][a-z0-9_-]{0,62}$/.test(s)) {
    return "Латиница (a–z), цифры, - и _; первый символ — буква или цифра; до 63 символов.";
  }
  return undefined;
}

async function runAppConfTemplateInteractive({ standalone, yqBin }) {
  const app = ensure(
    await text({
      message: "Имя приложения (APP = поле name в registry):",
      validate: (v) => validateAppName(v),
    }),
  ).trim();

  const addRegistry = ensure(
    await confirm({
      message:
        "Добавить запись в apps/registry.yaml (enabled: false, app_ns как APP)?",
      initialValue: true,
    }),
  );

  if (addRegistry) {
    const cnt = registryNameCount(yqBin, app);
    if (cnt < 0) {
      log.error("Не удалось проверить registry (yq).");
      if (standalone) outro("Ошибка.");
      return;
    }
    if (cnt > 0) {
      log.error(
        `В registry уже есть name="${app}". Используйте другое имя или сценарий apps-conf-template с APP=${app} и SKIP_REGISTRY=1 (если каталога ещё нет).`,
      );
      if (standalone) outro("Ошибка.");
      return;
    }
  } else {
    const cnt = registryNameCount(yqBin, app);
    if (cnt === 0) {
      note(
        "В registry пока нет этого имени — добавьте запись вручную или повторите шаг с включённой опцией выше.",
        "Registry",
      );
    }
  }

  log.step(
    `apps-conf-template.sh ${app}${addRegistry ? "" : " (SKIP_REGISTRY=1)"}`,
  );
  const code = await new Promise((resolveP) => {
    const env = { ...process.env };
    if (!addRegistry) env.SKIP_REGISTRY = "1";
    const child = spawn(APPS_CONF_TEMPLATE, [REPO_ROOT, app], {
      cwd: REPO_ROOT,
      stdio: "inherit",
      env,
    });
    child.on("error", () => resolveP(1));
    child.on("exit", (c) => resolveP(c ?? 1));
  });
  if (code === 0) log.success(`Шаблон для «${app}» создан.`);
  else log.error(`apps-conf-template.sh завершился с кодом ${code}.`);

  if (standalone) outro("Готово.");
}

/**
 * @param {{ standalone?: boolean, session: { env: string } }} options
 */
export async function runConfigure(options = {}) {
  const { standalone = true, session } = options;
  if (!session || typeof session.env !== "string") {
    throw new Error("runConfigure: session.env обязателен");
  }

  const OPT_HELP = { value: HELP_VALUE, label: "Справка" };

  /** @param {keyof typeof MENU_HELP} id */
  function showCfgHelp(id) {
    const b = MENU_HELP[id];
    if (b) note(b.body, b.title);
  }

  async function preludeMultiselectStep(helpId) {
    for (;;) {
      const pre = ensure(
        await select({
          message: "Перед мультивыбором: перейти к списку или открыть справку",
          options: [
            { value: "go", label: "Перейти к выбору" },
            OPT_HELP,
          ],
        }),
      );
      if (pre === HELP_VALUE) {
        showCfgHelp(helpId);
        continue;
      }
      break;
    }
  }

  if (standalone) intro("Infra: конфигуратор приложений");

  const yqBin = resolveYq();

  await pickSessionEnvInteractive(session, {
    ensure,
    select,
    text,
    helpOption: OPT_HELP,
    showHelp: () => showCfgHelp("configureEnvSelect"),
  });

  note(
    `Переопределения SSH/registry: локальный файл environments/${session.env}.mk (не в git).`,
    "Окружение",
  );

  let mode;
  for (;;) {
    const m = ensure(
      await select({
        message: "Конфигуратор приложений:",
        options: [
          {
            value: "secrets",
            label: "Секреты (существующее приложение в registry)",
          },
          {
            value: "template",
            label: "Новое приложение: шаблон apps/conf (+ registry)",
          },
          OPT_HELP,
        ],
      }),
    );
    if (m === HELP_VALUE) {
      showCfgHelp("configureMode");
      continue;
    }
    mode = m;
    break;
  }

  if (mode === "template") {
    await runAppConfTemplateInteractive({ standalone, yqBin });
    return;
  }

  let appNames;
  try {
    appNames = listAppNames(yqBin);
  } catch (err) {
    log.error(err?.message || String(err));
    return;
  }

  if (appNames.length === 0) {
    log.warn(
      "В apps/registry.yaml нет приложений — создайте шаблон: этот же конфигуратор → «Новое приложение: шаблон» или сценарий apps-conf-template с APP=...",
    );
    return;
  }

  let app;
  for (;;) {
    const a = ensure(
      await select({
        message: "Приложение (name из registry):",
        options: [
          ...appNames.map((n) => ({ value: n, label: n })),
          OPT_HELP,
        ],
      }),
    );
    if (a === HELP_VALUE) {
      showCfgHelp("configureAppPick");
      continue;
    }
    app = a;
    break;
  }

  let meta = readRegistryAppMeta(yqBin, app);

  const wantRegistryMeta = ensure(
    await confirm({
      message:
        "Изменить в apps/registry.yaml поля enabled, app_ns, redis_db для этого приложения?",
      initialValue: false,
    }),
  );

  if (wantRegistryMeta) {
    let appsAll;
    try {
      appsAll = readAppsJson(yqBin);
    } catch (e) {
      log.error(String(e?.message || e));
      if (standalone) outro("Ошибка.");
      return;
    }

    const enabledNew = ensure(
      await confirm({
        message: "Включить приложение в merge и apps-apply (enabled: true)?",
        initialValue: meta?.enabled !== false,
      }),
    );

    const nsDefault = meta?.app_ns != null ? String(meta.app_ns) : app;
    const nsTyped = ensure(
      await text({
        message: "app_ns (namespace Kubernetes приложения):",
        initialValue: nsDefault,
        validate: validateAppNs,
      }),
    );
    const appNsTrim = String(nsTyped ?? "").trim();

    const redisDefault =
      meta?.redis_db !== undefined && meta?.redis_db !== null
        ? String(meta.redis_db)
        : "";
    const redisTyped = ensure(
      await text({
        message:
          "redis_db (0–127; пусто — убрать из registry, тогда при create подберётся свободный DB):",
        initialValue: redisDefault,
        validate: validateRedisDbField,
      }),
    );
    const redisTrim = String(redisTyped ?? "").trim();
    const draft = {
      enabled: enabledNew,
      app_ns: appNsTrim,
      clearRedisDb: !redisTrim,
      redis_db: redisTrim ? parseInt(redisTrim, 10) : undefined,
    };

    const simErr = simulateRegistryPatchesError(appsAll, app, draft);
    if (simErr) {
      log.error(simErr);
      if (standalone) outro("Прервано.");
      return;
    }

    if (!patchRegistryEnabled(yqBin, app, draft.enabled)) {
      log.error("Не удалось записать enabled (yq).");
      if (standalone) outro("Ошибка.");
      return;
    }
    if (!patchRegistryAppNs(yqBin, app, draft.app_ns)) {
      log.error("Не удалось записать app_ns (yq).");
      if (standalone) outro("Ошибка.");
      return;
    }
    if (!patchRegistryRedisDb(yqBin, app, redisTrim)) {
      log.error("Не удалось записать redis_db (yq).");
      if (standalone) outro("Ошибка.");
      return;
    }
    log.success("apps/registry.yaml: обновлены enabled, app_ns и при необходимости redis_db.");
    meta = readRegistryAppMeta(yqBin, app);
  }

  const wantSource = ensure(
    await confirm({
      message: `Настроить repo_url / repo_branch в registry и git clone в apps/src/${app}?`,
      initialValue: Boolean(meta?.repo_url),
    }),
  );

  if (wantSource) {
    const urlHint = meta?.repo_url != null ? String(meta.repo_url) : "";
    const branchHint = meta?.repo_branch != null ? String(meta.repo_branch) : "";
    const urlRaw = ensure(
      await text({
        message: "repo_url (пусто — убрать из registry):",
        initialValue: urlHint,
        placeholder: "https://… или git@…",
      }),
    );
    const urlTrim = String(urlRaw ?? "").trim();
    const urlErr = validateRepoUrl(urlTrim);
    if (urlErr) {
      log.error(urlErr);
      if (standalone) outro("Прервано.");
      return;
    }

    const brRaw = ensure(
      await text({
        message: "repo_branch (пусто — клон с веткой по умолчанию; ключ branch в registry снимется):",
        initialValue: branchHint,
      }),
    );
    const brTrim = String(brRaw ?? "").trim();

    if (!patchRegistrySource(yqBin, app, urlTrim, brTrim)) {
      log.error("Не удалось обновить apps/registry.yaml (yq).");
      if (standalone) outro("Ошибка.");
      return;
    }
    if (urlTrim) {
      log.success("registry: repo_url/repo_branch записаны.");
    } else {
      log.success("registry: repo_url/repo_branch удалены.");
    }

    if (urlTrim) {
      const code = await runAppsSrcCloneShell(app, urlTrim, brTrim);
      if (code === 0) {
        log.success(`Клон: apps/src/${app}`);
      } else if (code === 2) {
        const doPull = ensure(
          await confirm({
            message: `apps/src/${app} уже есть. Выполнить git pull --ff-only?`,
            initialValue: true,
          }),
        );
        if (doPull) {
          const pc = await gitPullAppFfOnly(app);
          if (pc === 0) log.success("git pull выполнен.");
          else log.error(`git pull завершился с кодом ${pc}`);
        }
      } else if (code === 3) {
        log.error(
          `apps/src/${app} существует и не git-репозиторий — уберите каталог вручную.`,
        );
      } else {
        log.error(`apps-src-clone.sh: код ${code}`);
      }
    }
  }

  await preludeMultiselectStep("configureBackends");

  const pickedBackends = ensure(
    await multiselect({
      message: "Какие секреты записать в apps/conf (merge в secrets.yaml)?",
      options: BACKENDS,
      required: false,
    }),
  );

  if (!pickedBackends?.length) {
    note("Секреты не выбраны — app-conf-set не вызывается.", "apps/conf");
    if (standalone) outro("Готово.");
    return;
  }

  const parts = [];

  for (const svc of DATA_SERVICES) {
    if (svc === "minio" || !pickedBackends.includes(svc)) continue;
    const defPw = hex(12);
    const pwRaw = ensure(
      await password({
        message: `${svc}.password (Enter — ${maskShort(defPw)})`,
        mask: "*",
      }),
    );
    const pw = pwRaw || defPw;
    parts.push(`${svc}:\n  password: "${yamlEscape(pw)}"`);
  }

  if (pickedBackends.includes("minio")) {
    const defAk = `app_${app}`;
    const ak = ensure(
      await text({
        message: "minio.access_key (Enter — app_<name>)",
        initialValue: defAk,
        placeholder: defAk,
      }),
    );
    const accessKey = String(ak || "").trim() || defAk;
    const defSk = hex(16);
    const skRaw = ensure(
      await password({
        message: `minio.secret_key (Enter — ${maskShort(defSk)})`,
        mask: "*",
      }),
    );
    const secretKey = skRaw || defSk;
    parts.push(
      `minio:\n  access_key: "${yamlEscape(accessKey)}"\n  secret_key: "${yamlEscape(secretKey)}"`,
    );
  }

  const yamlBody = `${parts.join("\n")}\n`;
  log.step(`app-conf-set.sh → apps/conf/${app}/secrets.yaml`);

  const code = await runAppConfSet(app, yamlBody);
  if (code === 0) log.success(`Секреты для «${app}» записаны.`);
  else log.error(`app-conf-set завершился с кодом ${code}.`);

  if (standalone) outro("Готово.");
}
