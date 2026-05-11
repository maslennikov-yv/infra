// «Настройка → TCP-порты ingress» — open/close TCP ports на ноде microk8s
// через nginx ingress controller (DaemonSet hostPort + ConfigMap nginx-ingress-tcp).
// См. .claude/skills/k8s-port-expose-microk8s/SKILL.md.

import { select, note, log } from "../io.mjs";
import {
  ensure,
  optionalText,
  promptYesNo,
  requiredText,
  runTarget,
} from "../prompts.mjs";

/** Валидатор для номера порта (HOST_PORT, CONTAINER_PORT). */
export function validatePortNumber(s) {
  return /^\d+$/.test(String(s).trim()) ? undefined : "Только цифры";
}

/** Валидатор адреса бэкенда в формате `ns/svc:port`. */
export function validateBackendAddr(s) {
  return /^[a-z0-9-]+\/[a-z0-9-]+:\d+$/.test(String(s).trim())
    ? undefined
    : "Формат ns/svc:port";
}

/**
 * @param {{ env: string }} session
 */
export async function settingsTcp(session) {
  for (;;) {
    const choice = ensure(
      await select({
        message: `TCP-порты ingress · ENV: ${session.env}`,
        options: [
          { value: "show",  label: "Показать состояние",                   hint: "k8s-port-expose-show" },
          { value: "diff",  label: "Сравнить ports-<env>.yaml с live",     hint: "k8s-port-expose-diff" },
          { value: "apply", label: "Применить из ports-<env>.yaml",        hint: "k8s-port-expose-apply (не удаляет лишнее)" },
          { value: "patch", label: "Изменить один порт/маршрут",           hint: "k8s-port-expose-patch (мастер)" },
          { value: "back",  label: "Назад" },
        ],
      }),
    );
    if (choice === "back") return;

    if (choice === "show")  await runTarget(session, "k8s-port-expose-show", {});
    else if (choice === "diff")  await runTarget(session, "k8s-port-expose-diff", {});
    else if (choice === "apply") await applyFlow(session);
    else if (choice === "patch") await patchFlow(session);
  }
}

async function applyFlow(session) {
  const dry = await pickDryRun();
  /** @type {Record<string,string>} */
  const env = {};
  if (dry) env.DRY_RUN = dry;
  await runTarget(session, "k8s-port-expose-apply", env);
}

async function patchFlow(session) {
  const layer = ensure(
    await select({
      message: "Что меняем:",
      options: [
        { value: "tcp",      label: "ConfigMap TCP (маршрут host-port → ns/svc:port)" },
        { value: "hostport", label: "DaemonSet hostPort (открыть/закрыть порт на ноде)" },
      ],
    }),
  );

  const hostPort = await requiredText(
    "HOST_PORT (номер порта на узле, напр. 1883):",
    validatePortNumber,
  );

  /** @type {Record<string,string>} */
  const env = { LAYER: layer, HOST_PORT: hostPort };

  if (layer === "tcp") {
    const remove = await promptYesNo("Удалить маршрут (RM=1)? Иначе — добавить/обновить.", false);
    if (remove) env.RM = "1";
    else {
      env.BACKEND = await requiredText(
        "BACKEND (ns/svc:port, напр. mqtt/mosquitto:1883):",
        validateBackendAddr,
      );
    }
  } else {
    const op = ensure(
      await select({
        message: "OP:",
        options: [
          { value: "add", label: "add — добавить порт в DaemonSet" },
          { value: "rm",  label: "rm — убрать порт" },
        ],
      }),
    );
    env.OP = op;
    if (op === "add") {
      env.CONTAINER_PORT = await requiredText(
        "CONTAINER_PORT (порт внутри контейнера ingress, обычно = HOST_PORT):",
        validatePortNumber,
      );
      env.PORT_NAME = await requiredText(
        "PORT_NAME (имя порта в DaemonSet, напр. mqtt):",
        (s) => (s && String(s).trim() ? undefined : "Обязательное поле"),
      );
      const proto = await optionalText("PROTO (TCP|UDP; Enter — TCP):");
      if (proto) env.PROTO = proto;
    }
  }

  const dry = await pickDryRun();
  if (dry) env.DRY_RUN = dry;

  await runTarget(session, "k8s-port-expose-patch", env);
}

async function pickDryRun() {
  const choice = ensure(
    await select({
      message: "DRY_RUN:",
      options: [
        { value: "",        label: "off — реально применить" },
        { value: "client",  label: "client — local validation, без API запроса" },
        { value: "server",  label: "server — server-side validation, без записи" },
      ],
    }),
  );
  return String(choice);
}

