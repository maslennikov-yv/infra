#!/usr/bin/env node
// infra: TUI жизненного цикла инфры и приложений.
//
// Action-first меню. Старое объект-ориентированное меню (run.mjs) удалено в
// этапе 5 переработки; контекст сессии (ENV+APP) — в infra-control/context.mjs.

import { runInfraV2 } from "./infra-control/main.mjs";

await runInfraV2();
