// Wizard «Бутстрап нового ENV» — Сценарий 1 из docs/runbooks/usage-scenarios.md.
// Шаги: env-new → доступ к кластеру → образы → up → doctor.
// После env-new при необходимости переключает session.env на новый.

import { note, text, select, log } from "../io.mjs";
import fs from "node:fs";
import path from "node:path";

import { ENVIRONMENTS_DIR } from "../../lib/repo.mjs";
import {
  ensure,
  promptYesNo,
  promptServicesSelection,
  runTarget,
} from "../prompts.mjs";
import { setSessionEnv } from "../context.mjs";
import { makeStep } from "./lib.mjs";

const TITLE = "Бутстрап нового ENV";
const step = makeStep(TITLE);

export function validateEnvName(v) {
  const t = String(v ?? "").trim();
  if (!t) return "ENV обязателен";
  if (!/^[a-z][a-z0-9_-]*$/.test(t))
    return "Только латиница/цифры/-/_, начинать с буквы";
  return undefined;
}

/**
 * @param {{ env: string, app?: string|null }} session
 */
export async function wizardBootstrapEnv(session) {
  note(
    [
      "Подготовка нового окружения: рыба environments/<env>.{mk,yaml}, kubeconfig, образы, deploy, sanity.",
      `Текущий ENV сессии: ${session.env}.`,
      "Каждый шаг можно пропустить, если уже выполнен раньше.",
    ].join("\n"),
    TITLE,
  );

  // 1. ENV
  step(1, 5, "Имя нового окружения (или подтверждение текущего).");
  const envName = ensure(
    await text({
      message: `ENV (текущий: ${session.env}):`,
      initialValue: session.env,
      validate: validateEnvName,
    }),
  );
  const targetEnv = String(envName).trim();

  // env-new: создать скелет, если файлов нет
  const mkPath = path.join(ENVIRONMENTS_DIR, `${targetEnv}.mk`);
  const yamlPath = path.join(ENVIRONMENTS_DIR, `${targetEnv}.yaml`);
  const skeletonExists = fs.existsSync(mkPath) && fs.existsSync(yamlPath);

  if (skeletonExists) {
    note(`environments/${targetEnv}.{mk,yaml} уже есть — шаг env-new пропустим.`, "env-new");
  } else if (await promptYesNo(`Создать рыбу environments/${targetEnv}.{mk,yaml} и k8s/config/${targetEnv}? (make env-new)`, true)) {
    // env-new не использует ENV сессии — параметр идёт прямо в Make
    await runTarget(session, "env-new", { ENV: targetEnv });
  }

  // Переключить сессию на новый ENV для последующих шагов
  if (targetEnv !== session.env) {
    setSessionEnv(session, targetEnv);
    log.success(`ENV сессии переключён на ${targetEnv}.`);
  }

  // 2. Доступ к кластеру
  step(2, 5, "Доступ к кластеру: удалённый MicroK8s по SSH или локальный.");
  const accessKind = ensure(
    await select({
      message: "Тип кластера:",
      options: [
        { value: "remote", label: "Удалённый MicroK8s (SSH)", hint: "microk8s-setup + kubeconfig-fetch" },
        { value: "local",  label: "Локальный MicroK8s на этой машине", hint: "kubeconfig-microk8s-local" },
        { value: "skip",   label: "Пропустить шаг" },
      ],
    }),
  );

  if (accessKind === "remote") {
    note(
      [
        `Перед запуском убедитесь, что в environments/${targetEnv}.mk заданы SSH_HOST, SSH_USER, SSH_KEY.`,
        "Файл не в git — задайте параметры в редакторе, потом продолжайте.",
      ].join("\n"),
      "SSH",
    );
    await promptYesNo("Параметры SSH прописаны — продолжать?", true);
    if (await promptYesNo("Запустить microk8s-setup на удалённой ноде?", true)) {
      await runTarget(session, "microk8s-setup", {});
    }
    if (await promptYesNo("Запросить kubeconfig с ноды (kubeconfig-fetch)?", true)) {
      await runTarget(session, "kubeconfig-fetch", {});
    }
  } else if (accessKind === "local") {
    await runTarget(session, "kubeconfig-microk8s-local", {});
  }

  // 3. Образы
  step(3, 5, "Образы Bitnami: docker pull → tar → загрузка в registry microk8s.");
  if (await promptYesNo("Скачать образы и сохранить в tar (make images-save)?", true)) {
    await runTarget(session, "images-save", {});
  }
  const pushKind = ensure(
    await select({
      message: "Куда загружать образы:",
      options: [
        { value: "local",  label: "Локально (images-push)", hint: "на этой машине" },
        { value: "remote", label: "На удалённый узел (images-push-remote)", hint: "по SSH из environments/<env>.mk" },
        { value: "skip",   label: "Пропустить" },
      ],
    }),
  );
  if (pushKind === "local")  await runTarget(session, "images-push", {});
  if (pushKind === "remote") await runTarget(session, "images-push-remote", {});

  // 4. Развёртывание
  step(4, 5, "Развёртывание стека: helmfile up + apps-apply.");
  if (await promptYesNo("Запустить make up сейчас?", true)) {
    const { enabled, exclude } = await promptServicesSelection({ kind: "up" });
    /** @type {Record<string,string>} */
    const env = {};
    if (enabled !== null) env.ENABLED_SERVICES = enabled;
    if (exclude !== null) env.EXCLUDE_SERVICES = exclude;
    if (await promptYesNo("Пропустить apps-apply на этом этапе? (SKIP_APPS_APPLY=1)", false)) {
      env.SKIP_APPS_APPLY = "1";
    }
    await runTarget(session, "up", env);
  }

  // 5. Sanity
  step(5, 5, "Sanity: doctor (полная диагностика).");
  if (await promptYesNo("Запустить make doctor?", true)) {
    await runTarget(session, "doctor", {});
  }

  note(
    [
      `ENV ${targetEnv} готов (или часть шагов пропущена).`,
      "Дальше: «Каждый день → Состояние и логи» — проверить компоненты; «Сценарий: подключить приложение» — добавить app.",
    ].join("\n"),
    `${TITLE} · готово`,
  );
}
