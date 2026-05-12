// Wizard «Подключить приложение» — Сценарий 2 из docs/runbooks/usage-scenarios.md.
// Линейный поток шагов с breadcrumb «(N/M)». Делегирует обязательную часть
// работы существующим make-целям (apps-conf-template, apps-apply, apps-src-clone,
// app-local-src-hostpath-mount) и интерактивному конфигуратору
// scripts/configure-infra.mjs::runConfigure.

import { note, text, log } from "../io.mjs";
import fs from "node:fs";
import path from "node:path";

import { REPO_ROOT } from "../../lib/repo.mjs";
import { runConfigure } from "../../configure-infra.mjs";
import {
  ensure,
  promptYesNo,
  runTarget,
  promptServicesSelection,
} from "../prompts.mjs";
import { setSessionApp } from "../context.mjs";
import { makeStep } from "./lib.mjs";

const TITLE = "Подключить приложение";
const step = makeStep(TITLE);

/** Валидация имени приложения: a-z0-9 и `-`/`_`, не пусто. */
export function validateAppName(v) {
  const t = String(v ?? "").trim();
  if (!t) return "Имя обязательно";
  if (!/^[a-z][a-z0-9_-]*$/.test(t))
    return "Только латиница/цифры/-/_, начинать с буквы";
  return undefined;
}

/**
 * @param {{ env: string, app?: string|null }} session
 */
export async function wizardConnectApp(session) {
  note(
    [
      `ENV: ${session.env}.`,
      "Шаги: имя → шаблон конфигов → редактирование → merge → apps-apply → опц. clone/hostpath → опц. infra-interface.",
      "Каждый шаг можно пропустить.",
    ].join("\n"),
    TITLE,
  );

  // 1. APP
  step(1, 8, "Имя приложения (поле .apps[].name в apps/registry.yaml).");
  const appRaw = ensure(
    await text({
      message: "APP:",
      initialValue: session.app ?? "",
      validate: validateAppName,
    }),
  );
  const app = String(appRaw).trim();
  setSessionApp(session, app);

  const confDir = path.join(REPO_ROOT, "apps", "conf", app, session.env);
  const alreadyExists = fs.existsSync(confDir);

  // 2. apps-conf-template
  step(2, 8, alreadyExists
    ? `Каталог apps/conf/${app}/${session.env}/ уже существует — шаг шаблона можно пропустить.`
    : `Создаём шаблон apps/conf/${app}/${session.env}/ + запись в registry (enabled: false по умолчанию).`);
  const doTemplate = await promptYesNo(
    alreadyExists
      ? "Перезаписать шаблон (опасно — затрёт текущие файлы)?"
      : "Создать шаблон через apps-conf-template?",
    !alreadyExists,
  );
  if (doTemplate) {
    const skipReg = alreadyExists
      ? await promptYesNo("Не править apps/registry.yaml (SKIP_REGISTRY=1)?", true)
      : false;
    /** @type {Record<string,string>} */
    const env = { APP: app };
    if (skipReg) env.SKIP_REGISTRY = "1";
    if (!(await runTarget(session, "apps-conf-template", env))) {
      log.warn("apps-conf-template завершился с ошибкой — wizard остановлен.");
      return;
    }
  }

  // 3. редактирование секретов (просто открыть/показать путь)
  step(3, 8, `Заполните секреты в apps/conf/${app}/${session.env}/secrets.yaml.`);
  note(
    [
      `Путь: ${path.relative(REPO_ROOT, confDir)}/secrets.yaml`,
      "Откройте в редакторе, заполните поля (пароли, ключи, redis_db и т.д.).",
      "Когда сохраните — продолжайте.",
    ].join("\n"),
    "Редактирование",
  );
  await promptYesNo("Файл отредактирован — продолжать?", true);

  // 4. интерактивный конфигуратор (опционально)
  step(4, 8, "Можно дополнительно пройти интерактивный конфигуратор (apps/conf + registry, генерация паролей).");
  if (
    await promptYesNo(
      "Запустить конфигуратор сейчас? (его меню — отдельный поток)",
      false,
    )
  ) {
    try {
      await runConfigure({ standalone: false, session });
    } catch (e) {
      log.warn(`Конфигуратор завершился с ошибкой: ${String(e?.message || e)}`);
    }
  }

  // 5. merge-просмотр
  step(5, 8, "Проверим итоговую конфигурацию (apps-merge-print).");
  if (await promptYesNo("Показать итоговый merge?", true)) {
    await runTarget(session, "apps-merge-print", {});
  }

  // 6. apps-apply
  step(6, 8, "Применим учётки в кластер (apps-apply). Это создаст Secret <APP>-<service> в namespace приложения.");
  if (await promptYesNo("Запустить apps-apply сейчас?", true)) {
    const { enabled, exclude } = await promptServicesSelection({ kind: "apps-apply" });
    /** @type {Record<string,string>} */
    const env = {};
    if (enabled !== null) env.ENABLED_SERVICES = enabled;
    if (exclude !== null) env.EXCLUDE_SERVICES = exclude;
    if (await promptYesNo("Продолжать при ошибке на одном сервисе? (APPS_APPLY_CONTINUE_ON_ERROR=1)", false)) {
      env.APPS_APPLY_CONTINUE_ON_ERROR = "1";
    }
    await runTarget(session, "apps-apply", env);
  }

  // 7. опциональные хвосты: clone и hostpath
  step(7, 8, "Опционально: клон git-репо приложения и hostPath для local-разработки.");
  if (await promptYesNo("Клонировать репозиторий в apps/src/ (apps-src-clone, требует repo_url в registry)?", false)) {
    await runTarget(session, "apps-src-clone", { APP: app });
  }
  if (session.env === "local") {
    if (
      await promptYesNo(
        "Настроить hostPath-mount apps/src/<app>/ в pod приложения (ENV=local)?",
        false,
      )
    ) {
      await runHostpathStep(session, app);
    }
  }

  // 8. рыба infra-interface (только если apps/src/<APP>/ уже есть)
  const srcDir = path.join(REPO_ROOT, "apps", "src", app);
  if (fs.existsSync(srcDir)) {
    step(8, 8, `Сгенерировать рыбу infra-interface.yaml + Makefile.infra в apps/src/${app}/.`);
    if (await promptYesNo("Создать рыбу infra-interface (app-interface-init)?", true)) {
      await runTarget(session, "app-interface-init", { APP: app });
    }
  }

  note(
    [
      `Приложение ${app} подключено (или шаги пропущены).`,
      "Дальше: «Каждый день → Учётки и топики → движок» для проверки кред.",
      `Lifecycle: «Lifecycle приложения → Capabilities» после реализации infra-interface.`,
    ].join("\n"),
    `${TITLE} · готово`,
  );
}

async function runHostpathStep(session, app) {
  const workload = ensure(
    await text({
      message: "APP_LOCAL_K8S_WORKLOAD (например deployment/myapp или statefulset/...; обязательно):",
      validate: (s) =>
        s && String(s).trim().includes("/")
          ? undefined
          : "Формат: kind/name (deployment|statefulset|daemonset|pod)",
    }),
  );
  const mountPath = ensure(
    await text({
      message: "APP_LOCAL_SRC_MOUNT_PATH (путь внутри контейнера; обязательно):",
      validate: (s) =>
        s && String(s).trim().startsWith("/")
          ? undefined
          : "Должен начинаться с /",
    }),
  );
  const container = ensure(
    await text({
      message: "APP_LOCAL_SRC_CONTAINER (имя контейнера; Enter — все):",
      initialValue: "",
    }),
  );
  /** @type {Record<string,string>} */
  const env = {
    APP: app,
    APP_LOCAL_K8S_WORKLOAD: String(workload).trim(),
    APP_LOCAL_SRC_MOUNT_PATH: String(mountPath).trim(),
  };
  const c = String(container ?? "").trim();
  if (c) env.APP_LOCAL_SRC_CONTAINER = c;
  if (await promptYesNo("Смонтировать read-only? (APP_LOCAL_SRC_READ_ONLY=1)", false)) {
    env.APP_LOCAL_SRC_READ_ONLY = "1";
  }
  await runTarget(session, "app-local-src-hostpath-mount", env);
}
