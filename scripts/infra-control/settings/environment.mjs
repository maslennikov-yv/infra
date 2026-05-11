// «Настройка → Окружение и образы» — env-new, kubeconfig, SSH, MicroK8s,
// образы, kafka-bootstrap, helm destroy (точечно / весь набор).
// Объединяет старые ветки «Бутстрап → Среда → Кластер» и «Управление → Среда».

import fs from "node:fs";
import path from "node:path";

import { select, text, note, log } from "../io.mjs";
import {
  ensure,
  promptDangerous,
  promptYesNo,
  promptServicesSelection,
  runTarget,
} from "../prompts.mjs";
import { setSessionEnv } from "../context.mjs";
import { ENVIRONMENTS_DIR } from "../../lib/repo.mjs";
import { validateEnvName } from "../../lib/session-env-picker.mjs";

/**
 * @param {{ env: string }} session
 */
export async function settingsEnvironment(session) {
  for (;;) {
    const choice = ensure(
      await select({
        message: `Окружение и образы · ENV: ${session.env}`,
        options: [
          { value: "env_new",   label: "Создать рыбу окружения (env-new)",         hint: "environments/<ENV>.{mk,yaml}, k8s/config/<ENV>, values-<ENV>.yaml в каждом сервисе" },
          { value: "kc_remote", label: "Kubeconfig: получить с удалённого сервера",  hint: "kubeconfig-fetch (нужен SSH_HOST)" },
          { value: "kc_local",  label: "Kubeconfig: локальный MicroK8s",             hint: "kubeconfig-microk8s-local" },
          { value: "kc_info",   label: "Kubeconfig: информация",                     hint: "kubeconfig-info — cluster-info текущего KUBECONFIG" },
          { value: "ssh",       label: "Войти по SSH",                                hint: "ssh (нужен SSH_HOST)" },
          { value: "mk_setup",  label: "MicroK8s: установить/проверить на ноде",     hint: "microk8s-setup (через SSH)" },
          { value: "mk_uninst", label: "MicroK8s: удалить с ноды (опасно)",          hint: "microk8s-uninstall (через SSH)" },
          { value: "img_save",  label: "Образы: pull + сохранить tar",                hint: "images-save [SERVICE=…]" },
          { value: "img_push",  label: "Образы: загрузить в локальный registry",      hint: "images-push [SERVICE=…]" },
          { value: "img_pushr", label: "Образы: загрузить на удалённый сервер",       hint: "images-push-remote [SERVICE=…]" },
          { value: "kafka_bs",  label: "Kafka: bootstrap-подключение к новому брокеру", hint: "kafka-bootstrap — разовая инициализация" },
          { value: "helm_down", label: "Helm: уничтожить релизы (опасно)",              hint: "down — мультивыбор сервисов; полное удаление с потерей данных PVC" },
          { value: "back",      label: "Назад" },
        ],
      }),
    );
    if (choice === "back") return;

    if (choice === "env_new")  await envNewFlow(session);
    else if (choice === "kc_remote") await runTarget(session, "kubeconfig-fetch", {});
    else if (choice === "kc_local")  await runTarget(session, "kubeconfig-microk8s-local", {});
    else if (choice === "kc_info")   await runTarget(session, "kubeconfig-info", {});
    else if (choice === "ssh")       await runTarget(session, "ssh", {}, { sigint: true });
    else if (choice === "mk_setup")  await runTarget(session, "microk8s-setup", {});
    else if (choice === "mk_uninst") {
      if (await promptDangerous("Удаление MicroK8s с удалённой ноды (все workloads и данные ноды погибнут)."))
        await runTarget(session, "microk8s-uninstall", {});
    }
    else if (choice === "img_save")  await imagesFlow(session, "images-save");
    else if (choice === "img_push")  await imagesFlow(session, "images-push");
    else if (choice === "img_pushr") await imagesFlow(session, "images-push-remote");
    else if (choice === "kafka_bs")  await runTarget(session, "kafka-bootstrap", {});
    else if (choice === "helm_down") await helmDownFlow(session);
  }
}

async function envNewFlow(session) {
  note(
    [
      "make env-new создаёт рыбу нового окружения:",
      "• environments/<ENV>.{mk,yaml}",
      "• k8s/config/<ENV>",
      "• values-<ENV>.yaml в каждом сервисе",
      "Цель идемпотентна: существующие файлы не перезаписываются.",
    ].join("\n"),
    "env-new",
  );

  const raw = ensure(
    await text({
      message: `ENV для нового окружения (текущая сессия: ${session.env}):`,
      initialValue: session.env,
      validate: validateEnvName,
    }),
  );
  const targetEnv = String(raw).trim();

  const mkPath = path.join(ENVIRONMENTS_DIR, `${targetEnv}.mk`);
  const yamlPath = path.join(ENVIRONMENTS_DIR, `${targetEnv}.yaml`);
  const skeletonExists = fs.existsSync(mkPath) && fs.existsSync(yamlPath);
  if (skeletonExists) {
    note(
      `environments/${targetEnv}.{mk,yaml} уже есть. env-new идемпотентен — недостающие values-<ENV>.yaml у сервисов будут досозданы.`,
      "env-new",
    );
    if (!(await promptYesNo("Запустить make env-new всё равно?", true))) {
      return;
    }
  }

  // env-new игнорирует ENV сессии, имя приходит явным параметром.
  const ok = await runTarget(session, "env-new", { ENV: targetEnv });
  if (!ok) return;

  if (targetEnv !== session.env) {
    if (
      await promptYesNo(
        `Переключить сессию TUI на ENV=${targetEnv}? (текущий: ${session.env})`,
        true,
      )
    ) {
      setSessionEnv(session, targetEnv);
      log.success(`ENV сессии: ${targetEnv}.`);
    } else {
      note(
        `Рыба создана. Когда понадобится — переключите ENV через «Сессия → Сменить ENV».`,
        "env-new",
      );
    }
  }
}

async function helmDownFlow(session) {
  note(
    [
      "helm down уничтожит выбранные релизы. PVC обычно НЕ удаляются автоматически —",
      "но политика storageClass может быть Delete. См. docs/runbooks/storage-class.md и <service>/TROUBLESHOOTING.md.",
    ].join("\n"),
    "Helm down",
  );
  const { enabled, exclude } = await promptServicesSelection({ kind: "down" });
  /** @type {Record<string,string>} */
  const env = {};
  if (enabled !== null) env.ENABLED_SERVICES = enabled;
  if (exclude !== null) env.EXCLUDE_SERVICES = exclude;
  const label = enabled ? `выбранных сервисов (${enabled})` : "ВСЕГО набора";
  if (!(await promptDangerous(`helmfile destroy ${label}.`))) return;
  await runTarget(session, "down", env);
}

async function imagesFlow(session, target) {
  const filter = await promptYesNo("Ограничить одним сервисом (SERVICE=…)?", false);
  /** @type {Record<string,string>} */
  const env = {};
  if (filter) {
    const svc = ensure(
      await select({
        message: "SERVICE (data-сервисы; Netdata управляется отдельно через monitoring-*):",
        options: [
          { value: "postgres",   label: "postgres" },
          { value: "redis",      label: "redis" },
          { value: "kafka",      label: "kafka" },
          { value: "minio",      label: "minio" },
          { value: "clickhouse", label: "clickhouse" },
          { value: "rabbitmq",   label: "rabbitmq" },
        ],
      }),
    );
    env.SERVICE = svc;
  }
  await runTarget(session, target, env);
}
