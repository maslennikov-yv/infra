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
// Restore-цели — соответствующие *-restore* (см. README по сервисам).
// BACKUP_FILE — относительный путь от <service>/backups/ (либо абсолютный,
// если make-цель его принимает). Для env-restore нужен CONFIRM=1.

import { select, note } from "../io.mjs";
import {
  ensure,
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

const SVC_BY_VALUE = Object.fromEntries(STATEFUL.map((s) => [s.value, s]));

/**
 * @param {{ env: string }} session
 */
export async function actionBackup(session) {
  for (;;) {
    const choice = ensure(
      await select({
        message: `Бэкапы · ENV: ${session.env}`,
        options: [
          { value: "make_full",     label: "Сделать бэкап: полный",       hint: "backup-all + env-backup (Secrets/apps/conf)" },
          { value: "make_pick",     label: "Сделать бэкап: выборочно",    hint: "выбор stateful-сервисов" },
          { value: "make_env",      label: "Сделать бэкап: только секреты", hint: "env-backup" },
          { value: "restore_svc",   label: "Восстановить сервис из архива", hint: "*-restore* BACKUP_FILE=…" },
          { value: "restore_env",   label: "Восстановить секреты из архива", hint: "env-restore BACKUP_FILE=… CONFIRM=1" },
          { value: "back",          label: "Назад" },
        ],
      }),
    );
    if (choice === "back") return;

    if (choice === "make_full")   await makeFull(session);
    else if (choice === "make_pick")    await makePick(session);
    else if (choice === "make_env")     await makeEnv(session);
    else if (choice === "restore_svc")  await restoreSvc(session);
    else if (choice === "restore_env")  await restoreEnv(session);
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
      "Артефакты — в <service>/backups/ и environments/backups/ (gitignored).",
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
    "env-backup → environments/backups/<env>-YYYYMMDD-HHMMSS.tar.gz. Без этого архива восстановление с нуля невозможно.",
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
    `BACKUP_FILE — путь к файлу (относительный от ${svc}/backups/ или абсолютный):`,
  );
  if (!(await promptDangerous(`Восстановление ${displayServiceName(svc)} из ${file}.`))) return;

  /** @type {Record<string,string>} */
  const env = { BACKUP_FILE: file, SKIP_CONFIRM: "1" };
  await runTarget(session, meta.restore, env);
}

async function restoreEnv(session) {
  note(
    "env-restore разворачивает архив environments/backups/<env>-...tar.gz: kubeconfig, Secrets платформы, apps/conf/. Затирает существующие файлы.",
    "env-restore",
  );
  const file = await requiredText(
    "BACKUP_FILE — путь к архиву env-backup (например environments/backups/local-20260101-120000.tar.gz):",
  );
  if (!(await promptDangerous(`Восстановление окружения ${session.env} из ${file}. Существующие файлы будут перезаписаны.`)))
    return;
  await runTarget(session, "env-restore", { BACKUP_FILE: file, CONFIRM: "1" });
}

