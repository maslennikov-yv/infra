# kubeconfig files

В эту папку складываются kubeconfig файлы по окружениям.

Пример:
- `k8s/config/local`
- `k8s/config/prod`

Скачать kubeconfig с удалённого microk8s:

```bash
make kubeconfig-fetch ENV=local SSH_HOST=1.2.3.4 SSH_KEY=~/.ssh/id_ed25519
```

Локальный snap MicroK8s на этой машине (без SSH), в тот же путь `k8s/config/<ENV>`:

```bash
make kubeconfig-microk8s-local ENV=local
```

При ошибке прав доступа к `microk8s`: `MICROK8S_CMD='sudo microk8s'` или пользователь в группе `microk8s`.

