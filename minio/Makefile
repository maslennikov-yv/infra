.PHONY: help \
	images-verify images-pull images-tag images-push images-sync images-save images-load images-sync-from-files images-clean images-clean-files \
	install upgrade uninstall status logs shell app-create app-show-creds app-drop \
	backup-meta restore-meta list-backups \
	check-registry check-updates

REGISTRY ?= localhost:32000

NAMESPACE ?= minio
RELEASE ?= minio
CHART_PATH ?= minio
ENV ?= local
VALUES_FILE ?= values-$(ENV).yaml

INFRA_ROOT ?= $(abspath $(CURDIR)/..)
APPS_REGISTRY ?= $(INFRA_ROOT)/apps/registry.yaml

# Image tags pinned from chart values.yaml/Chart.yaml annotations
MINIO_TAG ?= 2025.7.23-debian-12-r3
MINIO_CLIENT_TAG ?= 2025.7.21-debian-12-r2
MINIO_OBJECT_BROWSER_TAG ?= 2.0.2-debian-12-r3
OS_SHELL_TAG ?= 12-debian-12-r50

# Source tags (can override; default is pinned tags)
MINIO_SRC_TAG ?= $(MINIO_TAG)
MINIO_CLIENT_SRC_TAG ?= $(MINIO_CLIENT_TAG)
MINIO_OBJECT_BROWSER_SRC_TAG ?= $(MINIO_OBJECT_BROWSER_TAG)
OS_SHELL_SRC_TAG ?= $(OS_SHELL_TAG)

# Source images (только docker.io/bitnamilegacy)
MINIO_IMAGE_SRC := docker.io/bitnamilegacy/minio:$(MINIO_SRC_TAG)
MINIO_CLIENT_IMAGE_SRC := docker.io/bitnamilegacy/minio-client:$(MINIO_CLIENT_SRC_TAG)
MINIO_OBJECT_BROWSER_IMAGE_SRC := docker.io/bitnamilegacy/minio-object-browser:$(MINIO_OBJECT_BROWSER_SRC_TAG)
OS_SHELL_IMAGE_SRC := docker.io/bitnamilegacy/os-shell:$(OS_SHELL_SRC_TAG)

# Local registry tags (repository as in chart)
MINIO_IMAGE_LOCAL := $(REGISTRY)/bitnami/minio:$(MINIO_TAG)
MINIO_CLIENT_IMAGE_LOCAL := $(REGISTRY)/bitnami/minio-client:$(MINIO_CLIENT_TAG)
MINIO_OBJECT_BROWSER_IMAGE_LOCAL := $(REGISTRY)/bitnami/minio-object-browser:$(MINIO_OBJECT_BROWSER_TAG)
OS_SHELL_IMAGE_LOCAL := $(REGISTRY)/bitnami/os-shell:$(OS_SHELL_TAG)

IMAGES_SRC := $(MINIO_IMAGE_SRC) $(MINIO_CLIENT_IMAGE_SRC) $(MINIO_OBJECT_BROWSER_IMAGE_SRC) $(OS_SHELL_IMAGE_SRC)
IMAGES_LOCAL := $(MINIO_IMAGE_LOCAL) $(MINIO_CLIENT_IMAGE_LOCAL) $(MINIO_OBJECT_BROWSER_IMAGE_LOCAL) $(OS_SHELL_IMAGE_LOCAL)

IMAGES_DIR ?= images

help:
	@echo "MinIO"
	@echo ""
	@echo "Helm:"
	@echo "  make install            - Установить MinIO в namespace $(NAMESPACE)"
	@echo "  make upgrade            - Обновить MinIO"
	@echo "  make uninstall          - Удалить MinIO (⚠ удалит release)"
	@echo "  make status             - Показать статус MinIO"
	@echo ""
	@echo "Images:"
	@echo "  make images-verify       - проверить доступность тегов в docker.io/bitnamilegacy"
	@echo "  make images-save         - Скачать и сохранить tar"
	@echo "  make images-sync-from-files - docker load + tag + push в $(REGISTRY)"
	@echo ""
	@echo "App accounts:"
	@echo "  make app-create APP=myapp [APP_NS=...] — см. комментарии в Makefile"
	@echo "  make app-show-creds APP=myapp [APP_NS=...] — креды из Secret приложения (APP-minio)"
	@echo "  make app-drop APP=myapp — пользователь, политика, Secret (⚠ y/N; SKIP_CONFIRM=1). MINIO_REMOVE_BUCKETS=1 — удалить bucket (второй запрос y/N)"
	@echo "  make app-append APP=myapp BUCKET=... — добавить bucket к существующей учётке"
	@echo ""
	@echo "Backup / Restore (definitions; объекты бакетов НЕ бэкапятся — используйте mc mirror, см. minio/BACKUP.md):"
	@echo "  make backup-meta              - tar.gz: users + policies + buckets + tracking secrets minio-app-*"
	@echo "  make restore-meta BACKUP_FILE=... — восстановить policies + tracking secrets (⚠ y/N; SKIP_CONFIRM=1)"
	@echo "  make list-backups             - список meta-бэкапов"

## =========================
## App accounts (per-app isolation)
## =========================

# Usage:
#   make app-create APP=myapp \
#     [APP_NS=myapp] [BUCKET=myapp] [PREFIX=foo/] \
#     [ACCESS_MODE=private_rw|private_ro|private_wo] [PUBLIC_READ=true|false] [PUBLIC_LIST=true|false] \
#     [VERSIONING=enable|suspend|skip] [QUOTA=10Gi|skip] [TAGS=k=v,k2=v2|skip] [LIFECYCLE_JSON=path.json|skip] \
#     [OBJECT_LOCK=skip|governance|compliance] [RETENTION_DAYS=N] \
#     [ACCESS_KEY=...] [SECRET_KEY=...] [MINIO_SCHEME=http] \
#     [APP_PUBLIC_ENDPOINT=https://files.appA.com]
app-create:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-create APP=myapp)"; exit 1; fi
	@INF="$(INFRA_ROOT)"; REG="$(APPS_REGISTRY)"; \
	MG="$${APPS_MERGED_FILE:-}"; CLEAN_MG=0; \
	if [ -z "$$MG" ]; then MG=$$(mktemp); CLEAN_MG=1; "$$INF/scripts/apps-merge-config.sh" "$$REG" "$$INF" >"$$MG"; fi; \
	trap 'if [ "$$CLEAN_MG" = 1 ]; then rm -f "$$MG"; fi' EXIT; \
	APP_NS=$${APP_NS:-$(APP)}; \
	BUCKET=$${BUCKET:-$(APP)}; \
	PREFIX=$${PREFIX:-}; \
	ACCESS_MODE=$${ACCESS_MODE:-private_rw}; \
	PUBLIC_READ=$${PUBLIC_READ:-false}; \
	PUBLIC_LIST=$${PUBLIC_LIST:-false}; \
	VERSIONING=$${VERSIONING:-skip}; \
	QUOTA=$${QUOTA:-skip}; \
	TAGS=$${TAGS:-skip}; \
	LIFECYCLE_JSON=$${LIFECYCLE_JSON:-skip}; \
	OBJECT_LOCK=$${OBJECT_LOCK:-skip}; \
	RETENTION_DAYS=$${RETENTION_DAYS:-}; \
	MINIO_SCHEME=$${MINIO_SCHEME:-http}; \
	APP_PUBLIC_ENDPOINT=$${APP_PUBLIC_ENDPOINT:-}; \
	SK_MERGED=$$("$$INF/scripts/app-config-get.sh" "$$MG" "$(APP)" minio.secret_key || true); \
	AK_MERGED=$$("$$INF/scripts/app-config-get.sh" "$$MG" "$(APP)" minio.access_key || true); \
	ACCESS_KEY_RAW=$${ACCESS_KEY:-}; \
	if [ -n "$$ACCESS_KEY_RAW" ] && [ "$$ACCESS_KEY_RAW" != "null" ]; then ACCESS_KEY="$$ACCESS_KEY_RAW"; \
	elif [ -n "$$AK_MERGED" ] && [ "$$AK_MERGED" != "null" ]; then ACCESS_KEY="$$AK_MERGED"; \
	else ACCESS_KEY=app_$(APP); fi; \
	SECRET_KEY_RAW=$${SECRET_KEY:-}; \
	if [ -n "$$SECRET_KEY_RAW" ]; then SECRET_KEY="$$SECRET_KEY_RAW"; else SECRET_KEY="$$SK_MERGED"; fi; \
	if [ -z "$$SECRET_KEY" ] || [ "$$SECRET_KEY" = "null" ]; then \
		echo "✗ Задайте minio.secret_key для $(APP) в apps/conf/$(APP)/ (или передайте SECRET_KEY=...)"; exit 1; \
	fi; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-minio}; \
	LIFECYCLE_B64=""; \
	if [ "$$LIFECYCLE_JSON" != "skip" ]; then \
		if [ ! -f "$$LIFECYCLE_JSON" ]; then echo "✗ LIFECYCLE_JSON файл не найден: $$LIFECYCLE_JSON"; exit 1; fi; \
		LIFECYCLE_B64=$$(base64 -w0 "$$LIFECYCLE_JSON" 2>/dev/null || base64 "$$LIFECYCLE_JSON" | tr -d '\n'); \
	fi; \
	ROOT_USER=$$(kubectl get secret --namespace $(NAMESPACE) $(RELEASE) -o jsonpath='{.data.root-user}' 2>/dev/null | base64 -d); \
	ROOT_PASSWORD=$$(kubectl get secret --namespace $(NAMESPACE) $(RELEASE) -o jsonpath='{.data.root-password}' 2>/dev/null | base64 -d); \
	if [ -z "$$ROOT_USER" ] || [ -z "$$ROOT_PASSWORD" ]; then \
		echo "✗ Не удалось получить root creds из секрета $(RELEASE) в namespace $(NAMESPACE)"; \
		exit 1; \
	fi; \
	MINIO_HOST="$(RELEASE).$(NAMESPACE).svc.cluster.local"; \
	MINIO_ENDPOINT="$$MINIO_SCHEME://$$MINIO_HOST:9000"; \
	MINIO_PUBLIC_ENDPOINT="$$APP_PUBLIC_ENDPOINT"; \
	if [ -z "$$MINIO_PUBLIC_ENDPOINT" ]; then MINIO_PUBLIC_ENDPOINT="$$MINIO_ENDPOINT"; fi; \
	POLICY_NAME="app-$(APP)"; \
	echo "Creating bucket/user/policy for app=$(APP) bucket=$$BUCKET prefix=$$PREFIX access_mode=$$ACCESS_MODE public_read=$$PUBLIC_READ public_list=$$PUBLIC_LIST"; \
	kubectl run minio-mc-$$(date +%s) \
		--restart='Never' \
		--image=$(MINIO_CLIENT_IMAGE_LOCAL) \
		--namespace=$(NAMESPACE) \
		--rm -i \
		--env="ROOT_USER=$$ROOT_USER" \
		--env="ROOT_PASSWORD=$$ROOT_PASSWORD" \
		--env="MINIO_ENDPOINT=$$MINIO_ENDPOINT" \
		--env="BUCKET=$$BUCKET" \
		--env="PREFIX=$$PREFIX" \
		--env="ACCESS_MODE=$$ACCESS_MODE" \
		--env="PUBLIC_READ=$$PUBLIC_READ" \
		--env="PUBLIC_LIST=$$PUBLIC_LIST" \
		--env="VERSIONING=$$VERSIONING" \
		--env="QUOTA=$$QUOTA" \
		--env="TAGS=$$TAGS" \
		--env="LIFECYCLE_B64=$$LIFECYCLE_B64" \
		--env="OBJECT_LOCK=$$OBJECT_LOCK" \
		--env="RETENTION_DAYS=$$RETENTION_DAYS" \
		--env="ACCESS_KEY=$$ACCESS_KEY" \
		--env="SECRET_KEY=$$SECRET_KEY" \
		--env="POLICY_NAME=$$POLICY_NAME" \
		--command -- sh -ec "\
			mc alias set minio \"$$MINIO_ENDPOINT\" \"$$ROOT_USER\" \"$$ROOT_PASSWORD\";\n\
			# bucket create (object-lock must be enabled at creation time)\n\
			if [ \"$$OBJECT_LOCK\" != \"skip\" ]; then \n\
			  mc mb --with-lock -p \"minio/$$BUCKET\" || true; \n\
			else \n\
			  mc mb -p \"minio/$$BUCKET\" || true; \n\
			fi;\n\
			# Build app policy\n\
			PREFIX_RESOURCE=\"arn:aws:s3:::$$BUCKET/*\";\n\
			LIST_CONDITION=\"\";\n\
			if [ -n \"$$PREFIX\" ]; then \n\
			  # objects only under prefix\n\
			  PREFIX_RESOURCE=\"arn:aws:s3:::$$BUCKET/$$PREFIX*\";\n\
			  LIST_CONDITION=\",\\n      \\\"Condition\\\": {\\n        \\\"StringLike\\\": {\\n          \\\"s3:prefix\\\": [\\\"$$PREFIX*\\\"]\\n        }\\n      }\";\n\
			fi;\n\
			OBJ_ACTIONS=\"\\\"s3:GetObject\\\",\\\"s3:PutObject\\\",\\\"s3:DeleteObject\\\"\";\n\
			case \"$$ACCESS_MODE\" in \n\
			  private_rw) OBJ_ACTIONS=\"\\\"s3:GetObject\\\",\\\"s3:PutObject\\\",\\\"s3:DeleteObject\\\"\";;\n\
			  private_ro) OBJ_ACTIONS=\"\\\"s3:GetObject\\\"\";;\n\
			  private_wo) OBJ_ACTIONS=\"\\\"s3:PutObject\\\",\\\"s3:AbortMultipartUpload\\\",\\\"s3:ListMultipartUploadParts\\\"\";;\n\
			  *) echo \"✗ Unknown ACCESS_MODE=$$ACCESS_MODE\"; exit 1;;\n\
			esac;\n\
			cat > /tmp/policy.json <<EOF\n\
{\n\
  \"Version\": \"2012-10-17\",\n\
  \"Statement\": [\n\
    {\n\
      \"Effect\": \"Allow\",\n\
      \"Action\": [\"s3:GetBucketLocation\",\"s3:ListBucket\"],\n\
      \"Resource\": [\"arn:aws:s3:::$$BUCKET\"]$${LIST_CONDITION}\n\
    },\n\
    {\n\
      \"Effect\": \"Allow\",\n\
      \"Action\": [ $${OBJ_ACTIONS} ],\n\
      \"Resource\": [\"$${PREFIX_RESOURCE}\"]\n\
    }\n\
  ]\n\
}\n\
EOF\n\
			mc admin policy create minio \"$$POLICY_NAME\" /tmp/policy.json || mc admin policy info minio \"$$POLICY_NAME\" >/dev/null;\n\
			mc admin user add minio \"$$ACCESS_KEY\" \"$$SECRET_KEY\" || true;\n\
			mc admin policy attach minio \"$$POLICY_NAME\" --user \"$$ACCESS_KEY\";\n\
			# public access (best-effort)\n\
			if [ \"$$PUBLIC_READ\" = \"true\" ] || [ \"$$PUBLIC_LIST\" = \"true\" ]; then \n\
			  PUB_PREFIX_RESOURCE=\"arn:aws:s3:::$$BUCKET/*\";\n\
			  PUB_LIST_CONDITION=\"\";\n\
			  if [ -n \"$$PREFIX\" ]; then \n\
			    PUB_PREFIX_RESOURCE=\"arn:aws:s3:::$$BUCKET/$$PREFIX*\";\n\
			    PUB_LIST_CONDITION=\",\\n      \\\"Condition\\\": {\\n        \\\"StringLike\\\": {\\n          \\\"s3:prefix\\\": [\\\"$$PREFIX*\\\"]\\n        }\\n      }\";\n\
			  fi;\n\
			  cat > /tmp/public.json <<EOF\n\
{\n\
  \"Version\": \"2012-10-17\",\n\
  \"Statement\": [\n\
    {\n\
      \"Effect\": \"Allow\",\n\
      \"Principal\": \"*\",\n\
      \"Action\": [\"s3:GetObject\"],\n\
      \"Resource\": [\"$${PUB_PREFIX_RESOURCE}\"]\n\
    }\n\
  ]\n\
}\n\
EOF\n\
			  if [ \"$$PUBLIC_LIST\" = \"true\" ]; then \n\
			    cat > /tmp/public.json <<EOF\n\
{\n\
  \"Version\": \"2012-10-17\",\n\
  \"Statement\": [\n\
    {\n\
      \"Effect\": \"Allow\",\n\
      \"Principal\": \"*\",\n\
      \"Action\": [\"s3:GetObject\"],\n\
      \"Resource\": [\"$${PUB_PREFIX_RESOURCE}\"]\n\
    },\n\
    {\n\
      \"Effect\": \"Allow\",\n\
      \"Principal\": \"*\",\n\
      \"Action\": [\"s3:GetBucketLocation\",\"s3:ListBucket\"],\n\
      \"Resource\": [\"arn:aws:s3:::$$BUCKET\"]$${PUB_LIST_CONDITION}\n\
    }\n\
  ]\n\
}\n\
EOF\n\
			  fi;\n\
			  # Prefer setting a custom anonymous policy. If unsupported, ignore.\n\
			  mc anonymous set-json /tmp/public.json \"minio/$$BUCKET\" 2>/dev/null || true;\n\
			fi;\n\
			# versioning\n\
			if [ \"$$VERSIONING\" = \"enable\" ]; then mc version enable \"minio/$$BUCKET\" || true; fi;\n\
			if [ \"$$VERSIONING\" = \"suspend\" ]; then mc version suspend \"minio/$$BUCKET\" || true; fi;\n\
			# quota\n\
			if [ \"$$QUOTA\" != \"skip\" ]; then mc quota set \"minio/$$BUCKET\" --size \"$$QUOTA\" || true; fi;\n\
			# tags\n\
			if [ \"$$TAGS\" != \"skip\" ]; then mc tag set \"minio/$$BUCKET\" \"$$TAGS\" || true; fi;\n\
			# lifecycle\n\
			if [ -n \"$$LIFECYCLE_B64\" ]; then echo \"$$LIFECYCLE_B64\" | base64 -d > /tmp/lifecycle.json 2>/dev/null || echo \"$$LIFECYCLE_B64\" | base64 -D > /tmp/lifecycle.json; mc ilm import \"minio/$$BUCKET\" < /tmp/lifecycle.json || true; fi;\n\
			# object lock retention (best-effort)\n\
			if [ \"$$OBJECT_LOCK\" != \"skip\" ] && [ -n \"$$RETENTION_DAYS\" ]; then \n\
			  MODE_UP=$$(echo \"$$OBJECT_LOCK\" | tr '[:lower:]' '[:upper:]');\n\
			  mc retention set --default \"$${MODE_UP}\" \"$${RETENTION_DAYS}d\" \"minio/$$BUCKET\" 2>/dev/null || true;\n\
			fi;\n\
		"; \
	echo "Creating Secret $$APP_SECRET_NAME in namespace $$APP_NS"; \
	kubectl create namespace "$$APP_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; \
	kubectl delete secret "$$APP_SECRET_NAME" -n "$$APP_NS" --ignore-not-found >/dev/null; \
	kubectl create secret generic "$$APP_SECRET_NAME" -n "$$APP_NS" \
		--from-literal=MINIO_ENDPOINT="$$MINIO_ENDPOINT" \
		--from-literal=MINIO_PUBLIC_ENDPOINT="$$MINIO_PUBLIC_ENDPOINT" \
		--from-literal=AWS_ACCESS_KEY_ID="$$ACCESS_KEY" \
		--from-literal=AWS_SECRET_ACCESS_KEY="$$SECRET_KEY" \
		--from-literal=S3_BUCKET="$$BUCKET" \
		--from-literal=S3_PREFIX="$$PREFIX" \
		--from-literal=AWS_REGION="us-east-1" \
		>/dev/null; \
	echo "Creating tracking Secret minio-app-$(APP) in namespace $(NAMESPACE)"; \
	kubectl delete secret "minio-app-$(APP)" -n "$(NAMESPACE)" --ignore-not-found >/dev/null; \
	printf '%s' "[{\"bucket\":\"$$BUCKET\",\"prefix\":\"$$PREFIX\",\"access_mode\":\"$$ACCESS_MODE\",\"public_read\":$${PUBLIC_READ},\"public_list\":$${PUBLIC_LIST}}]" | \
		kubectl create secret generic "minio-app-$(APP)" -n "$(NAMESPACE)" --from-file=buckets.json=/dev/stdin >/dev/null; \
	printf '%s\n' \
		'minio:' \
		"  access_key: \"$$ACCESS_KEY\"" \
		"  secret_key: \"$$SECRET_KEY\"" \
		"  bucket: \"$$BUCKET\"" \
		"  prefix: \"$$PREFIX\"" \
		"  scheme: \"$$MINIO_SCHEME\"" \
		"  endpoint: \"$$MINIO_ENDPOINT\"" \
		"  public_endpoint: \"$$MINIO_PUBLIC_ENDPOINT\"" \
	| "$$INF/scripts/app-conf-set.sh" "$$INF" "$(APP)"; \
	echo "✓ Done (Secret: $$APP_NS/$$APP_SECRET_NAME)"

# Usage: make app-show-creds APP=myapp [APP_NS=myapp]
app-show-creds:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-show-creds APP=myapp)"; exit 1; fi
	@APP_NS=$${APP_NS:-$(APP)}; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-minio}; \
	if ! kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" >/dev/null 2>&1; then \
		echo "✗ Secret $$APP_SECRET_NAME не найден в namespace $$APP_NS"; exit 1; \
	fi; \
	echo "Secret: $$APP_NS/$$APP_SECRET_NAME"; \
	echo "---"; \
	for k in MINIO_ENDPOINT MINIO_PUBLIC_ENDPOINT AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY S3_BUCKET S3_PREFIX AWS_REGION; do \
		v=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath="{.data.$$k}" 2>/dev/null | base64 -d); \
		echo "$$k=$$v"; \
	done

# Append one bucket/prefix to existing app account (rebuild policy from tracking secret)
# Usage: make app-append APP=myapp BUCKET=b2 [PREFIX=data/] [ACCESS_MODE=private_rw|private_ro|private_wo] [PUBLIC_READ=true|false] [PUBLIC_LIST=true|false] [APP_PUBLIC_ENDPOINT=https://files.appA.com]
app-append:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан"; exit 1; fi
	@if [ -z "$(BUCKET)" ]; then echo "✗ BUCKET не задан"; exit 1; fi
	@PREFIX=$${PREFIX:-}; \
	ACCESS_MODE=$${ACCESS_MODE:-private_rw}; \
	PUBLIC_READ=$${PUBLIC_READ:-false}; \
	PUBLIC_LIST=$${PUBLIC_LIST:-false}; \
	MINIO_SCHEME=$${MINIO_SCHEME:-http}; \
	APP_PUBLIC_ENDPOINT=$${APP_PUBLIC_ENDPOINT:-}; \
	ACCESS_KEY=$${ACCESS_KEY:-app_$(APP)}; \
	ROOT_USER=$$(kubectl get secret --namespace $(NAMESPACE) $(RELEASE) -o jsonpath='{.data.root-user}' 2>/dev/null | base64 -d); \
	ROOT_PASSWORD=$$(kubectl get secret --namespace $(NAMESPACE) $(RELEASE) -o jsonpath='{.data.root-password}' 2>/dev/null | base64 -d); \
	if [ -z "$$ROOT_USER" ] || [ -z "$$ROOT_PASSWORD" ]; then echo "✗ Не удалось получить root creds"; exit 1; fi; \
	TRACK=$$(kubectl get secret -n $(NAMESPACE) "minio-app-$(APP)" -o jsonpath='{.data.buckets\\.json}' 2>/dev/null | base64 -d); \
	if [ -z "$$TRACK" ]; then echo "✗ Tracking secret minio-app-$(APP) не найден (сначала app-create)"; exit 1; fi; \
	MINIO_HOST="$(RELEASE).$(NAMESPACE).svc.cluster.local"; \
	MINIO_ENDPOINT="$$MINIO_SCHEME://$$MINIO_HOST:9000"; \
	POLICY_NAME="app-$(APP)"; \
	echo "Append bucket=$(BUCKET) prefix=$$PREFIX to app=$(APP)"; \
	kubectl run minio-mc-$$(date +%s) \
		--restart='Never' \
		--image=$(MINIO_CLIENT_IMAGE_LOCAL) \
		--namespace=$(NAMESPACE) \
		--rm -i \
		--env="ROOT_USER=$$ROOT_USER" \
		--env="ROOT_PASSWORD=$$ROOT_PASSWORD" \
		--env="MINIO_ENDPOINT=$$MINIO_ENDPOINT" \
		--env="NEW_BUCKET=$(BUCKET)" \
		--env="NEW_PREFIX=$$PREFIX" \
		--env="NEW_ACCESS_MODE=$$ACCESS_MODE" \
		--env="NEW_PUBLIC_READ=$$PUBLIC_READ" \
		--env="NEW_PUBLIC_LIST=$$PUBLIC_LIST" \
		--env="ACCESS_KEY=$$ACCESS_KEY" \
		--env="POLICY_NAME=$$POLICY_NAME" \
		--env="TRACK_JSON=$$TRACK" \
		--command -- sh -ec "\
			mc alias set minio \"$$MINIO_ENDPOINT\" \"$$ROOT_USER\" \"$$ROOT_PASSWORD\";\n\
			mc mb -p \"minio/$$NEW_BUCKET\" || true;\n\
			# update tracking json\n\
			python3 - <<'PY'\n\
import json, os\n\
track=json.loads(os.environ.get('TRACK_JSON','[]') or '[]')\n\
entry={\n\
  'bucket': os.environ['NEW_BUCKET'],\n\
  'prefix': os.environ.get('NEW_PREFIX','') or '',\n\
  'access_mode': os.environ.get('NEW_ACCESS_MODE','private_rw') or 'private_rw',\n\
  'public_read': (os.environ.get('NEW_PUBLIC_READ','false').lower()=='true'),\n\
  'public_list': (os.environ.get('NEW_PUBLIC_LIST','false').lower()=='true'),\n\
}\n\
track.append(entry)\n\
print(json.dumps(track, separators=(',',':')))\n\
PY\n\
			> /tmp/buckets.json;\n\
			# build combined policy\n\
			python3 - <<'PY'\n\
import json\n\
track=json.load(open('/tmp/buckets.json'))\n\
stm=[]\n\
for e in track:\n\
  b=e['bucket']; p=e.get('prefix','') or ''\n\
  list_stmt={\n\
    'Effect':'Allow',\n\
    'Action':['s3:GetBucketLocation','s3:ListBucket'],\n\
    'Resource':[f'arn:aws:s3:::{b}'],\n\
  }\n\
  if p:\n\
    list_stmt['Condition']={'StringLike':{'s3:prefix':[f'{p}*']}}\n\
  mode=e.get('access_mode','private_rw')\n\
  if mode=='private_ro':\n\
    actions=['s3:GetObject']\n\
  elif mode=='private_wo':\n\
    actions=['s3:PutObject','s3:AbortMultipartUpload','s3:ListMultipartUploadParts']\n\
  else:\n\
    actions=['s3:GetObject','s3:PutObject','s3:DeleteObject']\n\
  obj_stmt={\n\
    'Effect':'Allow',\n\
    'Action':actions,\n\
    'Resource':[f'arn:aws:s3:::{b}/{p}*' if p else f'arn:aws:s3:::{b}/*'],\n\
  }\n\
  stm.append(list_stmt)\n\
  stm.append(obj_stmt)\n\
policy={'Version':'2012-10-17','Statement':stm}\n\
print(json.dumps(policy, indent=2))\n\
PY\n\
			> /tmp/policy.json;\n\
			mc admin policy create minio \"$$POLICY_NAME\" /tmp/policy.json || mc admin policy info minio \"$$POLICY_NAME\" >/dev/null;\n\
			mc admin policy attach minio \"$$POLICY_NAME\" --user \"$$ACCESS_KEY\";\n\
			# public for NEW bucket (best-effort)\n\
			if [ \"$$NEW_PUBLIC_READ\" = \"true\" ] || [ \"$$NEW_PUBLIC_LIST\" = \"true\" ]; then \n\
			  PUB_PREFIX_RESOURCE=\"arn:aws:s3:::$$NEW_BUCKET/*\";\n\
			  PUB_LIST_CONDITION=\"\";\n\
			  if [ -n \"$$NEW_PREFIX\" ]; then \n\
			    PUB_PREFIX_RESOURCE=\"arn:aws:s3:::$$NEW_BUCKET/$$NEW_PREFIX*\";\n\
			    PUB_LIST_CONDITION=\",\\n      \\\"Condition\\\": {\\n        \\\"StringLike\\\": {\\n          \\\"s3:prefix\\\": [\\\"$$NEW_PREFIX*\\\"]\\n        }\\n      }\";\n\
			  fi;\n\
			  cat > /tmp/public.json <<EOF\n\
{\n\
  \"Version\": \"2012-10-17\",\n\
  \"Statement\": [\n\
    {\n\
      \"Effect\": \"Allow\",\n\
      \"Principal\": \"*\",\n\
      \"Action\": [\"s3:GetObject\"],\n\
      \"Resource\": [\"$${PUB_PREFIX_RESOURCE}\"]\n\
    }\n\
  ]\n\
}\n\
EOF\n\
			  if [ \"$$NEW_PUBLIC_LIST\" = \"true\" ]; then \n\
			    cat > /tmp/public.json <<EOF\n\
{\n\
  \"Version\": \"2012-10-17\",\n\
  \"Statement\": [\n\
    {\n\
      \"Effect\": \"Allow\",\n\
      \"Principal\": \"*\",\n\
      \"Action\": [\"s3:GetObject\"],\n\
      \"Resource\": [\"$${PUB_PREFIX_RESOURCE}\"]\n\
    },\n\
    {\n\
      \"Effect\": \"Allow\",\n\
      \"Principal\": \"*\",\n\
      \"Action\": [\"s3:GetBucketLocation\",\"s3:ListBucket\"],\n\
      \"Resource\": [\"arn:aws:s3:::$$NEW_BUCKET\"]$${PUB_LIST_CONDITION}\n\
    }\n\
  ]\n\
}\n\
EOF\n\
			  fi;\n\
			  mc anonymous set-json /tmp/public.json \"minio/$$NEW_BUCKET\" 2>/dev/null || true;\n\
			fi;\n\
			# print updated buckets.json to stdout for the outer make\n\
			cat /tmp/buckets.json;\n\
		" > /tmp/minio-buckets.json; \
	kubectl delete secret "minio-app-$(APP)" -n "$(NAMESPACE)" --ignore-not-found >/dev/null; \
	kubectl create secret generic "minio-app-$(APP)" -n "$(NAMESPACE)" --from-file=buckets.json=/tmp/minio-buckets.json >/dev/null; \
	echo "✓ Done (updated tracking secret: $(NAMESPACE)/minio-app-$(APP))"

# Usage: make app-drop APP=myapp [APP_NS=myapp] [ACCESS_KEY=...] [SKIP_CONFIRM=1] [MINIO_REMOVE_BUCKETS=1]
app-drop:
	@if [ -z "$(APP)" ]; then echo "✗ APP не задан (пример: make app-drop APP=myapp)"; exit 1; fi
	@APP_NS=$${APP_NS:-$(APP)}; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-minio}; \
	POLICY_NAME="app-$(APP)"; \
	AK_FROM_SECRET=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d); \
	if [ -n "$(ACCESS_KEY)" ]; then ACCESS_KEY_VAL="$(ACCESS_KEY)"; \
	elif [ -n "$$AK_FROM_SECRET" ]; then ACCESS_KEY_VAL="$$AK_FROM_SECRET"; \
	else ACCESS_KEY_VAL="app_$(APP)"; fi; \
	MINIO_ENDPOINT=$$(kubectl get secret "$$APP_SECRET_NAME" -n "$$APP_NS" -o jsonpath='{.data.MINIO_ENDPOINT}' 2>/dev/null | base64 -d); \
	if [ -z "$$MINIO_ENDPOINT" ]; then MINIO_ENDPOINT="http://$(RELEASE).$(NAMESPACE).svc.cluster.local:9000"; fi; \
	ROOT_USER=$$(kubectl get secret -n $(NAMESPACE) $(RELEASE) -o jsonpath='{.data.root-user}' 2>/dev/null | base64 -d); \
	ROOT_PASSWORD=$$(kubectl get secret -n $(NAMESPACE) $(RELEASE) -o jsonpath='{.data.root-password}' 2>/dev/null | base64 -d); \
	if [ -z "$$ROOT_USER" ] || [ -z "$$ROOT_PASSWORD" ]; then \
		echo "✗ Не удалось получить root creds из секрета $(RELEASE) в namespace $(NAMESPACE)"; exit 1; \
	fi; \
	if [ "$(SKIP_CONFIRM)" != "1" ]; then \
		echo "⚠ ВНИМАНИЕ: Будут удалены IAM-пользователь \"$$ACCESS_KEY_VAL\", политика \"$$POLICY_NAME\", Secret \"$$APP_NS/$$APP_SECRET_NAME\" и tracking Secret \"$(NAMESPACE)/minio-app-$(APP)\"."; \
		read -p "Вы уверены? (y/N): " confirm; \
		if [ "$$confirm" != "y" ] && [ "$$confirm" != "Y" ]; then echo "Отменено."; exit 0; fi; \
	fi; \
	DO_RB=0; \
	BUCKETS_CSV=""; \
	if [ "$(MINIO_REMOVE_BUCKETS)" = "1" ]; then \
		if [ "$(SKIP_CONFIRM)" != "1" ]; then \
			echo "⚠ Дополнительно: будут удалены bucket из tracking Secret (mc rb --force), объекты будут потеряны."; \
			read -p "Удалить bucket с данными? (y/N): " confirm2; \
			if [ "$$confirm2" = "y" ] || [ "$$confirm2" = "Y" ]; then DO_RB=1; fi; \
		else DO_RB=1; \
		fi; \
		if [ $$DO_RB -eq 1 ]; then \
			TRACK=$$(kubectl get secret -n $(NAMESPACE) "minio-app-$(APP)" -o jsonpath='{.data.buckets\\.json}' 2>/dev/null | base64 -d); \
			if command -v jq >/dev/null 2>&1; then \
				BUCKETS_CSV=$$(echo "$$TRACK" | jq -r '[.[].bucket] | unique | join(",")' 2>/dev/null || true); \
			else \
				echo "✗ jq не найден: для MINIO_REMOVE_BUCKETS=1 установите jq или удалите bucket вручную"; exit 1; \
			fi; \
		fi; \
	fi; \
	echo "Removing MinIO user/policy..."; \
	kubectl run minio-drop-$$(date +%s) \
		--restart='Never' \
		--image=$(MINIO_CLIENT_IMAGE_LOCAL) \
		--namespace=$(NAMESPACE) \
		--rm -i \
		--env="ROOT_USER=$$ROOT_USER" \
		--env="ROOT_PASSWORD=$$ROOT_PASSWORD" \
		--env="MINIO_ENDPOINT=$$MINIO_ENDPOINT" \
		--env="ACCESS_KEY=$$ACCESS_KEY_VAL" \
		--env="POLICY_NAME=$$POLICY_NAME" \
		--env="BUCKETS_CSV=$$BUCKETS_CSV" \
		--env="DO_RB=$$DO_RB" \
		--command -- sh -ec "\
			mc alias set minio \"\$$MINIO_ENDPOINT\" \"\$$ROOT_USER\" \"\$$ROOT_PASSWORD\";\n\
			mc admin policy detach minio \"\$$POLICY_NAME\" --user \"\$$ACCESS_KEY\" 2>/dev/null || true;\n\
			mc admin user remove minio \"\$$ACCESS_KEY\" 2>/dev/null || true;\n\
			mc admin policy remove minio \"\$$POLICY_NAME\" 2>/dev/null || true;\n\
			if [ \"\$$DO_RB\" = \"1\" ] && [ -n \"\$$BUCKETS_CSV\" ]; then\n\
			  echo \"\$$BUCKETS_CSV\" | tr ',' '\\n' | while read -r b; do\n\
			    [ -z \"\$$b\" ] && continue;\n\
			    mc rb --force \"minio/\$$b\" 2>/dev/null || true;\n\
			  done;\n\
			fi;\n\
		"; \
	echo "Deleting Secrets..."; \
	kubectl delete secret "$$APP_SECRET_NAME" -n "$$APP_NS" --ignore-not-found; \
	kubectl delete secret "minio-app-$(APP)" -n "$(NAMESPACE)" --ignore-not-found; \
	"$(INFRA_ROOT)/scripts/app-conf-clear.sh" "$(INFRA_ROOT)" "$(APP)" minio || true; \
	if [ $$DO_RB -eq 1 ]; then echo "✓ Учётка MinIO для $(APP) удалена; bucket из tracking Secret удалены (mc rb --force)"; else echo "✓ Учётка MinIO для $(APP) удалена; bucket не удалялись"; fi

images-verify:
	@echo "Проверка доступности тегов в docker.io/bitnamilegacy..."
	@command -v docker >/dev/null 2>&1 || { echo "✗ docker не установлен"; exit 1; }
	@FAIL=0; \
	for img in docker.io/bitnamilegacy/minio:$(MINIO_TAG) docker.io/bitnamilegacy/minio-client:$(MINIO_CLIENT_TAG) docker.io/bitnamilegacy/minio-object-browser:$(MINIO_OBJECT_BROWSER_TAG) docker.io/bitnamilegacy/os-shell:$(OS_SHELL_TAG); do \
		echo "  - $$img"; \
		if docker manifest inspect "$$img" >/dev/null 2>&1; then \
			echo "    ✓ OK"; \
		else \
			echo "    ✗ NOT FOUND"; \
			FAIL=1; \
		fi; \
	done; \
	if [ $$FAIL -ne 0 ]; then \
		echo ""; \
		echo "✗ Некоторые теги в bitnamilegacy недоступны."; \
		exit 1; \
	fi; \
	echo "✓ Все теги доступны в bitnamilegacy"

check-updates: ## Проверить наличие новых версий чарта и образов
	@echo "Проверка обновлений для MinIO..."
	@echo ""
	@CURRENT_CHART=$$(grep '^version:' $(CHART_PATH)/Chart.yaml | awk '{print $$2}'); \
	CURRENT_APP=$$(grep '^appVersion:' $(CHART_PATH)/Chart.yaml | awk '{print $$2}'); \
	echo "Текущая версия чарта: $$CURRENT_CHART (appVersion: $$CURRENT_APP)"; \
	echo "Текущие теги образов: minio:$(MINIO_TAG), minio-client:$(MINIO_CLIENT_TAG), minio-object-browser:$(MINIO_OBJECT_BROWSER_TAG), os-shell:$(OS_SHELL_TAG)"; \
	echo ""; \
	echo "Проверка доступных версий чарта..."; \
	if command -v helm >/dev/null 2>&1; then \
		if ! helm repo list 2>/dev/null | grep -q bitnami; then \
			echo "  Добавляю репозиторий bitnami..."; \
			helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true; \
			helm repo update >/dev/null 2>&1 || true; \
		fi; \
		echo "  Поиск последней версии чарта..."; \
		LATEST_CHART=$$(helm search repo bitnami/minio --versions --output json 2>/dev/null | jq -r '.[0].version' 2>/dev/null || helm search repo bitnami/minio --versions 2>/dev/null | head -2 | tail -1 | awk '{print $$2}' || echo ""); \
		if [ -n "$$LATEST_CHART" ] && [ "$$LATEST_CHART" != "$$CURRENT_CHART" ]; then \
			echo "  ⚠ Доступна новая версия чарта: $$LATEST_CHART"; \
			echo "  Для проверки образов новой версии выполните:"; \
			echo "    helm show chart bitnami/minio --version $$LATEST_CHART | grep -A 10 '^annotations:'"; \
		elif [ -n "$$LATEST_CHART" ]; then \
			echo "  ✓ Используется последняя версия чарта: $$CURRENT_CHART"; \
		else \
			echo "  ⚠ Не удалось получить версию чарта"; \
		fi; \
	else \
		echo "  ⚠ helm не установлен, проверка версий чарта пропущена"; \
		echo "  Альтернатива: проверьте https://github.com/bitnami/charts/tree/main/bitnami/minio"; \
	fi; \
	echo ""; \
	echo "Примечание: После обновления чарта проверьте теги образов в Chart.yaml новой версии"

check-registry:
	@echo "Проверка MicroK8s registry..."
	@curl -fsS http://$(REGISTRY)/v2/ >/dev/null 2>&1 && \
		echo "✓ Registry доступен: http://$(REGISTRY)/v2/" || \
		(echo "✗ Registry недоступен. Убедитесь, что выполнен: microk8s enable registry" && exit 1)

install:
	@kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	@helm upgrade --install $(RELEASE) ./$(CHART_PATH) --namespace $(NAMESPACE) -f $(VALUES_FILE)

upgrade:
	@helm upgrade --install $(RELEASE) ./$(CHART_PATH) --namespace $(NAMESPACE) --create-namespace -f $(VALUES_FILE)

uninstall:
	@echo "⚠ ВНИМАНИЕ: Это удалит Helm release $(RELEASE)!"
	@read -p "Вы уверены? (y/N): " confirm && \
		if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
			helm uninstall $(RELEASE) --namespace $(NAMESPACE) || echo "Helm release не найден"; \
		else \
			echo "Отменено."; \
			exit 0; \
		fi

status:
	@helm status $(RELEASE) --namespace $(NAMESPACE) 2>/dev/null || echo "Helm release не найден"
	@kubectl get pods,svc,pvc -n $(NAMESPACE) -o wide 2>/dev/null || true

logs:
	@POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/name=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then \
		echo "Поды MinIO не найдены"; \
	else \
		echo "Логи пода: $$POD"; \
		kubectl logs -f $$POD -n $(NAMESPACE); \
	fi

shell:
	@POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/name=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then \
		echo "Поды MinIO не найдены"; \
		exit 1; \
	else \
		echo "Подключение к поду: $$POD"; \
		kubectl exec -it $$POD -n $(NAMESPACE) -- bash || kubectl exec -it $$POD -n $(NAMESPACE) -- sh; \
	fi

images-pull:
	@echo "Загрузка образов из docker.io/bitnamilegacy..."
	@docker pull $(MINIO_IMAGE_SRC)
	@docker pull $(MINIO_CLIENT_IMAGE_SRC)
	@docker pull $(MINIO_OBJECT_BROWSER_IMAGE_SRC)
	@docker pull $(OS_SHELL_IMAGE_SRC)
	@echo "✓ Все образы загружены"

images-tag: images-pull
	@docker tag $(MINIO_IMAGE_SRC) $(MINIO_IMAGE_LOCAL)
	@docker tag $(MINIO_CLIENT_IMAGE_SRC) $(MINIO_CLIENT_IMAGE_LOCAL)
	@docker tag $(MINIO_OBJECT_BROWSER_IMAGE_SRC) $(MINIO_OBJECT_BROWSER_IMAGE_LOCAL)
	@docker tag $(OS_SHELL_IMAGE_SRC) $(OS_SHELL_IMAGE_LOCAL)

images-push: check-registry images-tag
	@docker push $(MINIO_IMAGE_LOCAL)
	@docker push $(MINIO_CLIENT_IMAGE_LOCAL)
	@docker push $(MINIO_OBJECT_BROWSER_IMAGE_LOCAL)
	@docker push $(OS_SHELL_IMAGE_LOCAL)

images-sync: images-push

images-save: images-pull
	@mkdir -p $(IMAGES_DIR)
	@docker save $(MINIO_IMAGE_SRC) -o $(IMAGES_DIR)/minio-$(MINIO_TAG).tar
	@docker save $(MINIO_CLIENT_IMAGE_SRC) -o $(IMAGES_DIR)/minio-client-$(MINIO_CLIENT_TAG).tar
	@docker save $(MINIO_OBJECT_BROWSER_IMAGE_SRC) -o $(IMAGES_DIR)/minio-object-browser-$(MINIO_OBJECT_BROWSER_TAG).tar
	@docker save $(OS_SHELL_IMAGE_SRC) -o $(IMAGES_DIR)/os-shell-$(OS_SHELL_TAG).tar

images-load:
	@if [ ! -d "$(IMAGES_DIR)" ]; then echo "✗ Директория $(IMAGES_DIR) не найдена"; exit 1; fi
	@for file in $(IMAGES_DIR)/*.tar; do \
		if [ -f "$$file" ]; then docker load -i $$file; fi; \
	done

images-sync-from-files: check-registry images-load
	@$(MAKE) images-tag
	@$(MAKE) images-push

images-clean:
	-@docker rmi $(IMAGES_LOCAL) 2>/dev/null || true
	-@docker rmi $(IMAGES_SRC) 2>/dev/null || true

images-clean-files:
	@if [ -d "$(IMAGES_DIR)" ]; then rm -f $(IMAGES_DIR)/*.tar 2>/dev/null || true; fi

## =========================
## Backup / Restore (meta: IAM users + policies + buckets + tracking secrets)
## =========================
BACKUP_DIR ?= backups

# Запускает helper-pod на minio-client image, собирает users/policies/buckets через mc admin,
# на хосте дополнительно собирает tracking secrets minio-app-<APP> из namespace $(NAMESPACE).
# Объекты бакетов (содержимое) НЕ бэкапятся: используйте mc mirror отдельно.
# Secret-keys IAM-пользователей не экспортируются (хранятся только в Secret <APP>-minio в namespace приложения).
backup-meta:
	@mkdir -p $(BACKUP_DIR)
	@TS=$$(date +%Y%m%d-%H%M%S); \
	OUT="$(BACKUP_DIR)/minio-meta-$$TS.tar.gz"; \
	echo "Создание meta-бэкапа MinIO в $$OUT..."; \
	ROOT_USER=$$(kubectl get secret --namespace $(NAMESPACE) $(RELEASE) -o jsonpath='{.data.root-user}' 2>/dev/null | base64 -d); \
	ROOT_PASSWORD=$$(kubectl get secret --namespace $(NAMESPACE) $(RELEASE) -o jsonpath='{.data.root-password}' 2>/dev/null | base64 -d); \
	if [ -z "$$ROOT_USER" ] || [ -z "$$ROOT_PASSWORD" ]; then echo "✗ Не удалось получить root creds из секрета $(RELEASE) в namespace $(NAMESPACE)"; exit 1; fi; \
	MINIO_HOST="$(RELEASE).$(NAMESPACE).svc.cluster.local"; \
	MINIO_ENDPOINT="http://$$MINIO_HOST:9000"; \
	HELPER=minio-meta-$$TS; \
	echo "  Старт helper-pod $$HELPER..."; \
	kubectl run "$$HELPER" --restart=Never --image=$(MINIO_CLIENT_IMAGE_LOCAL) --namespace=$(NAMESPACE) \
		--overrides='{"spec":{"containers":[{"name":"'$$HELPER'","image":"$(MINIO_CLIENT_IMAGE_LOCAL)","command":["sleep","600"]}]}}' \
		>/dev/null; \
	trap 'kubectl delete pod "$$HELPER" -n $(NAMESPACE) --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT INT TERM; \
	kubectl wait --namespace $(NAMESPACE) --for=condition=Ready pod/"$$HELPER" --timeout=120s >/dev/null; \
	echo "  Сбор IAM users + policies + buckets..."; \
	kubectl exec "$$HELPER" -n $(NAMESPACE) --env="ROOT_USER=$$ROOT_USER" --env="ROOT_PASSWORD=$$ROOT_PASSWORD" --env="MINIO_ENDPOINT=$$MINIO_ENDPOINT" -- sh -ec ' \
		mkdir -p /tmp/meta/policies /tmp/meta/buckets; cd /tmp/meta; \
		mc alias set minio "$$MINIO_ENDPOINT" "$$ROOT_USER" "$$ROOT_PASSWORD" >/dev/null; \
		mc admin info       --json minio > info.json         2>/dev/null || echo "{}" > info.json; \
		mc admin user list  --json minio > users.json        2>/dev/null || echo "" > users.json; \
		mc admin policy list --json minio > policies.list    2>/dev/null || echo "" > policies.list; \
		# Содержимое каждой policy
		for p in $$(mc admin policy list minio 2>/dev/null | awk "NR>1 {print \$$1}"); do \
			[ -z "$$p" ] && continue; \
			mc admin policy info --json minio "$$p" > "policies/$$p.json" 2>/dev/null || true; \
		done; \
		mc ls --json minio > buckets.json 2>/dev/null || echo "" > buckets.json; \
		# Per-bucket: versioning + ilm + anonymous policy
		for b in $$(mc ls minio 2>/dev/null | awk "{print \$$NF}" | sed "s|/$$||"); do \
			[ -z "$$b" ] && continue; \
			mc version info     --json "minio/$$b" > "buckets/$$b-versioning.json" 2>/dev/null || true; \
			mc ilm rule export        "minio/$$b" > "buckets/$$b-ilm.json"        2>/dev/null || true; \
			mc anonymous get-json     "minio/$$b" > "buckets/$$b-anonymous.json"  2>/dev/null || true; \
		done; \
		tar -czf /tmp/minio-meta-mc.tar.gz -C /tmp/meta .; \
	'; \
	TMP=$$(mktemp -d); trap 'rm -rf "$$TMP"; kubectl delete pod "$$HELPER" -n $(NAMESPACE) --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT INT TERM; \
	kubectl cp "$(NAMESPACE)/$$HELPER:/tmp/minio-meta-mc.tar.gz" "$$TMP/mc.tar.gz" >/dev/null; \
	echo "  Сбор tracking secrets minio-app-*..."; \
	mkdir -p "$$TMP/tracking-secrets"; \
	for s in $$(kubectl get secret -n $(NAMESPACE) -o name 2>/dev/null | grep '^secret/minio-app-' || true); do \
		NAME=$$(basename "$$s"); \
		kubectl get secret -n $(NAMESPACE) "$$NAME" -o yaml \
			| awk '/^  resourceVersion:/{next} /^  uid:/{next} /^  creationTimestamp:/{next} {print}' \
			> "$$TMP/tracking-secrets/$$NAME.yaml"; \
	done; \
	# Распаковываем mc.tar.gz в TMP, добавляем tracking-secrets, переупаковываем единым архивом.
	mkdir -p "$$TMP/meta"; \
	tar -xzf "$$TMP/mc.tar.gz" -C "$$TMP/meta"; \
	if [ -d "$$TMP/tracking-secrets" ]; then mv "$$TMP/tracking-secrets" "$$TMP/meta/tracking-secrets"; fi; \
	tar -czf "$$OUT" -C "$$TMP/meta" .; \
	SIZE=$$(ls -lh "$$OUT" | awk '{print $$5}'); \
	echo "✓ Meta-бэкап создан: $$OUT ($$SIZE)"

list-backups:
	@echo "Список meta-бэкапов MinIO в $(BACKUP_DIR):"
	@if [ -d "$(BACKUP_DIR)" ]; then \
		ls -lht "$(BACKUP_DIR)"/minio-meta-*.tar.gz 2>/dev/null | awk '{print $$9, "(" $$5, $$6, $$7, $$8 ")"}' || echo "  Бэкапы не найдены"; \
	else \
		echo "  Директория $(BACKUP_DIR) не существует"; \
	fi

# Восстанавливает policies (mc admin policy create) и tracking secrets minio-app-* (kubectl apply).
# IAM-users НЕ восстанавливаются автоматически (secret_key не экспортируем — он только в Secret приложения).
# Полная процедура воссоздания учёток приложений — через `make apps-apply ENV=... ENABLED_SERVICES=minio`.
restore-meta:
	@if [ -z "$(BACKUP_FILE)" ]; then \
		echo "✗ Укажите файл: make restore-meta BACKUP_FILE=$(BACKUP_DIR)/minio-meta-YYYYMMDD-HHMMSS.tar.gz"; \
		exit 1; \
	fi
	@if [ ! -f "$(BACKUP_FILE)" ]; then echo "✗ Файл $(BACKUP_FILE) не найден"; exit 1; fi
	@if [ "$(SKIP_CONFIRM)" != "1" ]; then \
		echo "⚠ Будут восстановлены policies и tracking secrets minio-app-* из $(BACKUP_FILE)."; \
		echo "  IAM users НЕ восстанавливаются: запустите make apps-apply для полного восстановления учёток приложений."; \
		read -p "Продолжить? (y/N): " confirm; \
		if [ "$$confirm" != "y" ] && [ "$$confirm" != "Y" ]; then echo "Отменено."; exit 0; fi; \
	fi
	@TS=$$(date +%Y%m%d-%H%M%S); \
	TMP=$$(mktemp -d); trap 'rm -rf "$$TMP"' EXIT INT TERM; \
	tar -xzf "$(BACKUP_FILE)" -C "$$TMP"; \
	# 1) Восстанавливаем policies
	if [ -d "$$TMP/policies" ]; then \
		ROOT_USER=$$(kubectl get secret --namespace $(NAMESPACE) $(RELEASE) -o jsonpath='{.data.root-user}' 2>/dev/null | base64 -d); \
		ROOT_PASSWORD=$$(kubectl get secret --namespace $(NAMESPACE) $(RELEASE) -o jsonpath='{.data.root-password}' 2>/dev/null | base64 -d); \
		if [ -z "$$ROOT_USER" ] || [ -z "$$ROOT_PASSWORD" ]; then echo "✗ Нет root creds для применения policies"; exit 1; fi; \
		MINIO_ENDPOINT="http://$(RELEASE).$(NAMESPACE).svc.cluster.local:9000"; \
		HELPER=minio-restore-$$TS; \
		kubectl run "$$HELPER" --restart=Never --image=$(MINIO_CLIENT_IMAGE_LOCAL) --namespace=$(NAMESPACE) \
			--overrides='{"spec":{"containers":[{"name":"'$$HELPER'","image":"$(MINIO_CLIENT_IMAGE_LOCAL)","command":["sleep","300"]}]}}' \
			>/dev/null; \
		trap 'kubectl delete pod "$$HELPER" -n $(NAMESPACE) --ignore-not-found --wait=false >/dev/null 2>&1 || true; rm -rf "$$TMP"' EXIT INT TERM; \
		kubectl wait --namespace $(NAMESPACE) --for=condition=Ready pod/"$$HELPER" --timeout=120s >/dev/null; \
		kubectl exec "$$HELPER" -n $(NAMESPACE) --env="ROOT_USER=$$ROOT_USER" --env="ROOT_PASSWORD=$$ROOT_PASSWORD" --env="MINIO_ENDPOINT=$$MINIO_ENDPOINT" -- sh -ec ' \
			mc alias set minio "$$MINIO_ENDPOINT" "$$ROOT_USER" "$$ROOT_PASSWORD" >/dev/null; \
		'; \
		APPLIED=0; SKIPPED=0; \
		for f in "$$TMP/policies"/*.json; do \
			[ -f "$$f" ] || continue; \
			NAME=$$(basename "$$f" .json); \
			# консольные/системные policies (consoleAdmin, readonly, readwrite, writeonly, diagnostics) пропустим
			case "$$NAME" in consoleAdmin|readonly|readwrite|writeonly|diagnostics) SKIPPED=$$((SKIPPED+1)); continue ;; esac; \
			kubectl cp "$$f" "$(NAMESPACE)/$$HELPER:/tmp/$$NAME.json" >/dev/null; \
			if kubectl exec "$$HELPER" -n $(NAMESPACE) -- mc admin policy create minio "$$NAME" "/tmp/$$NAME.json" >/dev/null 2>&1; then \
				APPLIED=$$((APPLIED+1)); \
			else \
				echo "  ⚠ Не удалось применить policy $$NAME"; \
			fi; \
		done; \
		echo "  Policies: применено $$APPLIED, пропущено системных $$SKIPPED"; \
		kubectl delete pod "$$HELPER" -n $(NAMESPACE) --ignore-not-found --wait=false >/dev/null 2>&1 || true; \
	fi; \
	# 2) Восстанавливаем tracking secrets minio-app-*
	APPLIED_TS=0; \
	if [ -d "$$TMP/tracking-secrets" ]; then \
		for f in "$$TMP/tracking-secrets"/*.yaml; do \
			[ -f "$$f" ] || continue; \
			if kubectl apply -n $(NAMESPACE) -f "$$f" >/dev/null; then \
				APPLIED_TS=$$((APPLIED_TS+1)); \
			else \
				echo "  ⚠ Не удалось применить $$(basename "$$f")"; \
			fi; \
		done; \
		echo "  Tracking secrets: применено $$APPLIED_TS"; \
	fi; \
	echo "✓ Restore-meta завершён. Для воссоздания IAM-users + S3-кредов приложений: make apps-apply ENV=$(ENV) ENABLED_SERVICES=minio"


