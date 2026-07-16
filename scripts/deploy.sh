#!/usr/bin/env bash
# deploy.sh — rag-pgvector-demo: local dev, GCP Cloud Run, or AWS ECS
# Usage: ./scripts/deploy.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env.gcp"
BACKEND_SVC="rag-backend"
FRONTEND_SVC="rag-frontend"
DB_INSTANCE="rag-pgvector-db"
DB_NAME="ragdb"
DB_USER="postgres"
DB_SECRET="rag-db-password"
AR_REPO="rag-demo"
SA_NAME="rag-runner"

_aws_tf_ws_count() {
  local ws="$1"
  local state_file="$ROOT/infra/aws/terraform.tfstate.d/$ws/terraform.tfstate"
  [[ -f "$state_file" ]] || { printf '0'; return; }
  python3 -c "import json; d=json.load(open('$state_file')); print(sum(len(r.get('instances',[])) for r in d.get('resources',[])))" 2>/dev/null || printf '0'
}
_aws_lite_count=$(_aws_tf_ws_count lite)

printf '\n=== rag-pgvector-demo ===\n\n'
printf '  [1] Local  — uvicorn + npm dev, no Docker (Postgres via .env)'
printf '\n'
printf '  [2] Lite   — AWS: ECS Fargate + RDS db.t3.micro  (~$40-60/mo if left running)'
(( _aws_lite_count > 0 )) && printf ' [%s resources active]' "$_aws_lite_count" || printf ' [not deployed]'
printf '\n'
printf '  [3] Cloud  — GCP Cloud Run + Cloud SQL'
printf '\n\nChoice [1/2/3]: '
read -r _MODE
case "$_MODE" in
  2) TARGET="aws"; DEPLOY_WORKSPACE="lite"; TF_VAR_name_prefix="rag-lite"
     TF_VAR_be_task_cpu=512;  TF_VAR_be_task_memory=1024
     TF_VAR_fe_task_cpu=256;  TF_VAR_fe_task_memory=512
     TF_VAR_db_instance_class="db.t3.micro"
     export DEPLOY_WORKSPACE TF_VAR_name_prefix TF_VAR_be_task_cpu TF_VAR_be_task_memory
     export TF_VAR_fe_task_cpu TF_VAR_fe_task_memory TF_VAR_db_instance_class
     ;;
  3) TARGET="cloud" ;;
  *) TARGET="local" ;;
esac

# ── local mode (no Docker) ────────────────────────────────────────────────────
# Postgres + Redis run remotely (deployed Cloud SQL / Redis) or locally via brew.
# No Docker Compose needed — set DATABASE_URL and REDIS_URL in .env.
#
# Remote (already deployed):  DATABASE_URL=<Cloud SQL proxy URL>  REDIS_URL=<remote>
# Local (brew):               brew install postgresql redis
#                             brew services start postgresql redis
#                             DATABASE_URL=postgresql://postgres:@localhost:5432/ragdb
#                             REDIS_URL=redis://localhost:6379
if [[ "$TARGET" == "local" ]]; then
  [[ -f "$ROOT/.env" ]] || { echo "Error: .env not found. Copy .env.example and fill in API keys and DATABASE_URL."; exit 1; }
  # shellcheck source=/dev/null
  source "$ROOT/.env"
  if [[ -z "${DATABASE_URL:-}" ]]; then
    printf '\nDATABASE_URL not set in .env.\n'
    printf '  Remote: use your deployed Cloud SQL connection URL.\n'
    printf '  Local:  brew install postgresql@16 && brew services start postgresql@16\n'
    printf '          DATABASE_URL=postgresql://postgres:@localhost:5432/ragdb\n\n'
    exit 1
  fi

  cd "$ROOT/backend"
  [[ -d .venv ]] || python3 -m venv .venv
  # shellcheck source=/dev/null
  source .venv/bin/activate
  pip install -q -r requirements.txt
  cp "$ROOT/.env" "$ROOT/backend/.env" 2>/dev/null || true
  uvicorn app.main:app --host 0.0.0.0 --port 8001 --reload &
  BACKEND_PID=$!
  echo "Backend  → http://localhost:8001/docs"

  read -rp 'Seed Wikipedia articles into the local DB? [y/N]: ' _SEED
  if [[ "${_SEED:-n}" =~ ^[Yy] ]]; then
    sleep 3
    echo "Seeding Wikipedia articles..."
    python3 "$ROOT/scripts/seed.py"
  fi

  cd "$ROOT/frontend"
  [[ -d node_modules ]] || npm install
  grep -E '^(OPENAI|ANTHROPIC|NVIDIA|BACKEND)' "$ROOT/.env" > "$ROOT/frontend/.env.local" 2>/dev/null || true
  echo "BACKEND_URL=http://localhost:8001" >> "$ROOT/frontend/.env.local"
  npm run dev &
  FRONTEND_PID=$!
  echo "Frontend → http://localhost:3010"

  _cleanup() { kill "$BACKEND_PID" "$FRONTEND_PID" 2>/dev/null || true; }
  trap _cleanup EXIT INT TERM
  wait "$BACKEND_PID" "$FRONTEND_PID"
  exit 0
fi

# ── GCP Cloud Run ─────────────────────────────────────────────────────────────
if [[ "$TARGET" == "cloud" ]]; then
if ! command -v gcloud >/dev/null 2>&1; then
  printf '\ngcloud CLI not found.\n'
  if command -v brew >/dev/null 2>&1; then
    printf 'Installing via Homebrew...\n'
    brew install --cask google-cloud-sdk
    source "$(brew --prefix)/share/google-cloud-sdk/path.bash.inc" 2>/dev/null || true
  else
    printf 'Install from: https://cloud.google.com/sdk/docs/install\n'
    exit 1
  fi
fi

ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 || true)
if [[ -z "$ACTIVE_ACCOUNT" ]]; then
  printf '\nNot authenticated — logging in...\n'
  gcloud auth login
  ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 || true)
  [[ -n "$ACTIVE_ACCOUNT" ]] || { printf 'Login did not complete.\n' >&2; exit 1; }
fi
printf '\nAuthenticated as: %s\n' "$ACTIVE_ACCOUNT"

# ── project / region ──────────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
_CONFIG_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
GCP_PROJECT="${_CONFIG_PROJECT:-${GCP_PROJECT:-}}"
[[ -n "$GCP_PROJECT" ]] || { printf 'Set GCP_PROJECT or: gcloud config set project <id>\n' >&2; exit 1; }
_CONFIG_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
GCP_REGION="${_CONFIG_REGION:-${GCP_REGION:-us-central1}}"
printf '\n=== deployment config ===\n  Project: %s\n  Region:  %s\n' "$GCP_PROJECT" "$GCP_REGION"

_GIT_HASH=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || true)
TAG="${_GIT_HASH:+${_GIT_HASH}-}$(date +%Y%m%d%H%M%S)"

# ── enable APIs ───────────────────────────────────────────────────────────────
printf '\nEnabling APIs...\n'
gcloud services enable \
  artifactregistry.googleapis.com \
  run.googleapis.com \
  sqladmin.googleapis.com \
  cloudbuild.googleapis.com \
  secretmanager.googleapis.com \
  --project "$GCP_PROJECT" --quiet

# ── Artifact Registry ─────────────────────────────────────────────────────────
if ! gcloud artifacts repositories describe "$AR_REPO" \
     --project="$GCP_PROJECT" --location="$GCP_REGION" &>/dev/null; then
  printf '\nCreating Artifact Registry repo %s...\n' "$AR_REPO"
  gcloud artifacts repositories create "$AR_REPO" \
    --repository-format=docker \
    --location="$GCP_REGION" \
    --project="$GCP_PROJECT"
fi
AR_HOST="${GCP_REGION}-docker.pkg.dev"
BACKEND_IMAGE="${AR_HOST}/${GCP_PROJECT}/${AR_REPO}/${BACKEND_SVC}:${TAG}"
FRONTEND_IMAGE="${AR_HOST}/${GCP_PROJECT}/${AR_REPO}/${FRONTEND_SVC}:${TAG}"

# ── service account ───────────────────────────────────────────────────────────
SA_EMAIL="${SA_NAME}@${GCP_PROJECT}.iam.gserviceaccount.com"
if ! gcloud iam service-accounts describe "$SA_EMAIL" --project="$GCP_PROJECT" &>/dev/null; then
  printf '\nCreating service account %s...\n' "$SA_EMAIL"
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="RAG Demo Cloud Run SA" \
    --project="$GCP_PROJECT"
fi
for ROLE in roles/cloudsql.client roles/secretmanager.secretAccessor; do
  gcloud projects add-iam-policy-binding "$GCP_PROJECT" \
    --member="serviceAccount:${SA_EMAIL}" --role="$ROLE" --quiet 2>/dev/null || true
done

# ── Cloud SQL PG16 ────────────────────────────────────────────────────────────
if ! gcloud sql instances describe "$DB_INSTANCE" --project="$GCP_PROJECT" &>/dev/null; then
  printf '\nCreating Cloud SQL PG16 instance %s (~5 min)...\n' "$DB_INSTANCE"
  DB_PASS=$(openssl rand -base64 24 | tr -d '=+/')
  # Store password in Secret Manager
  echo -n "$DB_PASS" | gcloud secrets create "$DB_SECRET" \
    --data-file=- --project="$GCP_PROJECT" 2>/dev/null || \
  echo -n "$DB_PASS" | gcloud secrets versions add "$DB_SECRET" \
    --data-file=- --project="$GCP_PROJECT"
  gcloud secrets add-iam-policy-binding "$DB_SECRET" \
    --project="$GCP_PROJECT" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/secretmanager.secretAccessor" --quiet 2>/dev/null || true

  gcloud sql instances create "$DB_INSTANCE" \
    --database-version=POSTGRES_16 \
    --edition=ENTERPRISE \
    --tier=db-custom-1-3840 \
    --region="$GCP_REGION" \
    --project="$GCP_PROJECT" \
    --no-backup
  gcloud sql databases create "$DB_NAME" \
    --instance="$DB_INSTANCE" --project="$GCP_PROJECT"
  gcloud sql users set-password "$DB_USER" \
    --instance="$DB_INSTANCE" --password="$DB_PASS" --project="$GCP_PROJECT"
else
  printf '\nCloud SQL instance %s already exists.\n' "$DB_INSTANCE"
  DB_PASS=$(gcloud secrets versions access latest \
    --secret="$DB_SECRET" --project="$GCP_PROJECT" 2>/dev/null || echo "")
  if [[ -z "$DB_PASS" ]]; then
    read -r -s -p "DB password for ${DB_USER}@${DB_INSTANCE}: " DB_PASS; echo
  fi
fi

CLOUD_SQL_CONN="${GCP_PROJECT}:${GCP_REGION}:${DB_INSTANCE}"
SOCKET_HOST="/cloudsql/${CLOUD_SQL_CONN}"
DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@/${DB_NAME}?host=${SOCKET_HOST}"
PGVECTOR_CONN="postgresql+psycopg://${DB_USER}:${DB_PASS}@/${DB_NAME}?host=${SOCKET_HOST}"

# ── API key secrets ───────────────────────────────────────────────────────────
function upsert_secret() {
  local NAME="$1" VALUE="$2"
  [[ -z "$VALUE" ]] && return
  if gcloud secrets describe "$NAME" --project="$GCP_PROJECT" &>/dev/null; then
    echo -n "$VALUE" | gcloud secrets versions add "$NAME" --data-file=- --project="$GCP_PROJECT"
  else
    echo -n "$VALUE" | gcloud secrets create "$NAME" --data-file=- --project="$GCP_PROJECT"
    gcloud secrets add-iam-policy-binding "$NAME" --project="$GCP_PROJECT" \
      --member="serviceAccount:${SA_EMAIL}" --role="roles/secretmanager.secretAccessor" --quiet 2>/dev/null || true
  fi
}
[[ -f "$ROOT/.env" ]] && source "$ROOT/.env"
upsert_secret rag-openai-key     "${OPENAI_API_KEY:-}"
upsert_secret rag-anthropic-key  "${ANTHROPIC_API_KEY:-}"
upsert_secret rag-nvidia-key     "${NVIDIA_API_KEY:-}"

OPENAI_KEY=$(gcloud secrets versions access latest --secret=rag-openai-key --project="$GCP_PROJECT" 2>/dev/null || echo "")
ANTHROPIC_KEY=$(gcloud secrets versions access latest --secret=rag-anthropic-key --project="$GCP_PROJECT" 2>/dev/null || echo "")
NVIDIA_KEY=$(gcloud secrets versions access latest --secret=rag-nvidia-key --project="$GCP_PROJECT" 2>/dev/null || echo "")

# ── build images via Cloud Build (no local Docker required) ───────────────────
printf '\n[1/2] building backend via Cloud Build...\n'
gcloud builds submit \
  --tag "$BACKEND_IMAGE" \
  --project "$GCP_PROJECT" \
  "$ROOT/backend"

printf '\n[2/2] building frontend via Cloud Build...\n'
gcloud builds submit \
  --tag "$FRONTEND_IMAGE" \
  --project "$GCP_PROJECT" \
  "$ROOT/frontend"

# ── deploy backend ────────────────────────────────────────────────────────────
printf '\nDeploying %s to Cloud Run...\n' "$BACKEND_SVC"
gcloud run deploy "$BACKEND_SVC" \
  --image="$BACKEND_IMAGE" \
  --region="$GCP_REGION" \
  --project="$GCP_PROJECT" \
  --service-account="$SA_EMAIL" \
  --add-cloudsql-instances="$CLOUD_SQL_CONN" \
  --set-env-vars="DATABASE_URL=${DATABASE_URL},PGVECTOR_CONNECTION=${PGVECTOR_CONN},OPENAI_API_KEY=${OPENAI_KEY},ANTHROPIC_API_KEY=${ANTHROPIC_KEY},NVIDIA_API_KEY=${NVIDIA_KEY}" \
  --no-allow-unauthenticated \
  --min-instances=0 \
  --quiet
gcloud run services add-iam-policy-binding "$BACKEND_SVC" \
  --region="$GCP_REGION" --project="$GCP_PROJECT" \
  --member="user:${ACTIVE_ACCOUNT}" --role="roles/run.invoker" --quiet

BACKEND_URL=$(gcloud run services describe "$BACKEND_SVC" \
  --region="$GCP_REGION" --project="$GCP_PROJECT" \
  --format="value(status.url)")
printf '  Backend: %s\n' "$BACKEND_URL"

# ── deploy frontend ───────────────────────────────────────────────────────────
printf '\nDeploying %s to Cloud Run...\n' "$FRONTEND_SVC"
gcloud run deploy "$FRONTEND_SVC" \
  --image="$FRONTEND_IMAGE" \
  --region="$GCP_REGION" \
  --project="$GCP_PROJECT" \
  --service-account="$SA_EMAIL" \
  --set-env-vars="BACKEND_URL=${BACKEND_URL},OPENAI_API_KEY=${OPENAI_KEY},ANTHROPIC_API_KEY=${ANTHROPIC_KEY},NVIDIA_API_KEY=${NVIDIA_KEY}" \
  --no-allow-unauthenticated \
  --min-instances=0 \
  --quiet
gcloud run services add-iam-policy-binding "$FRONTEND_SVC" \
  --region="$GCP_REGION" --project="$GCP_PROJECT" \
  --member="user:${ACTIVE_ACCOUNT}" --role="roles/run.invoker" --quiet

FRONTEND_URL=$(gcloud run services describe "$FRONTEND_SVC" \
  --region="$GCP_REGION" --project="$GCP_PROJECT" \
  --format="value(status.url)")

# ── persist cloud config ──────────────────────────────────────────────────────
cat > "$ENV_FILE" <<ENVEOF
GCP_PROJECT=${GCP_PROJECT}
GCP_REGION=${GCP_REGION}
AR_REPO=${AR_REPO}
DB_INSTANCE=${DB_INSTANCE}
CLOUD_SQL_CONN=${CLOUD_SQL_CONN}
BACKEND_URL=${BACKEND_URL}
FRONTEND_URL=${FRONTEND_URL}
ENVEOF

printf '\n=== RAG + pgvector Demo deployed ===\n'
printf '  App:  %s\n' "$FRONTEND_URL"
printf '  API:  %s/docs\n' "$BACKEND_URL"
printf '\nOptional seed against live backend:\n'
printf '  BACKEND_URL=%s python scripts/seed.py\n' "$BACKEND_URL"
printf '\nTear down: ./scripts/infra-down.sh --cloud\n'
exit 0
fi

# ── AWS ECS ───────────────────────────────────────────────────────────────────
printf '\n--- AWS Lite summary ---\n'
printf '  Backend:  ECS Fargate 0.5 vCPU / 1 GB\n'
printf '  Frontend: ECS Fargate 0.25 vCPU / 0.5 GB\n'
printf '  DB:       RDS PostgreSQL 16 db.t3.micro (20 GB)\n'
printf '  Cost est: ~$40-60/mo if left running — TEAR DOWN when done\n'
printf '\nProceed? [Y/n] '
read -r _CONFIRM
[[ -z "$_CONFIRM" || "$_CONFIRM" =~ ^[Yy]$ ]] || { printf 'Aborted.\n'; exit 0; }

echo ""
echo "[1/4] Checking AWS credentials..."
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  printf '  AWS credentials not configured.\n'
  printf '  Running: aws configure\n\n'
  aws configure
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    printf '\n  Credentials still invalid — aborting.\n'; exit 1
  fi
fi
printf '  Credentials valid: %s\n' "$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)"

AWS_REGION=$(cd "$ROOT/infra/aws" && terraform output -raw aws_region 2>/dev/null || echo "us-east-1")

_update_ecs_schedules() {
  local _state="$1"
  for _sched in "${TF_VAR_name_prefix}-start-be" "${TF_VAR_name_prefix}-stop-be" \
                "${TF_VAR_name_prefix}-start-fe" "${TF_VAR_name_prefix}-stop-fe"; do
    if ! _cur=$(aws scheduler get-schedule --name "$_sched" --output json 2>/dev/null); then
      printf '  (schedule %s not found — run a full deploy first)\n' "$_sched"; continue
    fi
    _expr=$(printf '%s' "$_cur" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['ScheduleExpression'])" 2>/dev/null || true)
    _tz=$(printf '%s' "$_cur" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('ScheduleExpressionTimezone','America/Los_Angeles'))" 2>/dev/null || echo "America/Los_Angeles")
    _tgt=$(printf '%s' "$_cur" | python3 -c "import sys,json;d=json.load(sys.stdin);print(json.dumps(d['Target']))" 2>/dev/null || true)
    if aws scheduler update-schedule --name "$_sched" --state "$_state" \
        --schedule-expression "$_expr" --schedule-expression-timezone "$_tz" \
        --flexible-time-window '{"Mode":"OFF"}' --target "$_tgt" \
        --no-cli-pager >/dev/null 2>&1; then
      printf '  %-50s → %s\n' "$_sched" "$_state"
    else
      printf '  ERROR: failed to update %s\n' "$_sched"
    fi
  done
}

_CLUSTER="${TF_VAR_name_prefix}-cluster"
_BE_SVC="${TF_VAR_name_prefix}-backend"
_FE_SVC="${TF_VAR_name_prefix}-frontend"
_BE_STATE=$(aws ecs describe-services --cluster "$_CLUSTER" --services "$_BE_SVC" \
  --query "services[0].status" --output text 2>/dev/null || echo "NOT_DEPLOYED")
_FE_STATE=$(aws ecs describe-services --cluster "$_CLUSTER" --services "$_FE_SVC" \
  --query "services[0].status" --output text 2>/dev/null || echo "NOT_DEPLOYED")
_BE_DESIRED=$(aws ecs describe-services --cluster "$_CLUSTER" --services "$_BE_SVC" \
  --query "services[0].desiredCount" --output text 2>/dev/null || echo "0")
_FE_DESIRED=$(aws ecs describe-services --cluster "$_CLUSTER" --services "$_FE_SVC" \
  --query "services[0].desiredCount" --output text 2>/dev/null || echo "0")
_SCHED_STATE=$(aws scheduler get-schedule --name "${TF_VAR_name_prefix}-start-be" \
  --query "State" --output text 2>/dev/null || echo "NOT_CREATED")

printf '\n  Backend: %-12s desired=%s  Frontend: %-12s desired=%s\n' \
  "$_BE_STATE" "$_BE_DESIRED" "$_FE_STATE" "$_FE_DESIRED"
printf '  Auto-schedule: 8 am start · 5 pm stop · weekdays PT · state=%s\n' "$_SCHED_STATE"
printf '  [1] Start now  [2] Stop now  [3] Suspend schedule  [4] Resume schedule  [enter] Full deploy: '
read -r _PRE
case "${_PRE:-}" in
  1)
    if [[ "$_BE_STATE" == "NOT_DEPLOYED" || "$_FE_STATE" == "NOT_DEPLOYED" ]]; then
      printf '  Infra not found — falling through to full deploy.\n'
    else
      aws ecs update-service --cluster "$_CLUSTER" --service "$_BE_SVC" --desired-count 1 --no-cli-pager >/dev/null
      aws ecs update-service --cluster "$_CLUSTER" --service "$_FE_SVC" --desired-count 1 --no-cli-pager >/dev/null
      printf '  Services starting — tasks will be ready in ~1-2 min.\n'; exit 0
    fi ;;
  2)
    if [[ "$_BE_STATE" == "NOT_DEPLOYED" && "$_FE_STATE" == "NOT_DEPLOYED" ]]; then
      printf '  Nothing to stop — infra not deployed.\n'; exit 0
    fi
    aws ecs update-service --cluster "$_CLUSTER" --service "$_BE_SVC" --desired-count 0 --no-cli-pager >/dev/null 2>&1 || true
    aws ecs update-service --cluster "$_CLUSTER" --service "$_FE_SVC" --desired-count 0 --no-cli-pager >/dev/null 2>&1 || true
    printf '  Services stopped — no Fargate charges while at 0. ALB still billed.\n'; exit 0 ;;
  3)
    [[ "$_SCHED_STATE" == "NOT_CREATED" ]] && { printf '  No schedules found — run a full deploy first.\n'; exit 0; }
    aws ecs update-service --cluster "$_CLUSTER" --service "$_BE_SVC" --desired-count 0 --no-cli-pager >/dev/null 2>&1 || true
    aws ecs update-service --cluster "$_CLUSTER" --service "$_FE_SVC" --desired-count 0 --no-cli-pager >/dev/null 2>&1 || true
    _update_ecs_schedules "DISABLED"; printf '  Schedule suspended.\n'; exit 0 ;;
  4)
    [[ "$_SCHED_STATE" == "NOT_CREATED" ]] && { printf '  No schedules found — run a full deploy first.\n'; exit 0; }
    _update_ecs_schedules "ENABLED"; printf '  Schedule resumed.\n'; exit 0 ;;
esac

echo ""
echo "[2/4] Provisioning AWS infra (ECS cluster, ALB, RDS, ECR, EventBridge)..."
"$ROOT/scripts/infra-up-aws.sh"

INFRA_DIR="$ROOT/infra/aws"
cd "$INFRA_DIR"
terraform workspace select "$DEPLOY_WORKSPACE" >/dev/null

_TF_OUT=$(terraform output -json)
_tf() { printf '%s' "$_TF_OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['$1']['value'])"; }
FRONTEND_URL=$(_tf frontend_url)
BACKEND_URL=$(_tf backend_url)
BE_ECR_URI=$(_tf backend_ecr_uri)
FE_ECR_URI=$(_tf frontend_ecr_uri)
CLUSTER_NAME=$(_tf cluster_name)
BE_SVC=$(_tf backend_service)
FE_SVC=$(_tf frontend_service)
DATABASE_URL=$(_tf database_url)
AWS_REGION=$(_tf aws_region)

echo ""
echo "[3/4] Building and pushing images via AWS CodeBuild (remote)..."
TAG=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)

BUILD_BUCKET=$(_tf build_bucket)
CB_BE_PROJECT=$(_tf codebuild_backend_project)
CB_FE_PROJECT=$(_tf codebuild_frontend_project)

_ecr_image_exists() {
  local _repo="$1" _tag="$2"
  aws ecr describe-images --repository-name "$_repo" --image-ids "imageTag=$_tag" \
    --region "$AWS_REGION" >/dev/null 2>&1
}

_codebuild_wait() {
  local _build_id="$1" _label="$2" _elapsed=0
  printf '  %s build started: %s\n' "$_label" "$_build_id"
  while true; do
    _status=$(aws codebuild batch-get-builds --ids "$_build_id" \
      --query "builds[0].buildStatus" --output text 2>/dev/null)
    case "$_status" in
      SUCCEEDED) printf '  %s build succeeded (%ds).\n' "$_label" "$_elapsed"; return 0 ;;
      FAILED|FAULT|TIMED_OUT|STOPPED)
        printf '  %s build %s (%ds) — check CodeBuild console.\n' "$_label" "$_status" "$_elapsed"; return 1 ;;
      *) sleep 15; _elapsed=$(( _elapsed + 15 ))
         printf '  %s still building... %ds\n' "$_label" "$_elapsed" ;;
    esac
  done
}

_codebuild_run() {
  local _label="$1" _repo="$2" _project="$3" _zip_src="$4" _zip_key="$5"
  shift 5
  if _ecr_image_exists "$_repo" "$TAG"; then
    printf '  %s image %s already in ECR — skipping build.\n' "$_label" "$TAG"
    return 0
  fi
  printf '  Uploading %s source to S3...\n' "$_label"
  (cd "$_zip_src" && zip -qr "/tmp/rag-${_label}-source.zip" .)
  aws s3 cp "/tmp/rag-${_label}-source.zip" "s3://${BUILD_BUCKET}/${_zip_key}" --no-cli-pager >/dev/null
  printf '  Building %s (%s:%s)...\n' "$_label" "$_repo" "$TAG"
  local _build_id
  _build_id=$(aws codebuild start-build \
    --project-name "$_project" \
    --environment-variables-override "name=IMAGE_TAG,value=${TAG},type=PLAINTEXT" "$@" \
    --query "build.id" --output text --no-cli-pager)
  _codebuild_wait "$_build_id" "$_label"
}

_codebuild_run "backend" "${TF_VAR_name_prefix}-backend" "$CB_BE_PROJECT" \
  "$ROOT/backend" "backend-source.zip"

_codebuild_run "frontend" "${TF_VAR_name_prefix}-frontend" "$CB_FE_PROJECT" \
  "$ROOT/frontend" "frontend-source.zip" \
  "name=BUILD_ARGS,value=--build-arg NEXT_PUBLIC_BACKEND_URL=${BACKEND_URL},type=PLAINTEXT"

echo ""
echo "[4/4] Updating SSM parameters and deploying to ECS..."

# Source .env for API keys only — but preserve DATABASE_URL already set from Terraform
[[ -f "$ROOT/.env" ]] && source "$ROOT/.env" || true
DATABASE_URL=$(_tf database_url)   # re-read from Terraform to undo any .env override
PGVECTOR_CONNECTION="${DATABASE_URL/postgresql:\/\//postgresql+psycopg://}"
BACKEND_URL=$(_tf backend_url)     # re-read to undo any .env override

_prompt_key() {
  local _label="$1" _cur="${2:-}" _req="${3:-optional}"
  local _ans _val
  if [[ -n "$_cur" ]]; then
    printf '  %-24s  %s...%s  update? [Y/n]: ' \
      "$_label" "${_cur:0:8}" "${_cur: -4}" >&2
    read -r _ans
    if [[ -z "$_ans" || "$_ans" =~ ^[Yy]$ ]]; then
      printf '  New value (Enter to keep current): ' >&2
      read -rs _val; printf '\n' >&2
      printf '%s' "${_val:-$_cur}"
    else
      printf '%s' "$_cur"
    fi
  else
    if [[ "$_req" == required ]]; then
      printf '  %-24s  (required): ' "$_label" >&2
    else
      printf '  %-24s  (optional, Enter to skip): ' "$_label" >&2
    fi
    read -rs _val; printf '\n' >&2
    if [[ -z "$_val" && "$_req" == required ]]; then
      printf '  Cannot deploy without %s.\n' "$_label" >&2; exit 1
    fi
    printf '%s' "$_val"
  fi
}

printf '\n--- API keys ---\n'
OPENAI_API_KEY=$(_prompt_key    "OPENAI_API_KEY"    "${OPENAI_API_KEY:-}"    required)
ANTHROPIC_API_KEY=$(_prompt_key "ANTHROPIC_API_KEY" "${ANTHROPIC_API_KEY:-}" optional)
NVIDIA_API_KEY=$(_prompt_key    "NVIDIA_API_KEY"    "${NVIDIA_API_KEY:-}"    optional)

for _pair in "openai-key:${OPENAI_API_KEY:-}" "anthropic-key:${ANTHROPIC_API_KEY:-}" "nvidia-key:${NVIDIA_API_KEY:-}"; do
  _pname="/${TF_VAR_name_prefix}/${_pair%%:*}"
  _pval="${_pair#*:}"
  [[ -z "$_pval" ]] && continue
  aws ssm put-parameter --name "$_pname" --value "$_pval" \
    --type SecureString --overwrite --no-cli-pager >/dev/null
  printf '  Updated SSM: %s\n' "$_pname"
done

OPENAI_API_KEY=$(aws ssm get-parameter --name "/${TF_VAR_name_prefix}/openai-key" --with-decryption --query Parameter.Value --output text 2>/dev/null || echo "")
ANTHROPIC_API_KEY=$(aws ssm get-parameter --name "/${TF_VAR_name_prefix}/anthropic-key" --with-decryption --query Parameter.Value --output text 2>/dev/null || echo "")
NVIDIA_API_KEY=$(aws ssm get-parameter --name "/${TF_VAR_name_prefix}/nvidia-key" --with-decryption --query Parameter.Value --output text 2>/dev/null || echo "")

_register_task_def() {
  local family="$1" image="$2" port="$3" extra_env="$4"
  local log_group="/ecs/${TF_VAR_name_prefix}"
  local cur_def
  cur_def=$(aws ecs describe-task-definition --task-definition "$family" --output json 2>/dev/null \
    | python3 -c "import json,sys; td=json.load(sys.stdin)['taskDefinition']; \
      [td.pop(k,None) for k in ['taskDefinitionArn','revision','status','requiresAttributes','compatibilities','registeredAt','registeredBy','deregisteredAt']]; \
      print(json.dumps(td))" 2>/dev/null || echo "")
  if [[ -z "$cur_def" ]]; then
    printf '  Task definition %s not found — infra-up-aws.sh must run first.\n' "$family"; return 1
  fi
  local new_def _tmp
  _tmp=$(mktemp)
  printf '%s' "$cur_def" > "$_tmp"
  new_def=$(python3 - "$image" "$port" "$extra_env" "$_tmp" <<'PYEOF'
import json, sys
image, port_str, extra_env_json, def_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(def_file) as f:
    td = json.load(f)
extra_env = json.loads(extra_env_json) if extra_env_json else []
app_containers = [c for c in td['containerDefinitions'] if c['name'] == 'app']
if app_containers:
    app_containers[0]['image'] = image
    env = app_containers[0].get('environment', [])
    env_map = {e['name']: e for e in env}
    for e in extra_env:
        env_map[e['name']] = e   # upsert — update existing values, not just append new ones
    app_containers[0]['environment'] = list(env_map.values())
print(json.dumps(td))
PYEOF
)
  rm -f "$_tmp"
  local new_arn
  new_arn=$(aws ecs register-task-definition --cli-input-json "$new_def" \
    --query "taskDefinition.taskDefinitionArn" --output text --no-cli-pager)
  printf '  Registered: %s\n' "$new_arn" >&2
  printf '%s' "$new_arn"
}

BE_EXTRA_ENV=$(python3 -c "import json; print(json.dumps([e for e in [
  {'name':'DATABASE_URL','value':'${DATABASE_URL}'},
  {'name':'PGVECTOR_CONNECTION','value':'${PGVECTOR_CONNECTION}'},
{'name':'OPENAI_API_KEY','value':'${OPENAI_API_KEY}'},
  {'name':'ANTHROPIC_API_KEY','value':'${ANTHROPIC_API_KEY}'},
  {'name':'NVIDIA_API_KEY','value':'${NVIDIA_API_KEY}'},
] if e['value']]))")
BE_TASK_ARN=$(_register_task_def "${TF_VAR_name_prefix}-backend" "${BE_ECR_URI}:${TAG}" "8001" "$BE_EXTRA_ENV")

FE_EXTRA_ENV=$(python3 -c "import json; print(json.dumps([e for e in [
  {'name':'BACKEND_URL','value':'${BACKEND_URL}'},
  {'name':'OPENAI_API_KEY','value':'${OPENAI_API_KEY}'},
  {'name':'ANTHROPIC_API_KEY','value':'${ANTHROPIC_API_KEY}'},
  {'name':'NVIDIA_API_KEY','value':'${NVIDIA_API_KEY}'},
] if e['value']]))")
FE_TASK_ARN=$(_register_task_def "${TF_VAR_name_prefix}-frontend" "${FE_ECR_URI}:${TAG}" "3010" "$FE_EXTRA_ENV")

aws ecs update-service --cluster "$CLUSTER_NAME" --service "$BE_SVC" \
  --task-definition "$BE_TASK_ARN" --desired-count 1 --force-new-deployment --no-cli-pager >/dev/null
aws ecs update-service --cluster "$CLUSTER_NAME" --service "$FE_SVC" \
  --task-definition "$FE_TASK_ARN" --desired-count 1 --force-new-deployment --no-cli-pager >/dev/null

printf '\n  Waiting for services to stabilize (this takes 2-4 min)...\n'
_ecs_wait_stable() {
  local _cluster="$1" _region="$2"
  shift 2
  local _svcs=("$@")
  local _elapsed=0 _all_stable=false

  while (( _elapsed < 480 )); do
    _all_stable=true
    local _line=""
    for _svc in "${_svcs[@]}"; do
      local _out
      _out=$(aws ecs describe-services \
        --cluster "$_cluster" --services "$_svc" --region "$_region" \
        --query "services[0].{desired:desiredCount,running:runningCount,pending:pendingCount,deployments:length(deployments)}" \
        --output json 2>/dev/null)
      local _desired _running _pending _deps
      _desired=$(printf '%s' "$_out" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['desired'])" 2>/dev/null || echo "?")
      _running=$(printf '%s' "$_out" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['running'])" 2>/dev/null || echo "?")
      _pending=$(printf '%s' "$_out" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['pending'])" 2>/dev/null || echo "?")
      _deps=$(printf '%s' "$_out"    | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['deployments'])" 2>/dev/null || echo "?")

      # also grab the most recent stopped task reason if running < desired
      local _reason=""
      if [[ "$_running" != "$_desired" || "$_deps" != "1" ]]; then
        _all_stable=false
        _reason=$(aws ecs list-tasks \
          --cluster "$_cluster" --service-name "$_svc" \
          --desired-status STOPPED --region "$_region" \
          --query "taskArns[0]" --output text 2>/dev/null)
        if [[ -n "$_reason" && "$_reason" != "None" ]]; then
          _reason=$(aws ecs describe-tasks \
            --cluster "$_cluster" --tasks "$_reason" --region "$_region" \
            --query "tasks[0].containers[0].reason" --output text 2>/dev/null || echo "")
          [[ -n "$_reason" && "$_reason" != "None" ]] && _reason=" ← $_reason"
        else
          _reason=""
        fi
      fi

      _short="${_svc##*-}"
      _line+="  ${_short}: running=${_running}/${_desired} pending=${_pending} deployments=${_deps}${_reason}\n"
    done

    printf "  [%ds]\n%b" "$_elapsed" "$_line"

    "$_all_stable" && { printf '  All services stable.\n'; return 0; }
    sleep 5
    _elapsed=$(( _elapsed + 5 ))
  done

  printf '  Timed out after %ds — check ECS console.\n' "$_elapsed"
  return 1
}
_ecs_wait_stable "$CLUSTER_NAME" "$AWS_REGION" "$BE_SVC" "$FE_SVC"

printf '\n✓ RAG + pgvector Demo live on AWS\n'
printf '  App:         %s\n' "$FRONTEND_URL"
printf '  API Docs:    %s/docs\n' "$BACKEND_URL"
printf '  Schedule:    8 am \xc2\xb7 5 pm PT weekdays (ECS desiredCount 1/0)\n'
printf '  Tear down:   ./scripts/infra-down.sh --aws\n'

PORTFOLIO_SET_LIVE="$(cd "$ROOT/../../portfolio/scripts" 2>/dev/null && pwd || true)/set-live-url.sh"
if [[ -f "$PORTFOLIO_SET_LIVE" ]]; then
  printf '\n  Updating portfolio live-urls.js...\n'
  bash "$PORTFOLIO_SET_LIVE" --tier "lite" rag "$FRONTEND_URL" "${BACKEND_URL}/docs"
fi
