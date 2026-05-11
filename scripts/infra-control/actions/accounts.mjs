// «Учётки и топики» — единое подменю для работы с APP-учётками в data-сервисах
// и Kafka topics. APP берётся из контекста сессии (этап 0); если не задан —
// спрашиваем один раз и сохраняем в кэш.

import { select, note, log } from "../io.mjs";
import {
  ensure,
  optionalText,
  promptAppFromSession,
  promptDangerous,
  promptYesNo,
  promptServicesSelection,
  requiredText,
  runTarget,
} from "../prompts.mjs";

/**
 * @typedef {{ env: string, app?: string|null }} Session
 */

/**
 * @param {Session} session
 */
export async function actionAccounts(session) {
  // APP нужен для большинства действий — спросим один раз перед входом.
  const app = await promptAppFromSession(session, {
    requireValue: true,
    persist: true,
  });
  if (!app) return;

  for (;;) {
    const choice = ensure(
      await select({
        message: `Учётки и топики · APP=${session.app} · ENV=${session.env}`,
        options: [
          { value: "pg",  label: "PostgreSQL", hint: "create / show / psql / verify / drop" },
          { value: "rd",  label: "Redis",      hint: "create / show / verify / drop" },
          { value: "kf",  label: "Kafka",      hint: "create / show / verify / drop" },
          { value: "mn",  label: "MinIO",      hint: "create / show / append-bucket / verify / drop" },
          { value: "ch",  label: "ClickHouse", hint: "create / show / verify / drop" },
          { value: "rmq", label: "RabbitMQ",   hint: "create / show / verify / drop" },
          { value: "tp",  label: "Топики Kafka", hint: `создать/alter/describe/list (префикс ${session.app}.)` },
          { value: "apply", label: "Применить учётки (apps-apply)", hint: "из apps/registry.yaml + apps/conf/" },
          { value: "chgapp", label: "Сменить APP сессии",            hint: `текущий: ${session.app}` },
          { value: "back", label: "Назад" },
        ],
      }),
    );
    if (choice === "back") return;

    if (choice === "chgapp") {
      session.app = null;
      const next = await promptAppFromSession(session, { requireValue: true, persist: true });
      if (!next) return;
      continue;
    }

    if (choice === "apply") { await applyAppsFlow(session); continue; }
    if (choice === "tp")    { await topicsMenu(session);    continue; }

    await engineMenu(session, choice);
  }
}

/* ──────────────────────────────────────────────────────────────────────────── */
/* Учётки конкретного движка                                                   */
/* ──────────────────────────────────────────────────────────────────────────── */

/** Источник правды по движкам учёток. Каждый элемент:
 *  - key    — короткий идентификатор для пользователя (выбор в меню)
 *  - prefix — префикс make-целей `${prefix}-app-{create,show-creds,verify,drop}`
 *  - label  — отображаемое имя
 */
export const ENGINES = [
  { key: "pg",  prefix: "pg",         label: "PostgreSQL" },
  { key: "rd",  prefix: "redis",      label: "Redis" },
  { key: "kf",  prefix: "kafka",      label: "Kafka" },
  { key: "mn",  prefix: "minio",      label: "MinIO" },
  { key: "ch",  prefix: "clickhouse", label: "ClickHouse" },
  { key: "rmq", prefix: "rabbitmq",   label: "RabbitMQ" },
];

const ENGINE_BY_KEY = Object.fromEntries(ENGINES.map((e) => [e.key, e]));

async function engineMenu(session, key) {
  const { prefix, label } = ENGINE_BY_KEY[key];
  for (;;) {
    /** @type {{value: string, label: string, hint?: string}[]} */
    const opts = [
      { value: "create", label: "Создать учётку и ресурсы" },
      { value: "show",   label: "Показать креды и эндпоинт" },
      { value: "verify", label: "Проверить учётку в кластере" },
      { value: "drop",   label: "Удалить учётку (опасно)" },
      { value: "back",   label: "Назад" },
    ];
    if (key === "pg")  opts.splice(2, 0, { value: "psql",   label: "Открыть psql от имени APP" });
    if (key === "mn")  opts.splice(2, 0, { value: "append", label: "Добавить bucket к учётке" });

    const act = ensure(
      await select({
        message: `${label} · APP=${session.app}`,
        options: opts,
      }),
    );
    if (act === "back") return;

    if (act === "create") await create(session, key);
    else if (act === "show")   await runTarget(session, `${prefix}-app-show-creds`, { APP: session.app });
    else if (act === "verify") await runTarget(session, `${prefix}-app-verify`,     { APP: session.app });
    else if (act === "psql")   await runTarget(session, "pg-app-psql",              { APP: session.app }, { sigint: true });
    else if (act === "append") await minioAppend(session);
    else if (act === "drop")   await drop(session, key);
  }
}

async function create(session, key) {
  const { prefix } = ENGINE_BY_KEY[key];
  /** @type {Record<string,string|undefined>} */
  const env = { APP: session.app };

  // Все движки: опциональный APP_NS (по умолчанию = APP).
  const ns = await optionalText(
    `APP_NS — namespace приложения (Enter — оставить ${session.app}):`,
    "",
  );
  if (ns) env.APP_NS = ns;

  if (key === "rd") {
    const db = await optionalText("REDIS_DB (Enter — авто-выбор первого свободного 1..127):", "");
    if (db) env.REDIS_DB = db;
  }

  if (key === "mn") {
    const bucket = await optionalText("BUCKET (Enter — = APP):", "");
    if (bucket) env.BUCKET = bucket;
    const access = ensure(
      await select({
        message: "ACCESS_MODE — доступ для бакета:",
        options: [
          { value: "private_rw",  label: "private_rw — read+write только владельцу" },
          { value: "public_read", label: "public_read — анонимное чтение" },
          { value: "private_ro",  label: "private_ro — read-only владелец" },
          { value: "skip",        label: "Пропустить (использовать default чарта)" },
        ],
      }),
    );
    if (access !== "skip") env.ACCESS_MODE = access;
    const pubEnd = await optionalText("APP_PUBLIC_ENDPOINT (опц., для presigned URL на публичном домене):", "");
    if (pubEnd) env.APP_PUBLIC_ENDPOINT = pubEnd;
  }

  await runTarget(session, `${prefix}-app-create`, env);
}

async function drop(session, key) {
  const { prefix, label } = ENGINE_BY_KEY[key];
  if (!(await promptDangerous(`Удалить учётку ${label} для APP=${session.app}.`))) return;
  /** @type {Record<string,string|undefined>} */
  const env = { APP: session.app, SKIP_CONFIRM: "1" };
  if (key === "mn") {
    if (await promptYesNo("Также удалить бакеты приложения? (MINIO_REMOVE_BUCKETS=1)", false)) {
      env.MINIO_REMOVE_BUCKETS = "1";
    }
  }
  await runTarget(session, `${prefix}-app-drop`, env);
}

async function minioAppend(session) {
  const bucket = await requiredText("BUCKET — имя нового бакета для приложения:");
  /** @type {Record<string,string|undefined>} */
  const env = { APP: session.app, BUCKET: bucket };
  const access = ensure(
    await select({
      message: `ACCESS_MODE для bucket ${bucket}:`,
      options: [
        { value: "private_rw",  label: "private_rw" },
        { value: "public_read", label: "public_read" },
        { value: "private_ro",  label: "private_ro" },
        { value: "skip",        label: "Пропустить (default чарта)" },
      ],
    }),
  );
  if (access !== "skip") env.ACCESS_MODE = access;
  await runTarget(session, "minio-app-append", env);
}

/* ──────────────────────────────────────────────────────────────────────────── */
/* Топики Kafka                                                                 */
/* ──────────────────────────────────────────────────────────────────────────── */

async function topicsMenu(session) {
  for (;;) {
    const act = ensure(
      await select({
        message: `Топики Kafka · APP=${session.app}`,
        options: [
          { value: "create",   label: "Создать топик по APP", hint: `имя = ${session.app}.<TOPIC_SUFFIX>` },
          { value: "alter",    label: "Изменить параметры топика" },
          { value: "describe", label: "Показать описание топика" },
          { value: "list",     label: "Список топиков", hint: `по умолчанию префикс ${session.app}.` },
          { value: "back",     label: "Назад" },
        ],
      }),
    );
    if (act === "back") return;

    if (act === "create") {
      const suffix = await requiredText(`TOPIC_SUFFIX (имя без префикса; результат: ${session.app}.<suffix>):`);
      const partitions = await optionalText("PARTITIONS (Enter — default чарта):", "");
      const configs = await optionalText("CONFIGS — пары k=v через запятую (например retention.ms=...,cleanup.policy=delete):", "");
      const env = /** @type {Record<string,string>} */ ({ APP: session.app, TOPIC_SUFFIX: suffix });
      if (partitions) env.PARTITIONS = partitions;
      if (configs) env.CONFIGS = configs;
      await runTarget(session, "kafka-topic-create", env);
    } else if (act === "alter") {
      const topic = await requiredText("TOPIC (полное имя):");
      const partitions = await optionalText("PARTITIONS (Enter — не менять):", "");
      const configs = await optionalText("CONFIGS k=v,k=v (Enter — не менять):", "");
      const env = /** @type {Record<string,string>} */ ({ TOPIC: topic });
      if (partitions) env.PARTITIONS = partitions;
      if (configs) env.CONFIGS = configs;
      await runTarget(session, "kafka-topic-alter", env);
    } else if (act === "describe") {
      const topic = await requiredText("TOPIC (полное имя):");
      await runTarget(session, "kafka-topic-describe", { TOPIC: topic });
    } else if (act === "list") {
      const def = `${session.app}.`;
      const prefix = await optionalText(`PREFIX (Enter — ${def}, '-' — без префикса):`, "");
      const env = /** @type {Record<string,string>} */ ({});
      if (prefix === "-") {
        // явный сброс
      } else if (prefix) {
        env.PREFIX = prefix;
      } else {
        env.PREFIX = def;
      }
      await runTarget(session, "kafka-topic-list", env);
    }
  }
}

/* ──────────────────────────────────────────────────────────────────────────── */
/* apps-apply из меню учёток                                                   */
/* ──────────────────────────────────────────────────────────────────────────── */

async function applyAppsFlow(session) {
  note(
    "apps-apply применит учётки и конфиги для всех enabled-приложений из apps/registry.yaml.",
    "Применить учётки",
  );
  const { enabled, exclude } = await promptServicesSelection({ kind: "apps-apply" });
  /** @type {Record<string,string>} */
  const env = {};
  if (enabled !== null) env.ENABLED_SERVICES = enabled;
  if (exclude !== null) env.EXCLUDE_SERVICES = exclude;
  if (await promptYesNo("При ошибке на одном сервисе продолжать? (APPS_APPLY_CONTINUE_ON_ERROR=1)", false)) {
    env.APPS_APPLY_CONTINUE_ON_ERROR = "1";
  }
  await runTarget(session, "apps-apply", env);
}

