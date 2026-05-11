// infra TUI — action-first главное меню.
// Группы: «Каждый день» / «Сценарии» / «Бэкапы» / «Настройка» / «Сессия».
// Контекст ENV+APP — см. context.mjs (APP кэшируется per-ENV между запусками).
// Покрытие 7 сценариев из docs/runbooks/usage-scenarios.md — 1:1.

import { intro, outro, select, text, note, log } from "./io.mjs";

import {
  ensureSessionShape,
  setSessionApp,
  setSessionEnv,
  renderSessionHeader,
} from "./context.mjs";
import { ensure } from "./prompts.mjs";
import {
  formatSessionEnvOptionLabel,
  listEnvironmentNames,
} from "../lib/session-env-picker.mjs";

import { actionApply } from "./actions/apply.mjs";
import { actionDiff } from "./actions/diff.mjs";
import { actionStatus } from "./actions/status.mjs";
import { actionAccounts } from "./actions/accounts.mjs";

import { wizardConnectApp } from "./wizards/connect-app.mjs";
import { wizardDisconnectApp } from "./wizards/disconnect-app.mjs";
import { wizardConfigureServices } from "./wizards/configure-services.mjs";

import { actionBackup } from "./actions/backup.mjs";
import { settingsEnvironment } from "./settings/environment.mjs";
import { settingsTcp } from "./settings/tcp.mjs";
import { settingsCharts } from "./settings/charts.mjs";

function defaultEnv() {
  const n = listEnvironmentNames();
  if (!n.length) return "local";
  if (n.includes("local")) return "local";
  return n[0];
}

async function pickAppFlow(session) {
  const value = ensure(
    await text({
      message: `APP для сессии (ENV=${session.env}). Пусто — очистить.`,
      placeholder: session.app ?? "myapp",
      initialValue: session.app ?? "",
    }),
  );
  const trimmed = String(value ?? "").trim();
  setSessionApp(session, trimmed || null);
  if (!trimmed) note("APP сессии очищен.", "Сессия");
  else note(`APP сессии: ${trimmed}.`, "Сессия");
}

async function pickEnvFlow(session) {
  const envs = listEnvironmentNames();
  if (!envs.length) {
    note(
      "Нет окружений (environments/*.yaml). Создайте через «Окружение и образы → Создать рыбу окружения (env-new)».",
      "ENV",
    );
    return;
  }
  const choice = ensure(
    await select({
      message: "Окружение сессии:",
      options: envs.map((e) => ({
        value: e,
        label: formatSessionEnvOptionLabel(e),
      })),
      initialValue: session.env,
    }),
  );
  setSessionEnv(session, choice);
  note(
    `ENV: ${choice}${session.app ? ` · APP=${session.app}` : " · APP не задан"}.`,
    "Сессия",
  );
}

async function sessionMenu(session) {
  for (;;) {
    const action = ensure(
      await select({
        message: `Сессия · ${renderSessionHeader(session)}`,
        options: [
          {
            value: "env",
            label: "Сменить ENV",
            hint: `текущий: ${session.env}`,
          },
          {
            value: "app",
            label: "Задать или сменить APP",
            hint: `текущий: ${session.app ?? "—"}`,
          },
          {
            value: "clear",
            label: "Очистить APP",
            hint: "снимает выбор приложения для сессии",
          },
          { value: "back", label: "Назад" },
        ],
      }),
    );
    if (action === "back") return;
    if (action === "env") await pickEnvFlow(session);
    if (action === "app") await pickAppFlow(session);
    if (action === "clear") {
      setSessionApp(session, null);
      note("APP сессии очищен.", "Сессия");
    }
  }
}

export const ACTIONS = [
  // «Каждый день» — горячие пункты, без префиксов в label, чтобы быстро распознавались
  { value: "apply",   label: "Применить изменения",      hint: "helm up + apps-apply (мультивыбор сервисов)" },
  { value: "diff",    label: "Сравнить с кластером",     hint: "helm diff" },
  { value: "status",  label: "Состояние и логи",         hint: "doctor / status / логи / shell / события" },
  { value: "accts",   label: "Учётки и топики",          hint: "по APP: pg/redis/kafka/minio/clickhouse/rabbitmq + Kafka topics" },
  // Сценарии-мастера
  { value: "wiz_connect",    label: "Сценарий: подключить приложение",   hint: "template → configure → merge → apps-apply" },
  { value: "wiz_services",   label: "Сценарий: конфигурирование сервисов", hint: "весь набор / только указанные / кроме указанных + запись в <env>.mk + diff" },
  { value: "wiz_disconnect", label: "Сценарий: отключить приложение",    hint: "registry: enabled=false + опционально *-app-drop" },
  // Бэкапы
  { value: "backup",         label: "Бэкапы",                            hint: "сделать (полный/выборочный/секреты) или восстановить (svc/env)" },
  // Настройка
  { value: "set_env",    label: "Окружение и образы",                    hint: "kubeconfig, ssh, microk8s, images-save/push" },
  { value: "set_tcp",    label: "TCP-порты ingress (microk8s)",          hint: "k8s-port-expose-show/patch/apply" },
  { value: "set_charts", label: "Чарты: проверка и обновления",          hint: "verify, check-updates" },
  // Сессия
  { value: "session", label: "Сессия: ENV / APP / kubeconfig-info" },
  { value: "exit",    label: "Выход" },
];

export async function runInfraV2() {
  /** @type {import("./context.mjs").Session} */
  const session = ensureSessionShape({ env: defaultEnv() });

  intro("infra");
  note(
    [
      `ENV: ${session.env}`,
      `APP: ${session.app ?? "—"}  (кэш per-ENV)`,
      "",
      "Сменить ENV/APP — пункт «Сессия» в меню.",
    ].join("\n"),
    "Сессия",
  );

  for (;;) {
    const choice = ensure(
      await select({
        message: renderSessionHeader(session),
        options: ACTIONS,
        maxItems: 14,
      }),
    );

    if (choice === "exit") break;
    if (choice === "session") { await sessionMenu(session); continue; }

    if (choice === "apply")  { await actionApply(session);    continue; }
    if (choice === "diff")   { await actionDiff(session);     continue; }
    if (choice === "status") { await actionStatus(session);   continue; }
    if (choice === "accts")  { await actionAccounts(session); continue; }

    if (choice === "wiz_connect")    { await wizardConnectApp(session);       continue; }
    if (choice === "wiz_services")   { await wizardConfigureServices(session); continue; }
    if (choice === "wiz_disconnect") { await wizardDisconnectApp(session);    continue; }

    if (choice === "backup")     { await actionBackup(session);        continue; }
    if (choice === "set_env")    { await settingsEnvironment(session); continue; }
    if (choice === "set_tcp")    { await settingsTcp(session);         continue; }
    if (choice === "set_charts") { await settingsCharts(session);      continue; }

    log.warn(`Неизвестный пункт меню: ${String(choice)}`);
  }

  outro("Завершено.");
}
