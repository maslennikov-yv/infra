# kubeconfig files

В эту папку складываются kubeconfig файлы по окружениям.

Пример:
- `k8s/config/dev`
- `k8s/config/prod`

Скачать kubeconfig с удалённого microk8s:

```bash
make kubeconfig-fetch ENV=dev SSH_HOST=1.2.3.4 SSH_KEY=~/.ssh/id_ed25519
```

