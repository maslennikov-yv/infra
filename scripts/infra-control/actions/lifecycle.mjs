// «Lifecycle приложения» — вызывает app-* make-цели через infra-interface.
// Методы объявлены в apps/src/<APP>/infra-interface.yaml.
// Если файл не найден — показывается инструкция.

import { select, text, note } from "../io.mjs";
import { ensure, promptAppFromSession, promptDangerous, runTarget } from "../prompts.mjs";
import fs from "node:fs";
import path from "node:path";
import { REPO_ROOT } from "../../lib/repo.mjs";

/**
 * @param {{ env: string, app?: string|null }} session
 */
export async function actionLifecycle(session) {
  const app = await promptAppFromSession(session, {
    requireValue: true,
    persist: true,
  });
  if (!app) return;

  const srcDir = path.join(REPO_ROOT, "apps", "src", app);
  const ifaceFile = path.join(srcDir, "infra-interface.yaml");

  if (!fs.existsSync(srcDir)) {
    note(
      `apps/src/${app}/ не найден.\nЗапустите: make apps-src-clone APP=${app}`,
      "Lifecycle",
    );
    return;
  }

  if (!fs.existsSync(ifaceFile)) {
    note(
      [
        `apps/src/${app}/infra-interface.yaml не найден.`,
        `Приложение не объявляет интерфейс infra.`,
        ``,
        `Документация: docs/runbooks/app-interface.md`,
        `Диагностика:  make app-capabilities APP=${app}`,
      ].join("\n"),
      "Lifecycle",
    );
    return;
  }

  for (;;) {
    const choice = ensure(
      await select({
        message: `Lifecycle · APP=${app} · ENV=${session.env}`,
        options: [
          { value: "capabilities", label: "Capabilities",           hint: "app-capabilities — версия + реализованные методы" },
          { value: "deploy",       label: "Deploy",                  hint: "app-deploy — helm upgrade / kubectl apply" },
          { value: "rollback",     label: "Rollback",                hint: "app-rollback [REVISION=N] — откат релиза" },
          { value: "status",       label: "Status",                  hint: "app-status — поды + статус деплоя" },
          { value: "logs",         label: "Logs  (Ctrl+C — стоп)",  hint: "app-logs [FOLLOW=1] [CONTAINER=name]" },
          { value: "migrate",      label: "Migrate",                 hint: "app-migrate — миграции БД" },
          { value: "seed",         label: "Seed  ⚠",                hint: "app-seed — начальные данные; двойное подтверждение" },
          { value: "shell",        label: "Shell",                   hint: "app-shell [CONTAINER=name] — exec в pod" },
          { value: "chgapp",       label: "Сменить APP",             hint: `текущий: ${app}` },
          { value: "back",         label: "Назад" },
        ],
      }),
    );

    if (choice === "back") return;

    const env = { APP: app };

    if (choice === "chgapp") {
      session.app = null;
      const next = await promptAppFromSession(session, { requireValue: true, persist: true });
      if (!next) return;
      return actionLifecycle(session);
    }

    if (choice === "capabilities") {
      await runTarget(session, "app-capabilities", env);
      continue;
    }

    if (choice === "deploy") {
      await runTarget(session, "app-deploy", env);
      continue;
    }

    if (choice === "rollback") {
      const rev = String(
        ensure(
          await text({
            message: "REVISION (Enter — helm rollback к предыдущему):",
            placeholder: "3",
            initialValue: "",
          }),
        ) ?? "",
      ).trim();
      if (rev) env.REVISION = rev;
      await runTarget(session, "app-rollback", env);
      continue;
    }

    if (choice === "status") {
      await runTarget(session, "app-status", env);
      continue;
    }

    if (choice === "logs") {
      const container = String(
        ensure(
          await text({
            message: "CONTAINER (Enter — без фильтра):",
            placeholder: "",
            initialValue: "",
          }),
        ) ?? "",
      ).trim();
      if (container) env.CONTAINER = container;
      env.FOLLOW = "1";
      await runTarget(session, "app-logs", env, { sigint: true });
      continue;
    }

    if (choice === "migrate") {
      await runTarget(session, "app-migrate", env);
      continue;
    }

    if (choice === "seed") {
      note(
        "seed может перезаписать или удалить данные в базе.\nУбедитесь, что это намеренное действие.",
        "⚠ Предупреждение",
      );
      if (!(await promptDangerous(`Запустить seed для APP=${app} ENV=${session.env}?`))) continue;
      env.SKIP_CONFIRM = "1";
      await runTarget(session, "app-seed", env);
      continue;
    }

    if (choice === "shell") {
      const container = String(
        ensure(
          await text({
            message: "CONTAINER (Enter — первый контейнер):",
            placeholder: "",
            initialValue: "",
          }),
        ) ?? "",
      ).trim();
      if (container) env.CONTAINER = container;
      await runTarget(session, "app-shell", env, { sigint: true });
      continue;
    }
  }
}
