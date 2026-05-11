// «Состояние и логи» — единое подменю диагностики.
// Объединяет: doctor, status, top-totals, *-logs/-shell, monitoring-events,
// monitoring-pod-events, monitoring-describe-pod.

import { select, text, note } from "../io.mjs";
import {
  ACCOUNT_OPTIONS,
  DIAG_OPTIONS,
  displayServiceName,
  helmTargetPrefix,
} from "../meta.mjs";
import { ensure, runTarget } from "../prompts.mjs";

/**
 * @param {{ env: string, app?: string|null }} session
 */
export async function actionStatus(session) {
  for (;;) {
    const choice = ensure(
      await select({
        message: `Состояние и логи · ENV: ${session.env}`,
        options: [
          {
            value: "doctor",
            label: "Полная диагностика стека",
            hint: "make doctor — tools, кластер, helm vs helmfile, rollouts, per-app verify",
          },
          {
            value: "status",
            label: "Сводка по кластеру",
            hint: "make status — ноды, поды, helm list -A",
          },
          {
            value: "top",
            label: "Загрузка узлов: CPU/RAM",
            hint: "make top-totals",
          },
          {
            value: "logs",
            label: "Логи сервиса (Ctrl+C — выход)",
            hint: "<svc>-logs / monitoring-logs",
          },
          {
            value: "shell",
            label: "Shell в поде сервиса",
            hint: "<svc>-shell (для Netdata: port-forward)",
          },
          {
            value: "evt",
            label: "События namespace monitoring",
            hint: "monitoring-events",
          },
          {
            value: "pod_evt",
            label: "События конкретного пода",
            hint: "monitoring-pod-events POD=…",
          },
          {
            value: "pod_desc",
            label: "Describe конкретного пода",
            hint: "monitoring-describe-pod POD=…",
          },
          { value: "back", label: "Назад" },
        ],
      }),
    );
    if (choice === "back") return;

    if (choice === "doctor") await runTarget(session, "doctor", {});
    else if (choice === "status") await runTarget(session, "status", {});
    else if (choice === "top") await runTarget(session, "top-totals", {});
    else if (choice === "logs") await pickServiceAnd(session, "logs");
    else if (choice === "shell") await pickServiceAnd(session, "shell");
    else if (choice === "evt") await runTarget(session, "monitoring-events", {});
    else if (choice === "pod_evt") await podMakeFlow(session, "monitoring-pod-events");
    else if (choice === "pod_desc") await podMakeFlow(session, "monitoring-describe-pod");
  }
}

/**
 * @param {{ env: string }} session
 * @param {"logs"|"shell"} kind
 */
async function pickServiceAnd(session, kind) {
  // Для shell исключаем netdata (там вместо shell — port-forward).
  const options = kind === "shell"
    ? ACCOUNT_OPTIONS.concat([{ value: "monitoring", label: `${displayServiceName("monitoring")} — port-forward вместо shell` }])
    : DIAG_OPTIONS;

  const svc = ensure(
    await select({
      message: `${kind === "logs" ? "Логи" : "Shell / port-forward"}: компонент`,
      options: [...options, { value: "back", label: "Назад" }],
    }),
  );
  if (svc === "back") return;

  // Целевые имена: для Netdata префикс monitoring-, для остальных — slug.
  // shell у Netdata подменяется на port-forward.
  let target;
  if (svc === "monitoring") {
    target = kind === "shell" ? "monitoring-port-forward" : `monitoring-${kind}`;
  } else {
    target = `${helmTargetPrefix(svc)}-${kind}`;
  }

  // Логи и port-forward — долгоживущие, ловим Ctrl+C; shell интерактивный.
  const sigint = kind === "logs" || (svc === "monitoring" && kind === "shell");
  await runTarget(session, target, {}, { sigint });
}

/**
 * @param {{ env: string }} session
 * @param {"monitoring-pod-events"|"monitoring-describe-pod"} target
 */
async function podMakeFlow(session, target) {
  const pod = ensure(
    await text({
      message: "POD (имя пода; пусто — запустить без POD, целью на namespace):",
      placeholder: "netdata-...",
      initialValue: "",
    }),
  );
  const trimmed = String(pod ?? "").trim();
  await runTarget(session, target, trimmed ? { POD: trimmed } : {});
  if (!trimmed) note("Запущено без POD — make-цель использует свой default.", target);
}
