// «Бэкапы» — единое подменю. Закрывает Сценарий 5 из usage-scenarios.md.
//
// Бэкап-цели по сервисам:
//   postgres  → postgres-backup            ← полный pg_dump
//   redis     → redis-backup               ← RDB + ACL
//   kafka     → kafka-backup-meta          ← только метаданные топиков
//   minio     → minio-backup-meta          ← только метаданные (политики/пользователи)
//   clickhouse→ clickhouse-backup
//   rabbitmq  → rabbitmq-backup-defs       ← только definitions (без сообщений)
//   env       → env-backup                 ← платформенные Secrets + apps/conf/
//
// Per-app бэкапы (apps/backups/<ENV>/<APP>/<service>/):
//   <svc>-app-backup / <svc>-app-restore для postgres/clickhouse/minio/kafka/rabbitmq.
//   Redis намеренно не входит — нет per-app единицы данных.
//   Диспатчер `make app-backup APP=…` запускает все сервисы APP по merged конфигу.
//
// Restore-цели — соответствующие *-restore* (см. README по сервисам).
// BACKUP_FILE — относительный путь от <service>/ (например backups/<env>/...),
// либо абсолютный, если make-цель его принимает. Для env-restore нужен CONFIRM=1.

import { select, multiselect, note } from "../io.mjs";
import {
  ensure,
  promptAppFromSession,
  promptDangerous,
  promptYesNo,
  requiredText,
  runTarget,
} from "../prompts.mjs";
import { displayServiceName } from "../meta.mjs";

export const STATEFUL = [
  { value: "postgres",   backup: "postgres-backup",       restore: "postgres-restore" },
  { value: "redis",      backup: "redis-backup",          restore: "redis-restore-acl" },
  { value: "kafka",      backup: "kafka-backup-meta",     restore: "kafka-restore-meta-topics" },
  { value: "minio",      backup: "minio-backup-meta",     restore: "minio-restore-meta" },
  { value: "clickhouse", backup: "clickhouse-backup",     restore: "clickhouse-restore" },
  { value: "rabbitmq",   backup: "rabbitmq-backup-defs",  restore: "rabbitmq-restore-defs" },
];

// Per-app backup/restore цели. Redis не входит (нет per-app единицы данных).
// Контракт совпадает с Makefile: targets `<svc>-app-backup` / `<svc>-app-restore`
// принимают APP и ENV; restore дополнительно требует BACKUP_FILE (относительно $(REPO_ROOT)).
export const PER_APP_BACKUP = [
  { value: "postgres",   backup: "pg-app-backup",         restore: "pg-app-restore",         dir: "postgres",   scope: "db",     ext: "sql.gz"  },
  { value: "clickhouse", backup: "clickhouse-app-backup", restore: "clickhouse-app-restore", dir: "clickhouse", scope: "db",     ext: "tar.gz"  },
  { value: "minio",      backup: "minio-app-backup",      restore: "minio-app-restore",      dir: "minio",      scope: "bucket", ext: "tar.gz"  },
  { value: "kafka",      backup: "kafka-app-backup",      restore: "kafka-app-restore",      dir: "kafka",      scope: "topics", ext: "tar.gz"  },
  { value: "rabbitmq",   backup: "rabbitmq-app-backup",   restore: "rabbitmq-app-restore",   dir: "rabbitmq",   scope: "defs",   ext: "json.gz" },
];

const SVC_BY_VALUE = Object.fromEntries(STATEFUL.map((s) => [s.value, s]));
const PER_APP_BY_VALUE = Object.fromEntries(PER_APP_BACKUP.map((s) => [s.value, s]));

/**
 * @param {{ env: string, app?: string|null }} session
 */
export async function actionBackup(session) {
  for (;;) {
    const choice = ensure(
      await select({
        message: `Бэкапы · ENV: ${session.env}${session.app ? ` · APP: ${session.app}` : ""}`,
        options: [
          { value: "make_full",     label: "Сделать бэкап: полный",         hint: "backup-all + env-backup (Secrets/apps/conf)" },
          { value: "make_pick",     label: "Сделать бэкап: выборочно",      hint: "выбор stateful-сервисов" },
          { value: "make_env",      label: "Сделать бэкап: только секреты", hint: "env-backup" },
          { value: "make_app",      label: "Сделать per-app бэкап",         hint: "apps/backups/<ENV>/<APP>/<svc>/…" },
          { value: "restore_svc",   label: "Восстановить сервис из архива", hint: "*-restore* BACKUP_FILE=…" },
          { value: "restore_env",   label: "Восстановить секреты из архива", hint: "env-restore BACKUP_FILE=… CONFIRM=1" },
          { value: "restore_app",   label: "Восстановить per-app бэкап",    hint: "<svc>-app-restore APP=… BACKUP_FILE=…" },
          { value: "back",          label: "Назад" },
        ],
      }),
    );
    if (choice === "back") return;

    if (choice === "make_full")        await makeFull(session);
    else if (choice === "make_pick")    await makePick(session);
    else if (choice === "make_env")     await makeEnv(session);
    else if (choice === "make_app")     await makeApp(session);
    else if (choice === "restore_svc")  await restoreSvc(session);
    else if (choice === "restore_env")  await restoreEnv(session);
    else if (choice === "restore_app")  await restoreApp(session);
  }
}

/* ──────────────────────────────────────────────────────────────────────────── */

async function makeFull(session) {
  note(
    [
      "backup-all: postgres-backup, redis-backup, kafka-backup-meta, minio-backup-meta,",
      "clickhouse-backup, rabbitmq-backup-defs (с учётом ENABLED_SERVICES/EXCLUDE_SERVICES из <ENV>.mk).",
      "Плюс env-backup — платформенные Secrets и apps/conf/.",
      "",
      "Артефакты — в <service>/backups/<ENV>/ и environments/backups/<ENV>/ (gitignored).",
    ].join("\n"),
    "Полный бэкап",
  );
  if (!(await promptYesNo("Запустить?", true))) return;
  const okAll = await runTarget(session, "backup-all", {});
  if (okAll && (await promptYesNo("Дополнительно сделать env-backup (Secrets + apps/conf/)?", true))) {
    await runTarget(session, "env-backup", {});
  }
}

async function makePick(session) {
  for (;;) {
    const svc = ensure(
      await select({
        message: "Сервис для бэкапа:",
        options: [
          ...STATEFUL.map((s) => ({ value: s.value, label: displayServiceName(s.value), hint: s.backup })),
          { value: "back", label: "Назад" },
        ],
      }),
    );
    if (svc === "back") return;
    await runTarget(session, SVC_BY_VALUE[svc].backup, {});
  }
}

async function makeEnv(session) {
  note(
    "env-backup → environments/backups/<env>/YYYYMMDD-HHMMSS.tar.gz. Без этого архива восстановление с нуля невозможно.",
    "env-backup",
  );
  if (await promptYesNo("Запустить env-backup сейчас?", true)) {
    await runTarget(session, "env-backup", {});
  }
}

async function restoreSvc(session) {
  const svc = ensure(
    await select({
      message: "Сервис для восстановления:",
      options: [
        ...STATEFUL.map((s) => ({ value: s.value, label: displayServiceName(s.value), hint: s.restore })),
        { value: "back", label: "Назад" },
      ],
    }),
  );
  if (svc === "back") return;
  const meta = SVC_BY_VALUE[svc];

  const file = await requiredText(
    `BACKUP_FILE — путь к файлу (относительный от ${svc}/, например backups/${session.env}/...; или абсолютный):`,
  );
  if (!(await promptDangerous(`Восстановление ${displayServiceName(svc)} из ${file}.`))) return;

  /** @type {Record<string,string>} */
  const env = { BACKUP_FILE: file, SKIP_CONFIRM: "1" };
  await runTarget(session, meta.restore, env);
}

async function restoreEnv(session) {
  note(
    "env-restore разворачивает архив environments/backups/<env>/<TS>.tar.gz: kubeconfig, Secrets платформы, apps/conf/. Затирает существующие файлы.",
    "env-restore",
  );
  const file = await requiredText(
    "BACKUP_FILE — путь к архиву env-backup (например environments/backups/local/20260101-120000.tar.gz):",
  );
  if (!(await promptDangerous(`Восстановление окружения ${session.env} из ${file}. Существующие файлы будут перезаписаны.`)))
    return;
  await runTarget(session, "env-restore", { BACKUP_FILE: file, CONFIRM: "1" });
}

async function makeApp(session) {
  const app = await promptAppFromSession(session);
  if (!app) return;

  const mode = ensure(
    await select({
      message: `Per-app backup ${app} · ENV: ${session.env}`,
      options: [
        { value: "all",  label: "Все сервисы APP сразу", hint: "make app-backup APP=…  (диспатчер по merged)" },
        { value: "pick", label: "Выбрать сервисы",       hint: "по одному: <svc>-app-backup APP=…" },
        { value: "back", label: "Назад" },
      ],
    }),
  );
  if (mode === "back") return;

  if (mode === "all") {
    note(
      [
        `Диспатчер app-backup читает apps-merge-print, для каждого сервиса с конфигом APP=${app}`,
        "запускает <svc>-app-backup. Redis намеренно не входит. Fail-fast по умолчанию",
        "(APP_BACKUP_CONTINUE_ON_ERROR=1 чтобы продолжать остальные при ошибке).",
        "",
        `Артефакты — в apps/backups/${session.env}/${app}/<service>/ (gitignored).`,
      ].join("\n"),
      "Per-app backup",
    );
    if (!(await promptYesNo(`Запустить app-backup APP=${app}?`, true))) return;
    await runTarget(session, "app-backup", { APP: app });
    return;
  }

  // mode === "pick"
  const picked = ensure(
    await multiselect({
      message: `Сервисы для бэкапа APP=${app}:`,
      options: PER_APP_BACKUP.map((s) => ({
        value: s.value,
        label: displayServiceName(s.value),
        hint: s.backup,
      })),
      required: true,
    }),
  );
  for (const svc of picked) {
    await runTarget(session, PER_APP_BY_VALUE[svc].backup, { APP: app });
  }
}

async function restoreApp(session) {
  const app = await promptAppFromSession(session);
  if (!app) return;

  const svc = ensure(
    await select({
      message: `Восстановить APP=${app} · сервис:`,
      options: [
        ...PER_APP_BACKUP.map((s) => ({
          value: s.value,
          label: displayServiceName(s.value),
          hint: s.restore,
        })),
        { value: "back", label: "Назад" },
      ],
    }),
  );
  if (svc === "back") return;

  const meta = PER_APP_BY_VALUE[svc];
  const exampleFile = `apps/backups/${session.env}/${app}/${meta.dir}/${app}-${meta.scope}-YYYYMMDD-HHMMSS.${meta.ext}`;
  const file = await requiredText(
    `BACKUP_FILE — путь от корня репо, например ${exampleFile}:`,
  );

  if (!(await promptDangerous(
    `Восстановление ${displayServiceName(svc)} для APP=${app} из ${file}.`,
  ))) return;

  await runTarget(session, meta.restore, {
    APP: app,
    BACKUP_FILE: file,
    SKIP_CONFIRM: "1",
  });
}

