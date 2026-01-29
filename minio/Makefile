.PHONY: help \
	images-verify images-pull images-tag images-push images-sync images-save images-load images-sync-from-files images-clean images-clean-files \
	install upgrade uninstall status logs shell app-create \
	check-registry check-updates

REGISTRY ?= localhost:32000

NAMESPACE ?= minio
RELEASE ?= minio
CHART_PATH ?= minio
ENV ?= dev
VALUES_FILE ?= values-$(ENV).yaml

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

# Source images (bitnamilegacy -> bitnami fallback)
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
	@APP_NS=$${APP_NS:-$(APP)}; \
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
	ACCESS_KEY=$${ACCESS_KEY:-app_$(APP)}; \
	SECRET_KEY=$${SECRET_KEY:-}; \
	APP_SECRET_NAME=$${APP_SECRET_NAME:-$(APP)-minio}; \
	if [ -z "$$SECRET_KEY" ]; then \
		command -v openssl >/dev/null 2>&1 || { echo "✗ openssl не найден (передайте SECRET_KEY=... или установите openssl)"; exit 1; }; \
		SECRET_KEY=$$(openssl rand -hex 24); \
	fi; \
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
	echo "✓ Done (Secret: $$APP_NS/$$APP_SECRET_NAME)"

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
	@helm upgrade --install $(RELEASE) ./$(CHART_PATH) --namespace $(NAMESPACE) -f $(VALUES_FILE)

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
	@echo "Загрузка образов (bitnamilegacy -> bitnami fallback)..."
	@if docker pull $(MINIO_IMAGE_SRC) 2>/dev/null; then echo "✓ $(MINIO_IMAGE_SRC)"; else docker pull docker.io/bitnami/minio:$(MINIO_SRC_TAG); docker tag docker.io/bitnami/minio:$(MINIO_SRC_TAG) $(MINIO_IMAGE_SRC); fi
	@if docker pull $(MINIO_CLIENT_IMAGE_SRC) 2>/dev/null; then echo "✓ $(MINIO_CLIENT_IMAGE_SRC)"; else docker pull docker.io/bitnami/minio-client:$(MINIO_CLIENT_SRC_TAG); docker tag docker.io/bitnami/minio-client:$(MINIO_CLIENT_SRC_TAG) $(MINIO_CLIENT_IMAGE_SRC); fi
	@if docker pull $(MINIO_OBJECT_BROWSER_IMAGE_SRC) 2>/dev/null; then echo "✓ $(MINIO_OBJECT_BROWSER_IMAGE_SRC)"; else docker pull docker.io/bitnami/minio-object-browser:$(MINIO_OBJECT_BROWSER_SRC_TAG); docker tag docker.io/bitnami/minio-object-browser:$(MINIO_OBJECT_BROWSER_SRC_TAG) $(MINIO_OBJECT_BROWSER_IMAGE_SRC); fi
	@if docker pull $(OS_SHELL_IMAGE_SRC) 2>/dev/null; then echo "✓ $(OS_SHELL_IMAGE_SRC)"; else docker pull docker.io/bitnami/os-shell:$(OS_SHELL_SRC_TAG); docker tag docker.io/bitnami/os-shell:$(OS_SHELL_SRC_TAG) $(OS_SHELL_IMAGE_SRC); fi
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

