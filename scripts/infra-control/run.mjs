#!/usr/bin/env node
// Infra control center TUI (@clack/prompts).

import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
/** @type {{ version?: string }} */
const infraPkg = require("../../package.json");
const INFRA_LAB_VERSION = infraPkg.version ?? "0.0.0";
import {
  intro,
  outro,
  cancel,
  isCancel,
  select,
  multiselect,
  confirm,
  text,
  log,
  note,
} from "../lib/clack-narrow.mjs";

import { runConfigure } from "../configure-infra.mjs";
import { runMake, reportMakeExit } from "../lib/make.mjs";
import { resolveYq, REPO_ROOT } from "../lib/repo.mjs";
import { patchRegistryEnabled } from "../lib/registry-yq.mjs";
import { persistHelmServiceVarsMk } from "../lib/env-mk-persist.mjs";
import {
  formatSessionEnvOptionLabel,
  listEnvironmentNames,
  pickSessionEnvInteractive,
} from "../lib/session-env-picker.mjs";
import { DATA_SERVICES } from "../lib/data-services.mjs";
import {
  HELP_VALUE,
  INTRO_NOTE,
  MENU_HELP,
  MULTI_ENABLED_HELP,
  MULTI_EXCLUDE_HELP,
} from "./menu-hints.mjs";

/** @typedef {{ env: string }} Session */

const NAV = {
  TASK: {
    BOOTSTRAP: "Бутстрап",
    CONFIGURE: "Конфигурирование",
    MANAGE: "Управление",
  },
  OBJECT: {
    SESSION: "Сессия",
    ENV: "Среда",
    SVC: "Сервис",
    APP: "Приложение",
  },
};

const HELM_SERVICES = [...DATA_SERVICES, "netdata"];

/** Подписи сервисов в меню (value остаётся slug для имён целей). */
function displayServiceName(id) {
  switch (id) {
    case "postgres":
      return "PostgreSQL";
    case "redis":
      return "Redis";
    case "kafka":
      return "Kafka";
    case "minio":
      return "MinIO";
    case "clickhouse":
      return "ClickHouse";
    case "rabbitmq":
      return "RabbitMQ";
    case "netdata":
      return "Netdata";
    default:
      return id;
  }
}

const HELM_OPTIONS = HELM_SERVICES.map((s) => ({
  value: s,
  label: s === "netdata" ? "Netdata (мониторинг)" : displayServiceName(s),
}));

const DIAG_SERVICE_OPTIONS = [
  ...DATA_SERVICES.map((value) => ({
    value,
    label: displayServiceName(value),
  })),
  {
    value: "monitoring",
    label: "Netdata (мониторинг)",
  },
];

/** @param {string} t */
function verifyTargetLabel(t) {
  if (t === "check-updates") return "Сводка: проверка обновлений чартов";
  const m = /^([\w-]+)-(check-updates|verify)$/.exec(t);
  if (m) {
    const name = displayServiceName(m[1]);
    if (m[2] === "verify") return `Проверить Helm-релиз: ${name}`;
    return `Проверить обновления чарта: ${name}`;
  }
  return t;
}

/** @param {string|undefined} s */
function validateEnvNameInput(s) {
  const t = String(s ?? "").trim();
  if (!t) return "Обязательно";
  if (!/^[a-zA-Z0-9][-a-zA-Z0-9_]*$/.test(t))
    return "Буквы, цифры, - и _; первый символ — буква или цифра";
  if (t.endsWith("-") || t.endsWith("_"))
    return "Имя не должно заканчиваться на - или _";
  return undefined;
}

function defaultEnv() {
  const n = listEnvironmentNames();
  if (!n.length) return "local";
  if (n.includes("local")) return "local";
  return n[0];
}

/** Интерактивный цикл infra-control (@clack). */
export function runInfraControl() {
  /** @type {Session} */
  const session = { env: defaultEnv() };

  const ensure = (value) => {
    if (isCancel(value)) {
      cancel("Отменено.");
      process.exit(0);
    }
    return value;
  };

  const OPT_HELP = { value: HELP_VALUE, label: "Справка" };

  /** @param {keyof typeof MENU_HELP | string} id */
  function showMenuHelp(id) {
    const block = MENU_HELP[id];
    if (block) note(block.body, block.title);
  }

  /** Перед multiselect: «Перейти» или показать справку. */
  async function promptBeforeMultiselect(helpBlock) {
    for (;;) {
      const pre = ensure(
        await select({
          message: "Дальше: выбор сервисов в списке (или сначала справка)",
          options: [
            { value: "go", label: "Перейти к выбору сервисов" },
            OPT_HELP,
          ],
        }),
      );
      if (pre === HELP_VALUE) {
        note(helpBlock.body, helpBlock.title);
        continue;
      }
      break;
    }
  }

  /** @param {Record<string,string|undefined>} [extra] */
  const runnerEnv = (extra = {}) => ({
    ENV: session.env,
    ...extra,
  });

  async function promptYesNo(message, initialValue = false) {
    return ensure(
      await confirm({
        message,
        initialValue,
      }),
    );
  }

  /** @returns {Promise<string|null>} null = все сервисы */
  async function promptEnabledServices(question) {
    const all = await promptYesNo(question, true);
    if (all) return null;
    await promptBeforeMultiselect(MULTI_ENABLED_HELP);
    const picked = ensure(
      await multiselect({
        message:
          "Выберите сервисы для этой операции (остальные не затрагиваются):",
        options: HELM_OPTIONS,
        required: true,
      }),
    );
    return picked.join(",");
  }

  /** @returns {Promise<string|null>} */
  async function promptExcludeServices() {
    const useEx = await promptYesNo(
      "Исключить часть сервисов из набора? (переменная EXCLUDE_SERVICES)",
      false,
    );
    if (!useEx) return null;
    await promptBeforeMultiselect(MULTI_EXCLUDE_HELP);
    const picked = ensure(
      await multiselect({
        message: "Исключить из операции (не трогать при helm/apps-apply):",
        options: HELM_OPTIONS,
        required: true,
      }),
    );
    return picked.join(",");
  }

  async function dangerousProceed(hint) {
    if (!(await promptYesNo(`${hint} Продолжить?`, false))) return false;
    if (!(await promptYesNo("Точно выполнить эту операцию?", false)))
      return false;
    return true;
  }

  async function promptTypedWord(expected, message) {
    const w = ensure(
      await text({
        message,
        validate: (v) =>
          String(v).trim() === expected ? undefined : `Введите: ${expected}`,
      }),
    );
    return String(w).trim();
  }

  async function promptSshHost() {
    let host = process.env.SSH_HOST || "";
    if (!host) {
      const h = ensure(
        await text({
          message:
            "SSH_HOST: hostname или IP сервера с MicroK8s (как для ssh user@host)",
          initialValue: "",
          validate: (v) =>
            v && String(v).trim() ? undefined : "SSH_HOST обязателен",
        }),
      );
      return String(h).trim();
    }
    const keep = await promptYesNo(
      `Использовать SSH_HOST=${host} из окружения?`,
      true,
    );
    if (!keep) {
      const h = ensure(
        await text({
          message:
            "SSH_HOST: новый хост (hostname или IP удалённого сервера)",
          initialValue: host,
          validate: (v) =>
            v && String(v).trim() ? undefined : "SSH_HOST обязателен",
        }),
      );
      return String(h).trim();
    }
    return host;
  }

  /** kubeconfig-microk8s-local: без SSH; путь — KUBECONFIG для текущего ENV сессии. */
  async function runKubeconfigMicrok8sLocal() {
    note(
      `Файл задаётся KUBECONFIG для ENV=${session.env} (см. environments/${session.env}.mk). SSH не используется.`,
      "Локальный MicroK8s",
    );
    if (session.env !== "local") {
      log.warn(
        `Для локального кластера обычно выберите в сессии ENV=local; сейчас ENV=${session.env}.`,
      );
    }
    await runTarget("kubeconfig-microk8s-local", {});
  }

  /** @param {string} appLabel */
  async function promptApp(appLabel = "APP") {
    const v = ensure(
      await text({
        message: `${appLabel}: короткое имя как в apps/registry.yaml (name), без пробелов:`,
        initialValue: "",
        validate: (s) =>
          s && String(s).trim() ? undefined : "Обязательное поле",
      }),
    );
    return String(v).trim();
  }

  /** @param {Record<string,string|undefined>} base */
  async function promptExtraEnv(base) {
    const out = { ...base };
    for (;;) {
      const line = await text({
        message:
          "Переменная окружения в виде KEY=value (как в сценариях репозитория). Пустой ввод — закончить список:",
        initialValue: "",
      });
      if (isCancel(line)) {
        cancel("Отменено.");
        process.exit(0);
      }
      const t = String(line).trim();
      if (!t) break;
      const eq = t.indexOf("=");
      if (eq <= 0) {
        log.warn("Пропуск: ожидается VAR=value");
        continue;
      }
      const k = t.slice(0, eq).trim();
      const val = t.slice(eq + 1).trim();
      if (!k) {
        log.warn("Пустой ключ");
        continue;
      }
      out[k] = val;
    }
    return out;
  }

  /** @param {string} target @param {Record<string,string|undefined>} env @param {{ sigint?: boolean }} [o] */
  async function runTarget(target, env, o = {}) {
    log.step(`→ ${target}`);
    const { code } = await runMake(target, {
      env: runnerEnv(env),
      handleSigint: o.sigint === true,
    });
    if (
      o.sigint &&
      (code === 130 || code === 0)
    ) {
      log.info("Поток остановлен, возврат в меню.");
    } else {
      reportMakeExit(target, code, log);
    }
    return (
      code === 0 ||
      (Boolean(o.sigint) && (code === 130 || code === 0))
    );
  }

  async function promptAppsApplyScopedEnv() {
    const enabled = await promptEnabledServices(
      "Применить apps-apply сразу ко всем data-сервисам (postgres, redis, …)?",
    );
    const exclude = await promptExcludeServices();
    /** @type {Record<string,string>} */
    const env = {};
    if (enabled !== null) env.ENABLED_SERVICES = enabled;
    if (exclude !== null) env.EXCLUDE_SERVICES = exclude;
    if (
      await promptYesNo(
        "При ошибке на одном сервисе не останавливать apps-apply? (APPS_APPLY_CONTINUE_ON_ERROR=1)",
        false,
      )
    )
      env.APPS_APPLY_CONTINUE_ON_ERROR = "1";
    return { env, enabled, exclude };
  }

  /**
   * @param {string|null} enabled
   * @param {string|null} exclude
   */
  async function maybePersistServiceProfile(session, enabled, exclude) {
    if (enabled === null && exclude === null) return;
    const yes = await promptYesNo(
      `Сохранить выбор сервисов в локальный файл environments/${session.env}.mk (как в README: ENABLED_SERVICES или EXCLUDE_SERVICES)?`,
      false,
    );
    if (!yes) return;
    try {
      /** @type {{ enabledCsv?: string, excludeCsv?: string }} */
      const spec =
        enabled !== null ? { enabledCsv: enabled } : { excludeCsv: exclude };
      const r = persistHelmServiceVarsMk(REPO_ROOT, session.env, spec);
      if (r.created) {
        note(
          "Файл создан с одной переменной состава сервисов. Для SSH_HOST, KUBECONFIG и т.д. используйте шаблон из make env-new или допишите вручную.",
          "environments/*.mk",
        );
      }
      log.success(`Записано: ${r.path}`);
    } catch (e) {
      log.error(String(e?.message || e));
    }
  }

  async function deactivateAppWizard() {
    const app = await promptApp();
    if (
      !(await promptYesNo(
        `Выставить в apps/registry.yaml для «${app}» enabled: false?`,
        true,
      ))
    )
      return;

    const yqBin = resolveYq();
    if (!patchRegistryEnabled(yqBin, app, false)) {
      log.error("Не удалось обновить apps/registry.yaml (yq).");
      return;
    }
    log.success(`registry: «${app}» → enabled: false`);

    if (
      await promptYesNo(
        "Запустить apps-apply (синхронизация merge с кластером)?",
        false,
      )
    ) {
      try {
        const { env, enabled, exclude } = await promptAppsApplyScopedEnv();
        const okApply = await runTarget("apps-apply", env);
        if (okApply)
          await maybePersistServiceProfile(session, enabled, exclude);
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }

    const drops = ensure(
      await multiselect({
        message:
          "Выберите движки для целей *-app-drop (учётки в сервисе и Secret; опасно). Пустой выбор — пропуск.",
        options: [
          { value: "pg-app-drop", label: "PostgreSQL — pg-app-drop" },
          { value: "redis-app-drop", label: "Redis — redis-app-drop" },
          { value: "kafka-app-drop", label: "Kafka — kafka-app-drop" },
          { value: "rabbitmq-app-drop", label: "RabbitMQ — rabbitmq-app-drop" },
          { value: "minio-app-drop", label: "MinIO — minio-app-drop" },
          { value: "clickhouse-app-drop", label: "ClickHouse — clickhouse-app-drop" },
        ],
        required: false,
      }),
    );

    if (!drops?.length) return;

    if (
      !(await dangerousProceed(
        `Будут вызваны цели удаления учёток для приложения «${app}».`,
      ))
    )
      return;

    await promptTypedWord(
      "DROP",
      `Введите DROP для подтверждения удаления учёток «${app}»:`,
    );

    const skipAll = await promptYesNo(
      "Передать SKIP_CONFIRM=1 во все вызовы (без доп. подтверждений в make)?",
      true,
    );

    for (const t of drops) {
      /** @type {Record<string,string>} */
      let env = { APP: app };
      if (skipAll) env.SKIP_CONFIRM = "1";
      try {
        await runTarget(t, env);
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  /** Доступ к кластеру при первичном бутстрапе (без status / uninstall). */
  async function clusterBootstrapMenu() {
    for (;;) {
      const action = ensure(
        await select({
          message: `Кластер — бутстрап (ENV=${session.env})`,
          options: [
            {
              value: "kcfetch",
              label: "Kubeconfig: удалённый сервер (SSH, microk8s на ноде)",
            },
            {
              value: "kclocal",
              label: "Kubeconfig: локальный MicroK8s (без SSH, эта машина)",
            },
            {
              value: "ssh",
              label: "Войти по SSH на сервер",

            },
            {
              value: "msetup",
              label: "Установить или проверить MicroK8s на сервере",

            },
            OPT_HELP,
            { value: "back", label: "Назад" },
          ],
        }),
      );
      if (action === HELP_VALUE) {
        showMenuHelp("clusterBootstrap");
        continue;
      }
      if (action === "back") return;

      try {
        if (action === "kcfetch") {
          await runTarget("kubeconfig-fetch", {
            SSH_HOST: await promptSshHost(),
          });
        } else if (action === "kclocal") {
          await runKubeconfigMicrok8sLocal();
        } else if (action === "ssh") {
          await runTarget("ssh", { SSH_HOST: await promptSshHost() });
        } else {
          await runTarget("microk8s-setup", {
            SSH_HOST: await promptSshHost(),
          });
        }
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function clusterManageMenu() {
    for (;;) {
      const action = ensure(
        await select({
          message: `Кластер и доступ (ENV=${session.env})`,
          options: [
            {
              value: "status",
              label: "Обзор кластера (ноды, поды, Helm)",

            },
            {
              value: "top",
              label: "Загрузка узлов: CPU и RAM суммарно",

            },
            {
              value: "kcinfo",
              label: "Информация о kubeconfig",

            },
            {
              value: "doctor",
              label: "Полная диагностика стека (doctor)",

            },
            {
              value: "kcfetch",
              label: "Kubeconfig: удалённый сервер (SSH, microk8s на ноде)",
            },
            {
              value: "kclocal",
              label: "Kubeconfig: локальный MicroK8s (без SSH, эта машина)",
            },
            {
              value: "ssh",
              label: "Войти по SSH на сервер",

            },
            {
              value: "msetup",
              label: "Установить или проверить MicroK8s на сервере",

            },
            {
              value: "muninstall",
              label: "Удалить MicroK8s на сервере (опасно)",

            },
            OPT_HELP,
            { value: "back", label: "Назад" },
          ],
        }),
      );
      if (action === HELP_VALUE) {
        showMenuHelp("clusterManage");
        continue;
      }
      if (action === "back") return;

      try {
        if (action === "status") await runTarget("status", {});
        else if (action === "top") await runTarget("top-totals", {});
        else if (action === "kcinfo") await runTarget("kubeconfig-info", {});
        else if (action === "doctor") await runTarget("doctor", {});
        else if (action === "kcfetch") {
          await runTarget("kubeconfig-fetch", {
            SSH_HOST: await promptSshHost(),
          });
        } else if (action === "kclocal") {
          await runKubeconfigMicrok8sLocal();
        } else if (action === "ssh") {
          await runTarget("ssh", { SSH_HOST: await promptSshHost() });
        } else if (action === "msetup") {
          await runTarget("microk8s-setup", {
            SSH_HOST: await promptSshHost(),
          });
        } else if (action === "muninstall") {
          const ok = await dangerousProceed(
            "Удаление microk8s на удалённом хосте.",
          );
          if (!ok) continue;
          await runTarget("microk8s-uninstall", {
            SSH_HOST: await promptSshHost(),
          });
        }
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function helmGlobal(kind) {
    const enabled = await promptEnabledServices(
      `Распространить «${kind}» на все сервисы набора (postgres, redis, …)? Если нет — ограничьте список.`,
    );
    const exclude = await promptExcludeServices();
    const env = {};
    if (enabled !== null) env.ENABLED_SERVICES = enabled;
    if (exclude !== null) env.EXCLUDE_SERVICES = exclude;
    if (kind === "up") {
      if (await promptYesNo(
        "После успешного helm не запускать применение apps/conf к кластеру? (SKIP_APPS_APPLY=1)",
        false,
      ))
        env.SKIP_APPS_APPLY = "1";
      if (
        await promptYesNo(
          "Если apps-apply упадёт на одном сервисе, продолжить остальные? (APPS_APPLY_CONTINUE_ON_ERROR=1)",
          false,
        )
      )
        env.APPS_APPLY_CONTINUE_ON_ERROR = "1";
    }
    if (kind === "down") {
      if (!(await dangerousProceed("helmfile destroy выбранного набора.")))
        return;
    }
    const okMake = await runTarget(kind, env);
    if (okMake)
      await maybePersistServiceProfile(session, enabled, exclude);
  }

  async function helmPerServiceMenu() {
    svcLoop: for (;;) {
      const svc = ensure(
        await select({
          message: "Компонент стека",
          options: [...HELM_OPTIONS, OPT_HELP, { value: "__back__", label: "Назад" }],
        }),
      );
      if (svc === HELP_VALUE) {
        showMenuHelp("helmPickComponent");
        continue;
      }
      if (svc === "__back__") return;
      for (;;) {
        const act = ensure(
          await select({
            message: `${displayServiceName(svc)}: действие`,
            options: [
              {
                value: "up",
                label: "Развернуть или обновить",

              },
              {
                value: "diff",
                label: "Показать отличия с кластером",

              },
              {
                value: "down",
                label: "Уничтожить релиз (опасно)",

              },
              OPT_HELP,
              { value: "back", label: "Назад" },
            ],
          }),
        );
        if (act === HELP_VALUE) {
          showMenuHelp("helmPerServiceAction");
          continue;
        }
        if (act === "back") continue svcLoop;
        const realTarget =
          svc === "netdata" ? `monitoring-${act}` : `${svc}-${act}`;
        if (act === "down" && !(await dangerousProceed("Уничтожение релиза (helm destroy).")))
          continue;
        await runTarget(realTarget, {});
        return;
      }
    }
  }

  /** Весь набор: up / diff / down (уровень среды). */
  async function helmMenuGlobalFull() {
    for (;;) {
      const action = ensure(
        await select({
          message: `Helm — весь набор (ENV=${session.env})`,
          options: [
            {
              value: "up",
              label: "Развернуть весь стек (или выбрать сервисы)",

            },
            {
              value: "diff",
              label: "Сравнить весь набор с кластером",

            },
            {
              value: "down",
              label: "Уничтожить весь набор релизов (опасно)",

            },
            OPT_HELP,
            { value: "back", label: "Назад" },
          ],
        }),
      );
      if (action === HELP_VALUE) {
        showMenuHelp("helmMenuGlobalFull");
        continue;
      }
      if (action === "back") return;

      try {
        await helmGlobal(action);
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  /** diff по набору и поштучные релизы (уровень сервиса). */
  async function helmMenuServiceOps() {
    for (;;) {
      const action = ensure(
        await select({
          message: `Helm — сервис (ENV=${session.env})`,
          options: [
            {
              value: "diff",
              label: "Сравнить весь набор с кластером",

            },
            {
              value: "one",
              label: "Один компонент: развернуть / diff / уничтожить",

            },
            OPT_HELP,
            { value: "back", label: "Назад" },
          ],
        }),
      );
      if (action === HELP_VALUE) {
        showMenuHelp("helmMenuServiceOps");
        continue;
      }
      if (action === "back") return;

      try {
        if (action === "one") await helmPerServiceMenu();
        else await helmGlobal("diff");
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function imagesMenu() {
    for (;;) {
      const action = ensure(
        await select({
          message: "Образы",
          options: [
            {
              value: "save",
              label: "Сохранить образы в tar локально",

            },
            {
              value: "push",
              label: "Загрузить образы в registry",

            },
            {
              value: "pushr",
              label: "Отправить tar на сервер и выполнить там push",

            },
            OPT_HELP,
            { value: "back", label: "Назад" },
          ],
        }),
      );
      if (action === HELP_VALUE) {
        showMenuHelp("imagesMenu");
        continue;
      }
      if (action === "back") return;

      try {
        let env = {};
        if (await promptYesNo(
          "Обработать только один data-сервис? (иначе — цикл по всем из списка)",
          false,
        )) {
          for (;;) {
            const s = ensure(
              await select({
                message: "Сервис для образов",
                options: [
                  ...DATA_SERVICES.map((v) => ({
                    value: v,
                    label: displayServiceName(v),
                  })),
                  OPT_HELP,
                  { value: "__back__", label: "Назад" },
                ],
              }),
            );
            if (s === HELP_VALUE) {
              showMenuHelp("imagesPickService");
              continue;
            }
            if (s === "__back__") break;
            env.SERVICE = s;
            break;
          }
        }
        if (action === "save") await runTarget("images-save", env);
        else if (action === "push") await runTarget("images-push", env);
        else await runTarget("images-push-remote", {
          ...env,
          SSH_HOST: await promptSshHost(),
        });
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function runAppsConfTemplateFlow() {
    const app = await promptApp();
    let env = { APP: app };
    if (await promptYesNo(
      "Не изменять apps/registry.yaml при создании шаблона? (SKIP_REGISTRY=1)",
      false,
    ))
      env.SKIP_REGISTRY = "1";
    await runTarget("apps-conf-template", env);
  }

  async function runAppsApplyFlow() {
    try {
      const { env, enabled, exclude } = await promptAppsApplyScopedEnv();
      const okApply = await runTarget("apps-apply", env);
      if (okApply)
        await maybePersistServiceProfile(session, enabled, exclude);
    } catch (e) {
      log.error(String(e?.stack || e));
    }
  }

  async function bootstrapAppMenu() {
    for (;;) {
      const action = ensure(
        await select({
          message: `${NAV.TASK.BOOTSTRAP} — ${NAV.OBJECT.APP} (ENV=${session.env})`,
          options: [
            {
              value: "clone",
              label: "Клонировать репозиторий приложения (apps/src)",

            },
            {
              value: "tpl",
              label: "Создать каталог apps/conf из шаблона",

            },
            {
              value: "cfg",
              label: "Конфигуратор: секреты и registry",

            },
            OPT_HELP,
            { value: "back", label: "Назад" },
          ],
        }),
      );
      if (action === HELP_VALUE) {
        showMenuHelp("bootstrapApp");
        continue;
      }
      if (action === "back") return;

      try {
        if (action === "cfg") {
          await runConfigure({ standalone: false, session });
        } else if (action === "tpl") {
          await runAppsConfTemplateFlow();
        } else {
          const app = await promptApp();
          await runTarget("apps-src-clone", { APP: app });
        }
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function runAppsLocalSrcHelmSetsFlow() {
    if (session.env !== "local") {
      note(
        "Вывод работает только при ENV=local (меню «Сессия»).",
        "Helm —set для hostPath",
      );
      return;
    }
    const app = await promptApp();
    await runTarget("apps-local-src-helm-sets", { APP: app });
  }

  async function configureAppMenu() {
    for (;;) {
      const action = ensure(
        await select({
          message: `${NAV.TASK.CONFIGURE} — ${NAV.OBJECT.APP} (ENV=${session.env})`,
          options: [
            {
              value: "merge",
              label: "Показать итоговую конфигурацию (merge в stdout)",

            },
            {
              value: "helmsets",
              label: "Вывести helm --set для local hostPath (чарт приложения)",

            },
            {
              value: "cfg",
              label: "Конфигуратор: секреты и registry",

            },
            OPT_HELP,
            { value: "back", label: "Назад" },
          ],
        }),
      );
      if (action === HELP_VALUE) {
        showMenuHelp("configureApp");
        continue;
      }
      if (action === "back") return;

      try {
        if (action === "cfg") {
          await runConfigure({ standalone: false, session });
        } else if (action === "helmsets") {
          await runAppsLocalSrcHelmSetsFlow();
        } else {
          await runTarget("apps-merge-print", {});
        }
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function runAppLocalSrcHostpathFlow() {
    if (session.env !== "local") {
      note("Смонтировать hostPath можно только при ENV=local (меню «Сессия»).", "MicroK8s");
      return;
    }
    const app = await promptApp();
    const wk = ensure(
      await text({
        message:
          "Workload в namespace приложения (app_ns из merge): kind/имя — deployment|statefulset|daemonset|pod",
        initialValue: `deployment/${app}`,
        validate: (s) => {
          const t = String(s ?? "").trim();
          if (!t) return "Обязательное поле";
          if (!t.includes("/")) return "Ожидается kind/имя, например deployment/api";
          return undefined;
        },
      }),
    );
    const mountPath = ensure(
      await text({
        message: "Путь внутри контейнера (volumeMount mountPath):",
        initialValue: "/work/src",
        validate: (s) => (String(s ?? "").trim() ? undefined : "Обязательное поле"),
      }),
    );
    const cont = await text({
      message: "Контейнер (пусто = смонтировать во все контейнеры шаблона):",
      initialValue: "",
    });
    if (isCancel(cont)) {
      cancel("Отменено.");
      process.exit(0);
    }
    /** @type {Record<string, string>} */
    const env = {
      APP: app,
      APP_LOCAL_K8S_WORKLOAD: String(wk).trim(),
      APP_LOCAL_SRC_MOUNT_PATH: String(mountPath).trim(),
    };
    const ct = String(cont ?? "").trim();
    if (ct) env.APP_LOCAL_SRC_CONTAINER = ct;
    await runTarget("app-local-src-hostpath-mount", env);
  }

  async function manageAppMenu() {
    for (;;) {
      /** @type {{ value: string; label: string }[]} */
      const appOpts = [
        {
          value: "deact",
          label: "Деактивировать приложение в registry и снять учётки",
        },
        {
          value: "apply",
          label: "Применить учётки и конфиги приложений в кластер",
        },
        {
          value: "acc",
          label: "Логины приложений в БД и брокерах",
        },
        {
          value: "kafka",
          label: "Топики Kafka (создание по имени приложения)",
        },
      ];
      if (session.env === "local") {
        appOpts.push({
          value: "localsrc",
          label: "MicroK8s: hostPath apps/src/<APP> → workload",
        });
      }
      const action = ensure(
        await select({
          message: `${NAV.TASK.MANAGE} — ${NAV.OBJECT.APP} (ENV=${session.env})`,
          options: [...appOpts, OPT_HELP, { value: "back", label: "Назад" }],
        }),
      );
      if (action === HELP_VALUE) {
        showMenuHelp("manageApp");
        if (session.env === "local") {
          showMenuHelp("manageAppLocalHostpath");
        }
        continue;
      }
      if (action === "back") return;

      try {
        if (action === "deact") await deactivateAppWizard();
        else if (action === "apply") await runAppsApplyFlow();
        else if (action === "localsrc") await runAppLocalSrcHostpathFlow();
        else if (action === "acc") await accountsMenu();
        else await kafkaOperationsMenu("manageApp");
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function bootstrapEnvMenu() {
    for (;;) {
      const action = ensure(
        await select({
          message: `${NAV.TASK.BOOTSTRAP} — ${NAV.OBJECT.ENV} (ENV=${session.env})`,
          options: [
            {
              value: "new",
              label: "Создать скелет окружения (файлы, values)",

            },
            {
              value: "cluster",
              label: "Доступ к кластеру: kubeconfig, SSH, MicroK8s",

            },
            OPT_HELP,
            { value: "back", label: "Назад" },
          ],
        }),
      );
      if (action === HELP_VALUE) {
        showMenuHelp("bootstrapEnv");
        continue;
      }
      if (action === "back") return;

      try {
        if (action === "new") {
          const e = ensure(
            await text({
              message:
                "Имя нового окружения (латиница, цифры, - и _): станет ENV и суффиксом файлов",
              validate: validateEnvNameInput,
            }),
          );
          await runTarget("env-new", { ENV: String(e).trim() });
          session.env = String(e).trim();
        } else {
          await clusterBootstrapMenu();
        }
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function bootstrapServiceMenu() {
    for (;;) {
      const action = ensure(
        await select({
          message: `${NAV.TASK.BOOTSTRAP} — ${NAV.OBJECT.SVC} (ENV=${session.env})`,
          options: [
            {
              value: "kb",
              label: "Инициализировать подключение к Kafka (bootstrap)",

            },
            {
              value: "helmup",
              label: "Развернуть весь стек Helm (или выбрать сервисы)",

            },
            OPT_HELP,
            { value: "back", label: "Назад" },
          ],
        }),
      );
      if (action === HELP_VALUE) {
        showMenuHelp("bootstrapSvc");
        continue;
      }
      if (action === "back") return;

      try {
        if (action === "kb") await runTarget("kafka-bootstrap", {});
        else await helmGlobal("up");
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function manageEnvMenu() {
    for (;;) {
      const action = ensure(
        await select({
          message: `${NAV.TASK.MANAGE} — ${NAV.OBJECT.ENV} (ENV=${session.env})`,
          options: [
            {
              value: "cluster",
              label: "Кластер и доступ",

            },
            {
              value: "bu",
              label: "Сохранить секреты и манифесты окружения в архив",

            },
            {
              value: "img",
              label: "Образы контейнеров",

            },
            {
              value: "helm",
              label: "Релизы Helm: весь набор",

            },
            OPT_HELP,
            { value: "back", label: "Назад" },
          ],
        }),
      );
      if (action === HELP_VALUE) {
        showMenuHelp("manageEnv");
        continue;
      }
      if (action === "back") return;

      try {
        if (action === "cluster") await clusterManageMenu();
        else if (action === "bu") {
          if (await dangerousProceed("Секреты уйдут в локальный архив."))
            await runTarget("env-backup", {});
        } else if (action === "img") {
          await imagesMenu();
        } else {
          await helmMenuGlobalFull();
        }
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function manageServiceMenu() {
    for (;;) {
      const action = ensure(
        await select({
          message: `${NAV.TASK.MANAGE} — ${NAV.OBJECT.SVC} (ENV=${session.env})`,
          options: [
            {
              value: "helm",
              label: "Helm: сравнение и по компонентам",

            },
            {
              value: "diag",
              label: "Диагностика сервисов",

            },
            {
              value: "verify",
              label: "Проверки чартов и обновления",

            },
            {
              value: "kafka",
              label: "Kafka: сброс данных и работа с топиками",

            },
            OPT_HELP,
            { value: "back", label: "Назад" },
          ],
        }),
      );
      if (action === HELP_VALUE) {
        showMenuHelp("manageSvc");
        continue;
      }
      if (action === "back") return;

      try {
        if (action === "helm") await helmMenuServiceOps();
        else if (action === "diag") await diagnosticsMenu();
        else if (action === "verify") await verifyMenu();
        else await kafkaOperationsMenu("manageSvc");
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  function verifyTargetsList() {
    const bitnami = HELM_SERVICES.filter((x) => x !== "netdata").map(
      (s) => `${s}-verify`,
    );
    const chk = HELM_SERVICES.filter((x) => x !== "netdata").map(
      (s) => `${s}-check-updates`,
    );
    return [...bitnami, "check-updates", ...chk];
  }

  async function verifyMenu() {
    const opts = verifyTargetsList().map((v) => ({
      value: v,
      label: verifyTargetLabel(v),
    }));
    for (;;) {
      const t = ensure(
        await select({
          message:
            "Проверка Helm и доступных обновлений чартов (без автоматического деплоя)",
          options: [
            ...opts,
            OPT_HELP,
            { value: "__back__", label: "Назад" },
          ],
        }),
      );
      if (t === HELP_VALUE) {
        showMenuHelp("verifyMenu");
        continue;
      }
      if (t === "__back__") return;

      try {
        await runTarget(t, {});
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function postgresAccountsMenu() {
    for (;;) {
      const action = ensure(
        await select({
          message: "Учётки — PostgreSQL",
          options: [
            {
              value: "create",
              label: "Создать БД и пользователя для приложения",

            },
            {
              value: "creds",
              label: "Показать логин и пароль",

            },
            {
              value: "psql",
              label: "Открыть интерактивный psql",

            },
            {
              value: "drop",
              label: "Удалить учётку приложения (опасно)",

            },
            {
              value: "verify",
              label: "Проверить учётку в кластере",

            },
            OPT_HELP,
            { value: "back", label: "Назад" },
          ],
        }),
      );
      if (action === HELP_VALUE) {
        showMenuHelp("postgresAccounts");
        continue;
      }
      if (action === "back") return;

      const app = await promptApp();

      try {
        if (action === "create") {
          let env = { APP: app };
          if (await promptYesNo("Задать APP_NS?", false)) {
            const ns = ensure(
              await text({
                message:
                  "APP_NS: namespace в Kubernetes (часто совпадает с APP)",
                initialValue: app,
              }),
            );
            env.APP_NS = String(ns).trim();
          }
          if (await promptYesNo("Задать POSTGRES_ADMIN_PASSWORD?", false)) {
            const p = ensure(await text({ message: "POSTGRES_ADMIN_PASSWORD:" }));
            env.POSTGRES_ADMIN_PASSWORD = String(p);
          }
          if (await promptYesNo("Дополнительные переменные окружения?", false))
            env = await promptExtraEnv(env);
          await runTarget("pg-app-create", env);
        } else if (action === "creds") {
          await runTarget("pg-app-show-creds", { APP: app });
        } else if (action === "psql") {
          for (;;) {
            const which = ensure(
              await select({
                message:
                  "Способ запуска psql к базе этого приложения (две именованные цели)",
                options: [
                  {
                    value: "pg-app-psql",
                    label: "Прямое подключение psql к приложению",

                  },
                  {
                    value: "postgres-db",
                    label: "Подключение через обёртку postgres-db",

                  },
                  OPT_HELP,
                  { value: "__back__", label: "Назад" },
                ],
              }),
            );
            if (which === HELP_VALUE) {
              showMenuHelp("postgresPsqlMode");
              continue;
            }
            if (which === "__back__") break;
            await runTarget(which, { APP: app });
            break;
          }
        } else if (action === "verify") {
          await runTarget("pg-app-verify", { APP: app });
        } else {
          await promptTypedWord("DROP", `Введите DROP для удаления учётки ${app}:`);
          let env = { APP: app };
          if (await promptYesNo("SKIP_CONFIRM=1?", false)) env.SKIP_CONFIRM = "1";
          if (await promptYesNo("Доп. переменные окружения?", false))
            env = await promptExtraEnv(env);
          await runTarget("pg-app-drop", env);
        }
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function redisAccountsMenu() {
    for (;;) {
      const action = ensure(
        await select({
          message: "Учётки — Redis",
          options: [
            {
              value: "create",
              label: "Создать учётку (ACL) для приложения",

            },
            {
              value: "creds",
              label: "Показать пароль и параметры",

            },
            {
              value: "drop",
              label: "Удалить учётку (опасно)",

            },
            OPT_HELP,
            { value: "back", label: "Назад" },
          ],
        }),
      );
      if (action === HELP_VALUE) {
        showMenuHelp("redisAccounts");
        continue;
      }
      if (action === "back") return;

      const app = await promptApp();

      try {
        if (action === "creds") {
          await runTarget("redis-app-show-creds", { APP: app });
        } else if (action === "drop") {
          await promptTypedWord("DROP", "Введите DROP для удаления:");
          let env = { APP: app };
          if (await promptYesNo("SKIP_CONFIRM=1?", false)) env.SKIP_CONFIRM = "1";
          if (await promptYesNo("Дополнительные переменные?", false))
            env = await promptExtraEnv(env);
          await runTarget("redis-app-drop", env);
        } else {
          let env = { APP: app };
          const nsAsk = await promptYesNo("APP_NS?", false);
          if (nsAsk) {
            const ns = ensure(await text({ message: "APP_NS: namespace в Kubernetes (часто совпадает с APP)", initialValue: app }));
            env.APP_NS = String(ns).trim();
          }
          if (await promptYesNo("REDIS_DB числом явно?", false)) {
            const d = ensure(await text({ message: "REDIS_DB:", initialValue: "0" }));
            env.REDIS_DB = String(d).trim();
          }
          if (await promptYesNo("Доп. переменные (REDIS_AUTH_*, …)?", false))
            env = await promptExtraEnv(env);
          await runTarget("redis-app-create", env);
        }
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function kafkaAccountsMenu() {
    for (;;) {
      const action = ensure(
        await select({
          message: "Учётки — Kafka",
          options: [
            {
              value: "create",
              label: "Создать SASL-пользователя для приложения",

            },
            {
              value: "creds",
              label: "Показать параметры и пароль из Secret",

            },
            {
              value: "drop",
              label: "Удалить учётку (опасно)",

            },
            OPT_HELP,
            { value: "back", label: "Назад" },
          ],
        }),
      );
      if (action === HELP_VALUE) {
        showMenuHelp("kafkaAccounts");
        continue;
      }
      if (action === "back") return;

      const app = await promptApp();

      try {
        if (action === "create") {
          let env = { APP: app };
          if (await promptYesNo("APP_NS?", false))
            env.APP_NS = String(
              ensure(await text({ message: "APP_NS: namespace в Kubernetes (часто совпадает с APP)", initialValue: app })),
            ).trim();
          if (await promptYesNo("Доп. переменные?", false))
            env = await promptExtraEnv(env);
          await runTarget("kafka-app-create", env);
        } else if (action === "creds") {
          await runTarget("kafka-app-show-creds", { APP: app });
        } else {
          await promptTypedWord("DROP", "Введите DROP:");
          let env = { APP: app };
          if (await promptYesNo("SKIP_CONFIRM=1?", false)) env.SKIP_CONFIRM = "1";
          if (await promptYesNo("Доп. переменные (APP_USER, …)?", false))
            env = await promptExtraEnv(env);
          await runTarget("kafka-app-drop", env);
        }
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function minioAccountsMenu() {
    for (;;) {
      const action = ensure(
        await select({
          message: "Учётки — MinIO",
          options: [
            {
              value: "create",
              label: "Создать S3-пользователя и бакеты",

            },
            {
              value: "append",
              label: "Добавить бакет к учётке",

            },
            {
              value: "creds",
              label: "Показать ключи и эндпоинты из Secret",

            },
            {
              value: "drop",
              label: "Удалить учётку (опасно)",

            },
            OPT_HELP,
            { value: "back", label: "Назад" },
          ],
        }),
      );
      if (action === HELP_VALUE) {
        showMenuHelp("minioAccounts");
        continue;
      }
      if (action === "back") return;

      try {
        if (action === "append") {
          const app = await promptApp();
          let env = { APP: app };
          const bkt = ensure(
            await text({ message: "BUCKET:", validate: (s) => s?.trim() || "Нужно" }),
          );
          env.BUCKET = String(bkt).trim();
          if (await promptYesNo("PREFIX/ACCESS_* и др. переменные?", false))
            env = await promptExtraEnv(env);
          await runTarget("minio-app-append", env);
          continue;
        }

        const app = await promptApp();

        if (action === "create") {
          let env = { APP: app };
          if (await promptYesNo("APP_NS?", false))
            env.APP_NS = String(
              ensure(await text({ message: "APP_NS: namespace в Kubernetes (часто совпадает с APP)", initialValue: app })),
            ).trim();
          if (await promptYesNo("Подставить минимально BUCKET?", false)) {
            const bkt = ensure(await text({ message: "BUCKET:" }));
            env.BUCKET = String(bkt).trim();
          }
          if (
            await promptYesNo(
              "Открыть ввод множества опций (PUBLIC_READ, …)?",
              false,
            )
          )
            env = await promptExtraEnv(env);
          await runTarget("minio-app-create", env);
        } else if (action === "creds") {
          await runTarget("minio-app-show-creds", { APP: app });
        } else {
          await promptTypedWord("DROP", "Введите DROP:");
          let env = { APP: app };
          if (await promptYesNo("SKIP_CONFIRM=1?", false)) env.SKIP_CONFIRM = "1";
          if (await promptYesNo("MINIO_REMOVE_BUCKETS=1?", false))
            env.MINIO_REMOVE_BUCKETS = "1";
          if (await promptYesNo("Доп. переменные?", false))
            env = await promptExtraEnv(env);
          await runTarget("minio-app-drop", env);
        }
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function clickhouseAccountsMenu() {
    for (;;) {
      const action = ensure(
        await select({
          message: "Учётки — ClickHouse",
          options: [
            {
              value: "create",
              label: "Создать пользователя и базу для приложения",

            },
            {
              value: "creds",
              label: "Показать логин и пароль из Secret",

            },
            {
              value: "drop",
              label: "Удалить учётку (опасно)",

            },
            OPT_HELP,
            { value: "back", label: "Назад" },
          ],
        }),
      );
      if (action === HELP_VALUE) {
        showMenuHelp("clickhouseAccounts");
        continue;
      }
      if (action === "back") return;

      const app = await promptApp();

      try {
        if (action === "create") {
          let env = { APP: app };
          if (await promptYesNo("APP_NS?", false))
            env.APP_NS = String(
              ensure(await text({ message: "APP_NS: namespace в Kubernetes (часто совпадает с APP)", initialValue: app })),
            ).trim();
          if (await promptYesNo("Больше полей через KEY=value?", false))
            env = await promptExtraEnv(env);
          await runTarget("clickhouse-app-create", env);
        } else if (action === "creds") {
          await runTarget("clickhouse-app-show-creds", { APP: app });
        } else {
          await promptTypedWord("DROP", "Введите DROP:");
          let env = { APP: app };
          if (await promptYesNo("SKIP_CONFIRM=1?", false)) env.SKIP_CONFIRM = "1";
          if (await promptYesNo("Доп. переменные (DB, APP_USER …)?", false))
            env = await promptExtraEnv(env);
          await runTarget("clickhouse-app-drop", env);
        }
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function rabbitAccountsMenu() {
    for (;;) {
      const action = ensure(
        await select({
          message: "Учётки — RabbitMQ",
          options: [
            {
              value: "create",
              label: "Создать пользователя и vhost для приложения",

            },
            {
              value: "creds",
              label: "Показать URL и пароль из Secret",

            },
            {
              value: "drop",
              label: "Удалить учётку (опасно)",

            },
            OPT_HELP,
            { value: "back", label: "Назад" },
          ],
        }),
      );
      if (action === HELP_VALUE) {
        showMenuHelp("rabbitAccounts");
        continue;
      }
      if (action === "back") return;

      const app = await promptApp();

      try {
        if (action === "create") {
          let env = { APP: app };
          if (await promptYesNo("APP_NS?", false))
            env.APP_NS = String(
              ensure(await text({ message: "APP_NS: namespace в Kubernetes (часто совпадает с APP)", initialValue: app })),
            ).trim();
          if (await promptYesNo("Доп. переменные?", false))
            env = await promptExtraEnv(env);
          await runTarget("rabbitmq-app-create", env);
        } else if (action === "creds") {
          await runTarget("rabbitmq-app-show-creds", { APP: app });
        } else {
          await promptTypedWord("DROP", "Введите DROP:");
          let env = { APP: app };
          if (await promptYesNo("SKIP_CONFIRM=1?", false)) env.SKIP_CONFIRM = "1";
          if (await promptYesNo("Доп. переменные?", false))
            env = await promptExtraEnv(env);
          await runTarget("rabbitmq-app-drop", env);
        }
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function accountsMenu() {
    for (;;) {
      const eng = ensure(
        await select({
          message: `Учётки приложений (ENV=${session.env})`,
          options: [
            {
              value: "pg",
              label: "PostgreSQL",

            },
            { value: "rd", label: "Redis" },
            { value: "ka", label: "Kafka" },
            { value: "mi", label: "MinIO" },
            { value: "ch", label: "ClickHouse" },
            { value: "rmq", label: "RabbitMQ" },
            OPT_HELP,
            { value: "back", label: "Назад" },
          ],
        }),
      );

      try {
        if (eng === HELP_VALUE) {
          showMenuHelp("accountsEngine");
          continue;
        }
        if (eng === "back") return;
        if (eng === "pg") await postgresAccountsMenu();
        else if (eng === "rd") await redisAccountsMenu();
        else if (eng === "ka") await kafkaAccountsMenu();
        else if (eng === "mi") await minioAccountsMenu();
        else if (eng === "ch") await clickhouseAccountsMenu();
        else await rabbitAccountsMenu();
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  /** @param {"manageSvc"|"manageApp"} scope */
  async function kafkaOperationsMenu(scope) {
    for (;;) {
      /** @type {{ value: string, label: string }[]} */
      const opts =
        scope === "manageSvc"
          ? [
              {
                value: "reset",
                label: "Сбросить данные кластера Kafka (опасно)",

              },
              {
                value: "tal",
                label: "Изменить параметры топика",

              },
              {
                value: "td",
                label: "Показать описание топика",

              },
              {
                value: "tl",
                label: "Список топиков",

              },
            ]
          : [
              {
                value: "tcr",
                label: "Создать топик для приложения (по суффиксу)",

              },
              {
                value: "tal",
                label: "Изменить параметры топика",

              },
              {
                value: "td",
                label: "Показать описание топика",

              },
              {
                value: "tl",
                label: "Список топиков",

              },
            ];
      const action = ensure(
        await select({
          message:
            scope === "manageSvc"
              ? `Kafka: кластер и топики (ENV=${session.env})`
              : `Kafka: топики и приложение (ENV=${session.env})`,
          options: [...opts, OPT_HELP, { value: "back", label: "Назад" }],
        }),
      );
      if (action === HELP_VALUE) {
        showMenuHelp(scope === "manageSvc" ? "kafkaOpsSvc" : "kafkaOpsApp");
        continue;
      }
      if (action === "back") return;

      try {
        if (action === "reset") {
          if (!(await dangerousProceed("Сброс данных Kafka."))) continue;
          await runTarget("kafka-reset", {});
        } else if (action === "tcr") {
          const app = await promptApp();
          const suf = ensure(
            await text({
              message:
                "TOPIC_SUFFIX: суффикс имени топика (см. конвенцию в scripts/docs репозитория)",
              validate: (s) => s?.trim() || "Нужно",
            }),
          );
          let env = { APP: app, TOPIC_SUFFIX: String(suf).trim() };
          if (await promptYesNo("PARTITIONS / REPLICATION_FACTOR / CONFIGS?", false))
            env = await promptExtraEnv(env);
          await runTarget("kafka-topic-create", env);
        } else if (action === "tal") {
          const topic = ensure(
            await text({
              message: "Имя топика в Kafka (ровно как в кластере):",
              validate: (s) => s?.trim() || "Нужно",
            }),
          );
          let env = { TOPIC: String(topic).trim() };
          if (await promptYesNo("PARTITIONS или CONFIGS?", false))
            env = await promptExtraEnv(env);
          await runTarget("kafka-topic-alter", env);
        } else if (action === "td") {
          const topic = ensure(
            await text({
              message: "Имя топика в Kafka (ровно как в кластере):",
              validate: (s) => s?.trim() || "Нужно",
            }),
          );
          await runTarget("kafka-topic-describe", { TOPIC: String(topic).trim() });
        } else {
          let env = {};
          if (
            await promptYesNo(
              "Задать PREFIX (или оставить пустым для всего списка)?",
              false,
            )
          )
            env.PREFIX = String(
              ensure(
                await text({
                  message:
                    "PREFIX: фильтр по префиксу имён топиков (пусто — полный список)",
                }),
              ),
            ).trim();
          await runTarget("kafka-topic-list", env);
        }
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function postgresDataMenu() {
    for (;;) {
      const action = ensure(
        await select({
          message: "PostgreSQL: резервные копии и тома",
          options: [
            {
              value: "backup",
              label: "Сделать резервную копию",

            },
            {
              value: "restore",
              label: "Восстановить из архива (указать файл)",

            },
            {
              value: "recreate",
              label: "Подготовить пересоздание: бэкап, останов, удаление PVC (опасно)",

            },
            {
              value: "delpvc",
              label: "Удалить PVC PostgreSQL (опасно)",

            },
            OPT_HELP,
            { value: "back", label: "Назад" },
          ],
        }),
      );
      if (action === HELP_VALUE) {
        showMenuHelp("postgresData");
        continue;
      }
      if (action === "back") return;

      try {
        if (action === "backup") await runTarget("postgres-backup", {});
        else if (action === "restore") {
          const f = ensure(
            await text({
              message:
                "BACKUP_FILE: имя файла дампа относительно каталога postgres/ (см. README postgres/)",
              validate: (s) => s?.trim() || "Нужно",
            }),
          );
          await runTarget("postgres-restore", { BACKUP_FILE: String(f).trim() });
        } else if (action === "recreate") {
          if (!(await dangerousProceed("Цепочка backup + down + delete PVC.")))
            continue;
          await runTarget("postgres-recreate-prep", {});
        } else if (await dangerousProceed("Удалить PVC Postgres."))
          await runTarget("postgres-delete-pvcs", {});
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function monitoringExtrasMenu() {
    for (;;) {
      const action = ensure(
        await select({
          message: "Netdata: дополнительные действия",
          options: [
            {
              value: "tn",
              label: "Топ узлов по ресурсам",

            },
            {
              value: "ev",
              label: "События в namespace мониторинга",

            },
            {
              value: "pe",
              label: "События конкретного пода",

            },
            {
              value: "dp",
              label: "Описание пода (kubectl describe)",

            },
            {
              value: "helm",
              label: "Helm: развернуть, сравнить или удалить Netdata",

            },
            OPT_HELP,
            { value: "back", label: "Назад" },
          ],
        }),
      );
      if (action === HELP_VALUE) {
        showMenuHelp("monitoringExtras");
        continue;
      }
      if (action === "back") return;

      try {
        if (action === "tn") await runTarget("monitoring-top-nodes", {});
        else if (action === "ev") await runTarget("monitoring-events", {});
        else if (action === "helm") {
          helmPick: for (;;) {
            const hs = ensure(
              await select({
                message: "Релиз Netdata (Helm)",
                options: [
                  {
                    value: "monitoring-up",
                    label: "Развернуть или обновить",

                  },
                  {
                    value: "monitoring-diff",
                    label: "Показать отличия с кластером",

                  },
                  {
                    value: "monitoring-down",
                    label: "Удалить релиз (опасно)",

                  },
                  OPT_HELP,
                  { value: "back", label: "Назад" },
                ],
              }),
            );
            if (hs === HELP_VALUE) {
              showMenuHelp("monitoringHelm");
              continue helmPick;
            }
            if (hs === "back") break helmPick;
            if (hs === "monitoring-down" && !(await dangerousProceed("Удаление релиза Netdata.")))
              continue helmPick;
            await runTarget(hs, {});
            break helmPick;
          }
        } else {
          const pod = ensure(
            await text({
              message:
                "Имя pod Netdata (как в kubectl get pods); пусто — авто-выбор pod",
              initialValue: "",
            }),
          );
          await runTarget(
            action === "pe" ? "monitoring-pod-events" : "monitoring-describe-pod",
            { POD: String(pod).trim() },
          );
        }
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function serviceDiagLoop(svc) {
    const isMon = svc === "monitoring";
    const prefix = isMon ? "monitoring" : svc;

    for (;;) {
      const options = [
        {
          value: "status",
          label: "Состояние подов и релиза",

        },
        {
          value: "logs",
          label: "Логи (Ctrl+C для выхода)",

        },
      ];
      if (isMon)
        options.push({
          value: "pf",
          label: "Проброс порта 19999 на эту машину",

        });
      else
        options.push({
          value: "shell",
          label: "Shell в контейнере",

        });

      if (svc === "postgres")
        options.push({
          value: "data",
          label: "Бэкапы, восстановление и PVC",

        });
      if (isMon)
        options.push({
          value: "more",
          label: "Ещё: топ узлов, события, Helm",

        });

      options.push(OPT_HELP);
      options.push({ value: "back", label: "Назад" });

      const action = ensure(
        await select({
          message: `Диагностика: ${displayServiceName(svc === "monitoring" ? "netdata" : svc)} (ENV=${session.env})`,
          options,
        }),
      );

      if (action === HELP_VALUE) {
        showMenuHelp("serviceDiag");
        continue;
      }
      if (action === "back") return;

      try {
        if (action === "data" && svc === "postgres") {
          await postgresDataMenu();
          continue;
        }
        if (action === "more" && isMon) {
          await monitoringExtrasMenu();
          continue;
        }
        let target =
          action === "status"
            ? `${prefix}-status`
            : action === "logs"
              ? `${prefix}-logs`
              : action === "pf"
                ? "monitoring-port-forward"
                : `${svc}-shell`;
        if (!isMon && action === "shell") target = `${svc}-shell`;

        await runTarget(target, {}, { sigint: action === "logs" || action === "pf" });
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function diagnosticsMenu() {
    for (;;) {
      const svc = ensure(
        await select({
          message: `Сервис для диагностики (ENV=${session.env})`,
          options: [
            ...DIAG_SERVICE_OPTIONS,
            OPT_HELP,
            { value: "__back__", label: "Назад" },
          ],
        }),
      );
      if (svc === HELP_VALUE) {
        showMenuHelp("diagnosticsPick");
        continue;
      }
      if (svc === "__back__") return;

      try {
        await serviceDiagLoop(svc);
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function k8sPortExposeMenu() {
    for (;;) {
      const action = ensure(
        await select({
          message: `TCP-порты на узле (microk8s, ENV=${session.env})`,
          options: [
            {
              value: "show",
              label: "Показать ConfigMap и привязки hostPort",

            },
            {
              value: "patch",
              label: "Изменить маршрут или hostPort",

            },
            {
              value: "apply",
              label: "Применить локальный YAML (ports-ENV.yaml)",
            },
            OPT_HELP,
            { value: "back", label: "Назад" },
          ],
        }),
      );
      if (action === HELP_VALUE) {
        showMenuHelp("k8sPortTop");
        continue;
      }
      if (action === "back") return;

      try {
        if (action === "show") await runTarget("k8s-port-expose-show", {});
        else if (action === "apply") {
          applyFlow: for (;;) {
            /** @type {Record<string,string|undefined>} */
            let env = {};
            for (;;) {
              const dr = ensure(
                await select({
                  message: "Режим kubectl (dry-run) для k8s-port-expose-apply",
                  options: [
                    {
                      value: "",
                      label: "Нет, применить изменения",

                    },
                    {
                      value: "client",
                      label: "client (только клиент)",

                    },
                    {
                      value: "server",
                      label: "server",

                    },
                    OPT_HELP,
                    { value: "__back__", label: "Назад" },
                  ],
                }),
              );
              if (dr === HELP_VALUE) {
                showMenuHelp("k8sPortDryRun");
                continue;
              }
              if (dr === "__back__") break applyFlow;
              if (dr) env.DRY_RUN = String(dr).trim();
              break;
            }
            if (
              await promptYesNo(
                "Задать PORT_EXPOSE_CONFIG или INGRESS_* через KEY=value?",
                false,
              )
            )
              Object.assign(env, await promptExtraEnv({}));

            await runTarget("k8s-port-expose-apply", env);
            break applyFlow;
          }
        } else {
          patchFlow: for (;;) {
            let layer;
            for (;;) {
              const lr = ensure(
                await select({
                  message: "Слой изменения",
                  options: [
                    {
                      value: "tcp",
                      label: "Маршрут TCP через ConfigMap ingress",

                    },
                    {
                      value: "hostport",
                      label: "Проброс порта на узле (DaemonSet)",

                    },
                    OPT_HELP,
                    { value: "__back__", label: "Назад" },
                  ],
                }),
              );
              if (lr === HELP_VALUE) {
                showMenuHelp("k8sPortLayer");
                continue;
              }
              if (lr === "__back__") break patchFlow;
              layer = lr;
              break;
            }
            const hp = ensure(
              await text({
                message:
                  "HOST_PORT: номер порта на узле (например 1883 для MQTT)",
                validate: (v) => (String(v).trim() ? undefined : "Нужно число порта"),
              }),
            );
            /** @type {Record<string,string|undefined>} */
            let env = {
              LAYER: layer,
              HOST_PORT: String(hp).trim(),
            };

            if (layer === "tcp") {
              const rm = await promptYesNo(
                "Удалить запись из ConfigMap (RM=1), не задавая BACKEND?",
                false,
              );
              if (rm) env.RM = "1";
              else {
                const be = ensure(
                  await text({
                    message:
                      "BACKEND: куда слать трафик, формат namespace/имя-сервиса:порт",
                    validate: (v) =>
                      String(v).includes("/") ? undefined : "Нужно ns/svc:port",
                  }),
                );
                env.BACKEND = String(be).trim();
              }
            } else {
              for (;;) {
                const op = ensure(
                  await select({
                    message: "Действие с привязкой hostPort",
                    options: [
                      {
                        value: "add",
                        label: "Добавить",

                      },
                      {
                        value: "rm",
                        label: "Удалить",

                      },
                      OPT_HELP,
                      { value: "__back__", label: "Назад" },
                    ],
                  }),
                );
                if (op === HELP_VALUE) {
                  showMenuHelp("k8sPortHostOp");
                  continue;
                }
                if (op === "__back__") continue patchFlow;
                env.OP = op;
                if (op === "add") {
                  const cp = ensure(
                    await text({
                      message:
                        "CONTAINER_PORT: порт контейнера (часто совпадает с host)",
                      initialValue: env.HOST_PORT,
                    }),
                  );
                  const pn = ensure(
                    await text({
                      message: "PORT_NAME: метка порта в pod spec (часто tcp)",
                      initialValue: "tcp",
                    }),
                  );
                  env.CONTAINER_PORT = String(cp).trim();
                  env.PORT_NAME = String(pn).trim();
                }
                break;
              }
            }

            for (;;) {
              const dr = ensure(
                await select({
                  message: "Режим kubectl (dry-run)",
                  options: [
                    {
                      value: "",
                      label: "Нет, применить изменения",

                    },
                    {
                      value: "client",
                      label: "client (только клиент)",

                    },
                    {
                      value: "server",
                      label: "server",

                    },
                    OPT_HELP,
                    { value: "__back__", label: "Назад" },
                  ],
                }),
              );
              if (dr === HELP_VALUE) {
                showMenuHelp("k8sPortDryRun");
                continue;
              }
              if (dr === "__back__") continue patchFlow;
              if (dr) env.DRY_RUN = String(dr).trim();
              break;
            }

            if (await promptYesNo(
              "Добавить редкие параметры (INGRESS_NS, имя DaemonSet и т.д.) через KEY=value?",
              false,
            ))
              Object.assign(env, await promptExtraEnv({}));

            await runTarget("k8s-port-expose-patch", env);
            break patchFlow;
          }
        }
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }
  }

  async function configureSessionEnvFlow() {
    await pickSessionEnvInteractive(session, {
      ensure,
      select,
      text,
      helpOption: OPT_HELP,
      showHelp: () => showMenuHelp("sessionEnvPick"),
      selectMessage: "Окружение сессии infra-lab (ENV):",
    });
    note(
      `Переопределения SSH/registry: локальный файл environments/${session.env}.mk (не в git).`,
      "Окружение",
    );
    log.step(`ENV сессии: ${formatSessionEnvOptionLabel(session.env)}`);
  }

  async function rootLoop() {
    intro("Infra control center");

    note(
      `${INTRO_NOTE.tagline}\n\nВерсия ${INFRA_LAB_VERSION}.`,
      INTRO_NOTE.title,
    );

    note(
      `Текущее ENV=${session.env}. Сменить: «${NAV.TASK.CONFIGURE} → ${NAV.OBJECT.SESSION}». В конфигураторе приложений первый шаг задаёт то же ENV для сессии.`,
      "Сессия",
    );

    for (;;) {
      const task = ensure(
        await select({
          message: "Что вы хотите сделать?",
          options: [
            {
              value: "boot",
              label: NAV.TASK.BOOTSTRAP,

            },
            {
              value: "cfg",
              label: NAV.TASK.CONFIGURE,

            },
            {
              value: "run",
              label: NAV.TASK.MANAGE,

            },
            OPT_HELP,
            {
              value: "exit",
              label: "Выход",

            },
          ],
        }),
      );

      try {
        if (task === "exit") break;
        if (task === HELP_VALUE) {
          showMenuHelp("rootTask");
          continue;
        }

        const objOptions =
          task === "cfg"
            ? [
                {
                  value: "session",
                  label: NAV.OBJECT.SESSION,
                },
                {
                  value: "env",
                  label: NAV.OBJECT.ENV,

                },
                {
                  value: "app",
                  label: NAV.OBJECT.APP,

                },
                OPT_HELP,
                { value: "back", label: "Назад" },
              ]
            : [
                {
                  value: "env",
                  label: NAV.OBJECT.ENV,

                },
                {
                  value: "svc",
                  label: NAV.OBJECT.SVC,

                },
                {
                  value: "app",
                  label: NAV.OBJECT.APP,

                },
                OPT_HELP,
                { value: "back", label: "Назад" },
              ];

        const taskLabel =
          task === "boot"
            ? NAV.TASK.BOOTSTRAP
            : task === "cfg"
              ? NAV.TASK.CONFIGURE
              : NAV.TASK.MANAGE;

        const obj = ensure(
          await select({
            message: `Объект для «${taskLabel}» (с чем работаем в первую очередь):`,
            options: objOptions,
          }),
        );
        if (obj === HELP_VALUE) {
          showMenuHelp(task === "cfg" ? "rootObjectCfg" : "rootObjectRunBoot");
          continue;
        }
        if (obj === "back") continue;

        if (task === "boot") {
          if (obj === "env") await bootstrapEnvMenu();
          else if (obj === "svc") await bootstrapServiceMenu();
          else await bootstrapAppMenu();
        } else if (task === "cfg") {
          if (obj === "session") await configureSessionEnvFlow();
          else if (obj === "env") await k8sPortExposeMenu();
          else await configureAppMenu();
        } else {
          if (obj === "env") await manageEnvMenu();
          else if (obj === "svc") await manageServiceMenu();
          else await manageAppMenu();
        }
      } catch (e) {
        log.error(String(e?.stack || e));
      }
    }

    outro("Bye.");
  }

  rootLoop().catch((err) => {
    log.error(err?.stack || String(err));
    process.exit(1);
  });
}
