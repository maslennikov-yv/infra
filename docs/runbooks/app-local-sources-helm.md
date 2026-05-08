# Исходники приложения через hostPath: декларативно в Helm чарте (local)

**Предпочтительный** способ для репозитория приложения: том и `volumeMount` задаются в чарте и `values`; `helm upgrade` не затирает монтирование так, как может произойти при ручном `kubectl patch` поверх живого ресурса.

Запасной путь только из infra (без правки чарта): [`make app-local-src-hostpath-mount`](../../Makefile) при `ENV=local` и указании workload (`APP_LOCAL_K8S_WORKLOAD=…`). См. справку в infra-lab.

## Контекст

- Стек платформы (PostgreSQL, Redis, …) остаётся в этом репозитории `infra` и **helmfile**.
- Развёртывание **самого приложения** — в своём репозитории и своём Helm-чарте.
- Каталог с кодом на машине разработчика в контексте infra: `apps/src/<APP>` (клон из registry или руками). Абсолютный путь к нему на хосте = тот же путь, который увидит kubelet при `hostPath` на однодовом microk8s.

## 1. Values

Скопируйте блок в `values-local.yaml` (или аналог) **приложения** и допишите шаблоны под свой чарт:

- Образец: [apps/conf/_example/helm-app-volumes-values.yaml](../../apps/conf/_example/helm-app-volumes-values.yaml).

Пока `app.volumes.enabled: false`, в шаблоне не нужно добавлять том (или оберните добавление в `if` ниже).

## 2. Фрагмент шаблона (Deployment / Pod)

Имена полей и ключи ниже можно переименовать в своём чарте главное — **единообразие** между `values` и шаблоном.

Путь монтирования в контейнере (`mountPath`) задаётте под приложение — ниже условное `/var/www/html` только как пример.

```yaml
# Внутри spec.template.spec (Deployment) или spec (Pod)
{{- if .Values.app.volumes.enabled }}
      volumes:
        - name: app-src
          hostPath:
            path: {{ .Values.app.volumes.hostPath | quote }}
            type: Directory
{{- end }}

# У каждого контейнера, которому нужен код с хоста:
{{- if .Values.app.volumes.enabled }}
          volumeMounts:
            - name: app-src
              mountPath: /var/www/html
{{- end }}
```

`type: Directory` строже, чем `DirectoryOrCreate`: при неверном пути на ноде pod не получит «тихое» создание каталога.

## 3. Готовые аргументы `helm upgrade` из infra

Из корня **этого** репозитория `infra`, при активной машине разработки с microk8s и существующем каталоге `apps/src/<APP>`:

```bash
make apps-local-src-helm-sets ENV=local APP=myapp
```

На stdout будет строка вида `--set app.volumes.enabled=true --set app.volumes.hostPath="..."` с **абсолютным** путём к `apps/src/myapp`.

Вставьте вывод в свою команду `helm upgrade --install` в **репозитории приложения** (вместе с `--values values-local.yaml` и т.д.).

**Важно:** без `app.volumes.enabled=true` в values или в `--set` том в шаблоне не появится, даже если `hostPath` задан.

## 4. Многоузловой кластер

`hostPath` указывает на конкретную ноду: pod, запланированный не на ту ноду, не увидит ваш каталог с разработческой машины. Для local/microk8s обычно одна нода.

## 5. infra-lab

При сессии `ENV=local`: **Конфигурирование → Приложение → Вывести helm --set для local hostPath** — запросит `APP` и выполнит ту же цель `make`.
