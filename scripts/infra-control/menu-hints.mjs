/**
 * Тексты справки по пункту «Справка» в TUI (без Clack option.hint).
 */

import { DATA_SERVICES } from "../lib/data-services.mjs";

export const HELP_VALUE = "__help__";

/** @typedef {{ title: string, body: string }} HelpBlock */

const HELM_SERVICES = [...DATA_SERVICES, "netdata"];

const SVC_PRETTY = {
  postgres: "PostgreSQL",
  redis: "Redis",
  kafka: "Kafka",
  minio: "MinIO",
  clickhouse: "ClickHouse",
  rabbitmq: "RabbitMQ",
  netdata: "Netdata",
};

/** Роль компонента — для блоков справки. */
const SERVICE_HELM_LINES = {
  postgres:
    "Shared Postgres в k8s; каталог postgres/; учётки приложений через apps-apply.",
  redis: "Кэш/очереди; чарт redis/; отдельный логический DB index на приложение.",
  kafka: "Брокер; kafka/; SASL и топики из меню Kafka.",
  minio: "S3-совместимое хранилище; minio/.",
  clickhouse: "Аналитика; clickhouse/.",
  rabbitmq: "Очереди AMQP; rabbitmq/.",
  netdata: "Мониторинг; релиз в namespace monitoring.",
};

/** @param {string} t */
function verifyLineForTarget(t) {
  if (t === "check-updates")
    return "Сводка по всем чартам (bitnami): какие версии доступны, без установки.";
  const m = /^([\w-]+)-(check-updates|verify)$/.exec(t);
  if (!m) return "";
  const name = SVC_PRETTY[m[1]] || m[1];
  if (m[2] === "verify")
    return `Dry-run / шаблон манифеста релиза ${name}, без изменений в кластере.`;
  return `Только чарт ${name}: есть ли более новая версия в источнике.`;
}

function verifyMenuBody() {
  const bitnami = HELM_SERVICES.filter((x) => x !== "netdata");
  const lines = [
    "Проверки без деплоя. Каждый пункт запускает одну именованную цель (см. лог после выбора).",
    "",
  ];
  for (const s of bitnami)
    lines.push(`• ${s}-verify — ${verifyLineForTarget(`${s}-verify`)}`);
  lines.push(`• check-updates — ${verifyLineForTarget("check-updates")}`);
  for (const s of bitnami)
    lines.push(
      `• ${s}-check-updates — ${verifyLineForTarget(`${s}-check-updates`)}`,
    );
  return lines.join("\n");
}

function helmComponentsBody() {
  return [
    "Компоненты стека (value = slug для имён целей):",
    ...HELM_SERVICES.map(
      (s) =>
        `• ${SVC_PRETTY[s] || s} — ${SERVICE_HELM_LINES[s] ?? "см. каталог сервиса"}`,
    ),
  ].join("\n");
}

/** Справка для шага мультивыбора ENABLED_SERVICES */
export const MULTI_ENABLED_HELP = {
  title: "Справка: список сервисов",
  body:
    "Переменная ENABLED_SERVICES ограничивает набор для helmfile / apps-apply: только перечисленные slug через запятую.\n\n" +
    "Если на предыдущем шаге вы ответили «да — на все», ограничение не задаётся (все сервисы набора).\n\n" +
    "Состав набора по умолчанию задаётся values и helmfile для текущего ENV.",
};

/** Справка для шага EXCLUDE_SERVICES */
export const MULTI_EXCLUDE_HELP = {
  title: "Справка: исключения",
  body:
    "EXCLUDE_SERVICES — slug через запятую, которые пропустить при массовой операции (helm up/diff/down, apps-apply в связке).\n\n" +
    "Имеет смысл, когда основной набор широкий, а часть чартов трогать не нужно.",
};

/**
 * @type {Record<string, HelpBlock>}
 */
export const MENU_HELP = {
  rootTask: {
    title: "Справка: выбор задачи",
    body:
      "Начинайте с «Бутстрап»: для удалённой целевой среды настройте SSH и получите kubeconfig к кластеру; если нужен только локальный кластер (MicroK8s на этой машине) — достаточно сразу взять kubeconfig без SSH.\n\n" +
      "Далее — двухшаговая навигация: сначала задача, затем объект (среда / сервис / приложение).\n\n" +
      "• Бутстрап — первичное окружение: скелет ENV, доступ к кластеру (SSH + kubeconfig-fetch или kubeconfig-microk8s-local), шаблоны приложений, первый Helm.\n" +
      "• Конфигурирование — правки без массового деплоя: смена ENV сессии, TCP ingress (microk8s), секреты и merge для приложений.\n" +
      "• Управление — эксплуатация: кластер, образы, Helm, диагностика, учётки, Kafka.",
  },
  sessionEnvPick: {
    title: "Справка: окружение сессии",
    body:
      "Выбранное ENV действует для всего сеанса infra-lab (цели и подписи меню).\n\n" +
      "Профиль: environments/<ENV>.yaml и kubeconfig; локальные переопределения SSH/registry — environments/<ENV>.mk (не в git).\n\n" +
      "В конфигураторе приложений первый шаг использует тот же список ENV и синхронизирует его с сессией.",
  },
  rootObjectCfg: {
    title: "Справка: объект (конфигурирование)",
    body:
      "Объекты: «Сессия», «Среда» и «Приложение» (отдельные чарты не в этом меню).\n\n" +
      "• Сессия — активное ENV для всего сеанса infra-lab (тот же выбор, что первый шаг конфигуратора приложений).\n" +
      "• Среда — проброс TCP-портов на узлах (k8s-port-expose, microk8s nginx ingress).\n" +
      "• Приложение — merge конфигурации, интерактивный конфигуратор apps/conf и registry.",
  },
  rootObjectRunBoot: {
    title: "Справка: объект (бутстрап / управление)",
    body:
      "В бутстрапе для среды сначала обеспечьте доступ: для удалённого кластера — SSH и kubeconfig к целевому окружению; для локального — только kubeconfig MicroK8s на этой машине.\n\n" +
      "• Среда — весь кластер и окружение: kubeconfig, SSH, MicroK8s, бэкап секретов, образы, массовый Helm.\n\n" +
      "• Сервис — один компонент или диагностика: Helm по сервису, логи, verify, админка Kafka.\n\n" +
      "• Приложение — учётки в БД/брокерах, apps-apply, топики Kafka от имени APP.",
  },
  clusterBootstrap: {
    title: "Справка: кластер — бутстрап",
    body:
      "Удалённая среда: настройте SSH (environments/<ENV>.mk, цель ssh), затем kubeconfig-fetch (SSH_HOST; путь — KUBECONFIG из .mk).\n" +
      "Локальный кластер на этой машине: kubeconfig-microk8s-local (без SSH; см. MICROK8S_CMD).\n\n" +
      "Дополнительно: установить/проверить MicroK8s на удалённом сервере — microk8s-setup.",
  },
  clusterManage: {
    title: "Справка: кластер и доступ",
    body:
      "• Обзор кластера — цель status.\n" +
      "• Загрузка узлов — цель top-totals.\n" +
      "• Информация о kubeconfig — цель kubeconfig-info.\n" +
      "• Полная диагностика стека — цель doctor (тулинг + кластер + helm vs helmfile + rollouts + per-app verify).\n" +
      "• Kubeconfig: удалённо kubeconfig-fetch (SSH_HOST); локально kubeconfig-microk8s-local (без SSH).\n" +
      "• SSH / MicroK8s setup / uninstall — те же цели, что в бутстрапе (где применимо).\n" +
      "• Удалить MicroK8s — цель microk8s-uninstall (опасно).",
  },
  helmPickComponent: {
    title: "Справка: компонент стека",
    body:
      helmComponentsBody() +
      "\n\nПосле выбора — действие up, diff или down для этого релиза (netdata → monitoring-*).",
  },
  helmPerServiceAction: {
    title: "Справка: действие Helm",
    body:
      "• Развернуть или обновить — helm upgrade/install (цель <svc>-up или monitoring-up).\n" +
      "• Показать отличия — цель <svc>-diff (или monitoring-diff).\n" +
      "• Уничтожить релиз — цель <svc>-down (опасно).",
  },
  helmMenuGlobalFull: {
    title: "Справка: Helm — весь набор",
    body:
      "Массовые цели up / diff / down по helmfile для текущего ENV.\n\n" +
      "После выбора можно ограничить набор через ENABLED_SERVICES / EXCLUDE_SERVICES (см. справку на шаге мультивыбора).\n\n" +
      "Для up иногда спрашивают SKIP_APPS_APPLY и APPS_APPLY_CONTINUE_ON_ERROR.",
  },
  helmMenuServiceOps: {
    title: "Справка: Helm — сервис",
    body:
      "• Сравнить весь набор — одна цель diff с учётом выбранных/исключённых сервисов.\n" +
      "• Один компонент — переход в меню выбора сервиса и точечный up/diff/down.",
  },
  imagesMenu: {
    title: "Справка: образы",
    body:
      "• Сохранить в tar — цель images-save.\n" +
      "• Загрузить в registry — цель images-push.\n" +
      "• Tar на сервер и выполнить там push — цель images-push-remote (SSH_HOST).\n" +
      "Опционально ограничение одним SERVICE (data-сервис из списка).",
  },
  imagesPickService: {
    title: "Справка: сервис для образов",
    body:
      "Узкий фильтр: только этот компонент в цикле save/push. «Назад» — без фильтра, обработать все из набора.",
  },
  bootstrapApp: {
    title: "Справка: бутстрап — приложение",
    body:
      "• Клонировать — цель apps-src-clone (repo из registry).\n" +
      "• Шаблон — цель apps-conf-template.\n" +
      "• Конфигуратор — интерактивное заполнение apps/conf и registry.",
  },
  configureApp: {
    title: "Справка: конфигурирование — приложение",
    body:
      "• Показать merge — цель apps-merge-print (итог в stdout, без записи в кластер).\n" +
      "• Helm --set для local hostPath — apps-local-src-helm-sets (stdout для вставки в helm upgrade приложения; только ENV=local).\n" +
      "• Конфигуратор — секреты, repo_url, clone в apps/src.",
  },
  manageApp: {
    title: "Справка: управление — приложение",
    body:
      "• Применить в кластер — цель apps-apply (с учётом ENABLED_SERVICES / EXCLUDE); после успеха можно сохранить выбор в environments/<ENV>.mk.\n" +
      "• Деактивация — enabled:false в registry, опционально apps-apply и последовательные *-app-drop по выбранным движкам.\n" +
      "• Учётки — отдельные цели pg-app-*, redis-app-*, …\n" +
      "• Топики Kafka — создание/изменение топиков в контексте APP.\n" +
      "• Для ENV=local: hostPath apps/src/<APP> → workload pod/deployment/sts/ds, initContainers+containers — цель app-local-src-hostpath-mount (APP_LOCAL_SRC_READ_ONLY, фильтр контейнера).",
  },
  manageAppLocalHostpath: {
    title: "Справка: hostPath apps/src в MicroK8s",
    body:
      "Только при сессии ENV=local и кластере на этой машине: на ноде монтируется каталог infra/apps/src/<APP> (абсолютный путь из REPO_ROOT на хосте) в выбранный workload: deployment, statefulset, daemonset или pod (kind/имя).\n\n" +
      "Один и том же том подключается и к initContainers и к containers; APP_LOCAL_SRC_CONTAINER должен совпадать с именем контейнера, иначе ошибка; APP_LOCAL_SRC_READ_ONLY=1 — только чтение (повторным запуском включается readOnly у уже добавленных mount). Ошибки kubectl показываются компактно.\n\n" +
      "Идемпотентно: повторный запуск не дублирует volume/volumeMount при совпадающих настройках.",
  },
  bootstrapEnv: {
    title: "Справка: бутстрап — среда",
    body:
      "• Создать скелет окружения — цель env-new (ENV вводится вручную).\n" +
      "• Доступ к кластеру: удалённая среда — SSH + kubeconfig-fetch; только локальный MicroK8s — kubeconfig-microk8s-local (подменю «Кластер — бутстрап»).",
  },
  bootstrapSvc: {
    title: "Справка: бутстрап — сервис",
    body:
      "• Kafka bootstrap — цель kafka-bootstrap.\n" +
      "• Весь стек Helm — цель up с опциональным ограничением сервисов.",
  },
  manageEnv: {
    title: "Справка: управление — среда",
    body:
      "• Кластер и доступ — статус, kubeconfig, SSH, MicroK8s.\n" +
      "• Архив окружения — цель env-backup.\n" +
      "• Образы — save/push Bitnami-образов.\n" +
      "• Helm весь набор — цель up|diff|down.",
  },
  manageSvc: {
    title: "Справка: управление — сервис",
    body:
      "• Helm — diff всего набора или один компонент.\n" +
      "• Диагностика — логи, shell, данные Postgres, Netdata.\n" +
      "• Проверки чартов — verify / check-updates.\n" +
      "• Kafka — сброс данных и админка топиков (не путать с топиками по APP в меню приложения).",
  },
  verifyMenu: {
    title: "Справка: проверки Helm",
    body: verifyMenuBody(),
  },
  postgresAccounts: {
    title: "Справка: учётки PostgreSQL",
    body:
      "• Создать — цель pg-app-create.\n" +
      "• Показать креды — цель pg-app-show-creds.\n" +
      "• psql — цель pg-app-psql или postgres-db.\n" +
      "• Удалить — цель pg-app-drop (опасно).\n" +
      "• Проверить — цель pg-app-verify.",
  },
  postgresPsqlMode: {
    title: "Справка: режим psql",
    body:
      "• Прямое подключение — цель pg-app-psql.\n" +
      "• Через обёртку — цель postgres-db (дублирующая цель в репозитории).",
  },
  redisAccounts: {
    title: "Справка: учётки Redis",
    body:
      "• Создать — цель redis-app-create (ACL, REDIS_DB).\n" +
      "• Показать креды — цель redis-app-show-creds.\n" +
      "• Удалить — цель redis-app-drop.",
  },
  kafkaAccounts: {
    title: "Справка: учётки Kafka",
    body:
      "• Создать SASL — цель kafka-app-create.\n" +
      "• Показать креды — цель kafka-app-show-creds.\n" +
      "• Удалить — цель kafka-app-drop.",
  },
  minioAccounts: {
    title: "Справка: учётки MinIO",
    body:
      "• Создать пользователя и бакеты — цель minio-app-create.\n" +
      "• Добавить бакет — цель minio-app-append.\n" +
      "• Показать креды — цель minio-app-show-creds.\n" +
      "• Удалить — цель minio-app-drop.",
  },
  clickhouseAccounts: {
    title: "Справка: учётки ClickHouse",
    body:
      "• Создать — цель clickhouse-app-create.\n" +
      "• Показать креды — цель clickhouse-app-show-creds.\n" +
      "• Удалить — цель clickhouse-app-drop.",
  },
  rabbitAccounts: {
    title: "Справка: учётки RabbitMQ",
    body:
      "• Создать — цель rabbitmq-app-create.\n" +
      "• Показать креды — цель rabbitmq-app-show-creds.\n" +
      "• Удалить — цель rabbitmq-app-drop.",
  },
  accountsEngine: {
    title: "Справка: движок учёток",
    body:
      "Выбор СУБД/брокера для целей *-app-*.\n" +
      "Нужны секреты и записи в apps/conf; применение в кластер — apps-apply или отдельные цели *-app-*.",
  },
  kafkaOpsSvc: {
    title: "Справка: Kafka (кластер)",
    body:
      "• Сброс данных — цель kafka-reset (очень опасно).\n" +
      "• Изменить топик — цель kafka-topic-alter.\n" +
      "• Описание топика — цель kafka-topic-describe.\n" +
      "• Список топиков — цель kafka-topic-list (опционально PREFIX).",
  },
  kafkaOpsApp: {
    title: "Справка: Kafka (приложение)",
    body:
      "• Создать топик по APP — цель kafka-topic-create (TOPIC_SUFFIX).\n" +
      "• Остальные действия — те же цели alter/describe/list, что и для кластера.",
  },
  postgresData: {
    title: "Справка: Postgres — данные",
    body:
      "• Бэкап — цель postgres-backup.\n" +
      "• Восстановление — цель postgres-restore (BACKUP_FILE).\n" +
      "• Пересоздание — цель postgres-recreate-prep (цепочка с PVC).\n" +
      "• Удалить PVC — цель postgres-delete-pvcs (опасно).",
  },
  serviceBackup: {
    title: "Справка: бэкап и восстановление сервиса",
    body:
      "• Бэкап — цель <svc>-backup (для kafka/minio: -backup-meta; для rabbitmq: -backup-defs). Параметры не нужны.\n" +
      "• Восстановление — цель <svc>-restore (redis: -restore-acl; kafka: -restore-meta-topics; minio: -restore-meta; rabbitmq: -restore-defs). Запрашивается BACKUP_FILE; SKIP_CONFIRM=1 проставляется автоматически после явного подтверждения в TUI.\n" +
      "• Подробности форматов и тонкости restore — <svc>/BACKUP.md.",
  },
  monitoringExtras: {
    title: "Справка: Netdata — дополнительно",
    body:
      "• Топ узлов — цель monitoring-top-nodes.\n" +
      "• События namespace — цель monitoring-events.\n" +
      "• События/describe pod — monitoring-pod-events / monitoring-describe-pod.\n" +
      "• Подменю Helm — monitoring-up | diff | down.",
  },
  monitoringHelm: {
    title: "Справка: Netdata Helm",
    body:
      "• Развернуть/обновить — цель monitoring-up.\n" +
      "• Diff — цель monitoring-diff.\n" +
      "• Удалить релиз — цель monitoring-down (опасно).",
  },
  serviceDiag: {
    title: "Справка: диагностика компонента",
    body:
      "• Статус — цель <svc>-status или monitoring-status.\n" +
      "• Логи — *-logs; для Netdata — порт-форвард 19999 вместо shell.\n" +
      "• Shell — цель <svc>-shell (не для Netdata).\n" +
      "• Данные Postgres / расширенное Netdata — вложенные меню.",
  },
  diagnosticsPick: {
    title: "Справка: выбор сервиса",
    body:
      `${helmComponentsBody()}\n\n` +
      "Выбор ведёт в меню логов/статуса для этого компонента.",
  },
  k8sPortTop: {
    title: "Справка: TCP-порты на узле",
    body:
      "Интеграция с microk8s: nginx ingress TCP ConfigMap и при необходимости hostPort на DaemonSet.\n" +
      "• Показать — цель k8s-port-expose-show.\n" +
      "• Изменить — цель k8s-port-expose-patch (после серии вопросов).\n" +
      "• Применить YAML — k8s-port-expose-apply (файл k8s-port-expose/ports-ENV.yaml или PORT_EXPOSE_CONFIG).\n" +
      "Подробности: .claude/skills/k8s-port-expose-microk8s; пример полей — k8s-port-expose/ports.example.yaml.",
  },
  k8sPortLayer: {
    title: "Справка: слой проброса",
    body:
      "• tcp — правка ConfigMap маршрутизации TCP ingress (HOST_PORT → BACKEND).\n" +
      "• hostport — правка DaemonSet ingress-контроллера (OP add/rm).\n" +
      "«Назад» — выйти из мастера патча в предыдущее меню.",
  },
  k8sPortHostOp: {
    title: "Справка: hostPort",
    body:
      "• Добавить — CONTAINER_PORT, PORT_NAME для новой привязки.\n" +
      "• Удалить — убрать ранее добавленный hostPort для выбранного HOST_PORT.",
  },
  k8sPortDryRun: {
    title: "Справка: dry-run kubectl",
    body:
      "Режим DRY_RUN для patch: пусто — применить; client — проверка на клиенте; server — валидация на API без сохранения.",
  },
  configureEnvSelect: {
    title: "Справка: конфигуратор — окружение",
    body:
      "ENV задаёт профиль environments/<ENV>.yaml и kubeconfig для этой сессии.\n" +
      "Переопределения SSH/registry — environments/<ENV>.mk (локально, не в git).",
  },
  configureMode: {
    title: "Справка: режим конфигуратора",
    body:
      "• Секреты — запись в apps/conf/<APP>/secrets.yaml для merge и последующего apps-apply.\n" +
      "• Новое приложение — шаблон каталога apps/conf и опция добавления в apps/registry.yaml.\n" +
      "• По запросу — правка полей приложения прямо в apps/registry.yaml: enabled, app_ns, redis_db.",
  },
  configureAppPick: {
    title: "Справка: выбор приложения",
    body:
      "Имя из поля name в apps/registry.yaml. Для enabled:false merge можно не подхватывать до включения в registry.",
  },
  configureBackends: {
    title: "Справка: выбор бэкендов секретов",
    body:
      "Отметьте data-сервисы, для которых записать пароли в apps/conf/<APP>/secrets.yaml (для MinIO — ещё access_key и secret_key).\n" +
      "Записанные значения участвуют в merge и попадают в кластер при apps-apply.",
  },
};

export const INTRO_NOTE = {
  title: "О программе",
  tagline:
    "infra-lab — инструмент для работы со средой, стеком сервисов и приложениями на всём жизненном цикле (конфигурация, развёртывание, сопровождение).",
};
