# Документация infra

Карта runbook'ов и справочников по сценариям. Корневой [README.md](../README.md) — обзор репозитория, структура и быстрый старт.

## Маршруты по ролям

### «Я новый админ — что делать»

1. [docs/onboarding-admin.md](onboarding-admin.md) — какие файлы вне git нужны новому админу (kubeconfig, `environments/<env>.mk`, `apps/conf/`), безопасные каналы передачи, чек-лист доступа.
2. [docs/runbooks/usage-scenarios.md](runbooks/usage-scenarios.md) — типовые сценарии: **Сценарий 1 «Бутстрап нового окружения»** для первого деплоя.
3. Корневой [README.md → Быстрый старт](../README.md#быстрый-старт) — последовательность команд для свежего клона.

### «Мне нужна повседневная задача»

[docs/runbooks/usage-scenarios.md](runbooks/usage-scenarios.md) — 8 сценариев в порядке частоты:
бутстрап → новое приложение → ротация секретов → здоровье → бэкапы → +сервис → две среды → удалить.

### «Мне нужны учётки приложений»

[docs/pg-app.md](pg-app.md) — изоляция по `APP`: per-сервис цели `*-app-create` / `*-app-show-creds` / `*-app-drop`, чеклисты для PostgreSQL, Redis, Kafka, MinIO, ClickHouse, RabbitMQ.

### «У меня инцидент»

1. `make doctor ENV=…` — комплексная диагностика (тулинг + кластер + helm vs helmfile + rollouts + per-app verify).
2. Per-сервис: `<service>/TROUBLESHOOTING.md` (есть для PostgreSQL — типовые проблемы Pending/ImagePullBackOff/CrashLoopBackOff/PVC).
3. Логи и статус — `make <svc>-logs`, `make <svc>-status` (или TUI: `make infra-lab` → Управление → Сервис → Диагностика).

### «Сервер потерян — поднимаем заново»

1. [docs/runbooks/disaster-recovery.md](runbooks/disaster-recovery.md) — полный пошаговый runbook восстановления из git + env-backup + бэкапов данных.
2. Перед сценарием — убедитесь, что под рукой свежий `env-backup`-архив и бэкапы данных стейтфул-сервисов (см. ниже).

### «Бэкапы и проверка восстановления»

- Сценарий 5 в [usage-scenarios.md](runbooks/usage-scenarios.md): `make backup-all`, `make env-backup`, smoke-тест восстановления.
- Per-сервис формат и команды restore — `<service>/BACKUP.md` (postgres/redis/kafka/minio/clickhouse/rabbitmq).

### «Передаю секреты в git зашифрованными»

- Полный runbook: [docs/runbooks/secrets-management.md](runbooks/secrets-management.md) (sops + age для `apps/conf/<APP>/secrets.enc.yaml`).
- Краткая шпаргалка: [docs/runbooks/sops-quickstart.md](runbooks/sops-quickstart.md).

### «Открыть TCP-порт на ноде (microk8s ingress)»

- Skill: [`.claude/skills/k8s-port-expose-microk8s/SKILL.md`](../.claude/skills/k8s-port-expose-microk8s/SKILL.md) — `make k8s-port-expose-show / -patch / -apply / -diff`.
- Пример конфига: [`k8s-port-expose/ports.example.yaml`](../k8s-port-expose/ports.example.yaml).

## Per-service документация

Каждый сервис содержит свой `README.md` (общий обзор, особенности чарта, изоляция приложений) и `BACKUP.md` (формат и команды backup/restore):

- [postgres/README.md](../postgres/README.md), [postgres/BACKUP.md](../postgres/BACKUP.md), [postgres/TROUBLESHOOTING.md](../postgres/TROUBLESHOOTING.md)
- [redis/README.md](../redis/README.md), [redis/BACKUP.md](../redis/BACKUP.md)
- [kafka/README.md](../kafka/README.md), [kafka/BACKUP.md](../kafka/BACKUP.md)
- [minio/README.md](../minio/README.md), [minio/BACKUP.md](../minio/BACKUP.md) (+ presigned URL, CORS, профили бакетов)
- [clickhouse/README.md](../clickhouse/README.md), [clickhouse/BACKUP.md](../clickhouse/BACKUP.md)
- [rabbitmq/README.md](../rabbitmq/README.md), [rabbitmq/BACKUP.md](../rabbitmq/BACKUP.md)
- [monitoring/netdata/README.md](../monitoring/netdata/README.md) — single-node coverage, RBAC, кастомные алерты, уведомления.
