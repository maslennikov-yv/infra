// Метаданные сервисов для нового TUI v2. Вытащены из run.mjs (HELM_SERVICES,
// displayServiceName) — без зависимостей от внутреннего closure run.mjs.

import { DATA_SERVICES } from "../lib/data-services.mjs";

/** Все сервисы, управляемые через helm/helmfile. Netdata добавляется отдельно. */
export const HELM_SERVICES = Object.freeze([...DATA_SERVICES, "netdata"]);

/** Сервисы, по которым есть учётки приложений (apps-apply, *-app-create и т.п.). */
export const ACCOUNT_SERVICES = Object.freeze([
  "postgres",
  "redis",
  "kafka",
  "minio",
  "clickhouse",
  "rabbitmq",
]);

/** Сервисы для диагностики (логи / shell / status). Netdata здесь = "monitoring". */
export const DIAG_SERVICES = Object.freeze([
  ...DATA_SERVICES,
  "monitoring",
]);

/** Подписи сервисов в меню. Slug идёт в make-цели, label — для пользователя. */
export function displayServiceName(id) {
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
    case "monitoring":
      return "Netdata (мониторинг)";
    default:
      return id;
  }
}

/** Опции multiselect для всех helm-сервисов (включая Netdata). */
export const HELM_OPTIONS = HELM_SERVICES.map((s) => ({
  value: s,
  label: displayServiceName(s),
}));

/** Опции select для диагностики (используется monitoring=netdata по make-целям). */
export const DIAG_OPTIONS = DIAG_SERVICES.map((s) => ({
  value: s,
  label: displayServiceName(s),
}));

/** Опции select для меню учёток (без Netdata). */
export const ACCOUNT_OPTIONS = ACCOUNT_SERVICES.map((s) => ({
  value: s,
  label: displayServiceName(s),
}));

/** Префикс make-цели для конкретного service slug.
 *  Netdata управляется make-целями `monitoring-*`, остальные — по своему имени. */
export function helmTargetPrefix(svc) {
  return svc === "netdata" ? "monitoring" : svc;
}
