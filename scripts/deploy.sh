#!/usr/bin/env bash
# deploy.sh — rag-pgvector-demo: local dev, AWS Lambda+Neon+Vercel, or GCP Cloud Run
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
printf '  [1] Local   — uvicorn + npm dev, no Docker (Postgres via .env)'
printf '\n'
printf '  [2] Serverless — AWS Lambda + Neon + Vercel  (~$0/mo)'
(( _aws_lite_count > 0 )) && printf ' [%s resources active]' "$_aws_lite_count" || printf ' [not deployed]'
printf '\n'
printf '  [3] Cloud   — GCP Cloud Run + Cloud SQL'
printf '\n\nChoice [1/2/3]: '
read -r _MODE
case "$_MODE" in
  2) TARGET="aws"; DEPLOY_WORKSPACE="lite"; TF_VAR_name_prefix="rag-lite"
     export DEPLOY_WORKSPACE TF_VAR_name_prefix
     ;;
  3) TARGET="cloud" ;;
  *) TARGET="local" ;;
esac

# ── local mode ────────────────────────────────────────────────────────────────
if [[ "$TARGET" == "local" ]]; then
  [[ -f "$ROOT/.env" ]] || { echo "Error: .env not found. Copy .env.example and fill in API keys and DATABASE_URL."; exit 1; }
  source "$ROOT/.env"
  if [[ -z "${DATABASE_URL:-}" ]]; then
    printf '\nDATABASE_URL not set in .env.\n'
    printf '  Neon: paste your Neon connection string (postgresql://...neon.tech/ragdb?sslmode=require)\n'
    printf '  Local brew: brew install postgresql@16 && brew services start postgresql@16\n'
    printf '              DATABASE_URL=postgresql://postgres:@localhost:5432/ragdb\n\n'
    exit 1
  fi

  cd "$ROOT/backend"
  [[ -d .venv ]] || python3 -m venv .venv
  source .venv/bin/activate
  pip install -q -r requirements.txt
  cp "$ROOT/.env" "$ROOT/backend/.env" 2>/dev/null || true
  uvicorn app.main:app --host 0.0.0.0 --port 8001 --reload &
  BACKEND_PID=$!
  echo "Backend  → http://localhost:8001"

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

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
_CONFIG_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
GCP_PROJECT="${_CONFIG_PROJECT:-${GCP_PROJECT:-}}"
[[ -n "$GCP_PROJECT" ]] || { printf 'Set GCP_PROJECT or: gcloud config set project <id>\n' >&2; exit 1; }
_CONFIG_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
GCP_REGION="${_CONFIG_REGION:-${GCP_REGION:-us-central1}}"
printf '\n=== deployment config ===\n  Project: %s\n  Region:  %s\n' "$GCP_PROJECT" "$GCP_REGION"

_GIT_HASH=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || true)
TAG="${_GIT_HASH:+${_GIT_HASH}-}$(date +%Y%m%d%H%M%S)"

printf '\nEnabling APIs...\n'
gcloud services enable \
  artifactregistry.googleapis.com \
  run.googleapis.com \
  sqladmin.googleapis.com \
  cloudbuild.googleapis.com \
  secretmanager.googleapis.com \
  --project "$GCP_PROJECT" --quiet

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

if ! gcloud sql instances describe "$DB_INSTANCE" --project="$GCP_PROJECT" &>/dev/null; then
  printf '\nCreating Cloud SQL PG16 instance %s (~5 min)...\n' "$DB_INSTANCE"
  DB_PASS=$(openssl rand -base64 24 | tr -d '=+/')
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
printf '  API:  %s\n' "$BACKEND_URL"
printf '\nTear down: ./scripts/infra-down.sh --cloud\n'
exit 0
fi

# ── AWS Serverless (Lambda + Neon + Vercel) ───────────────────────────────────
printf '\n--- AWS Serverless ---\n'
printf '  Backend:  Lambda (container image, 1 GB, 15 min timeout)\n'
printf '  Database: Neon serverless Postgres + pgvector  (~$0/mo free tier)\n'
printf '  Frontend: Vercel                               (~$0/mo free tier)\n'
printf '  Cost est: ~$0/mo  (Lambda free tier covers demo traffic)\n'

echo ""
echo "[1/5] Checking AWS credentials..."
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  printf '  AWS credentials not configured.\n'
  aws configure
  aws sts get-caller-identity >/dev/null 2>&1 || { printf '  Credentials still invalid — aborting.\n'; exit 1; }
fi
printf '  Credentials valid: %s\n' "$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)"

AWS_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")

echo ""
echo "[2/5] Provisioning bootstrap infra (ECR, S3, IAM, CodeBuild)..."
INFRA_DIR="$ROOT/infra/aws"
cd "$INFRA_DIR"
terraform init -upgrade -input=false
terraform workspace select "$DEPLOY_WORKSPACE" 2>/dev/null \
  || terraform workspace new "$DEPLOY_WORKSPACE"

_tf() { terraform output -raw "$1" 2>/dev/null; }

# Phase 1 — ECR, S3, IAM, CodeBuild only; Lambda requires the image to exist in ECR first
terraform apply -auto-approve -var "name_prefix=${TF_VAR_name_prefix}" \
  -target=aws_codebuild_project.backend \
  -target=aws_s3_bucket_lifecycle_configuration.build_artifacts

BE_ECR_URI=$(_tf backend_ecr_uri)
AWS_REGION=$(_tf aws_region)
BUILD_BUCKET=$(_tf build_bucket)
CB_BE_PROJECT=$(_tf codebuild_backend_project)

echo ""
echo "[3/5] Neon database setup..."
_OLD_DB_URL=$(aws ssm get-parameter --name "/${TF_VAR_name_prefix}/database-url" --with-decryption --query Parameter.Value --output text 2>/dev/null || echo "")
if [[ -n "$_OLD_DB_URL" ]]; then
  printf '  DATABASE_URL already set in SSM: %s...\n' "${_OLD_DB_URL:0:40}"
  printf '  Update? [y/N]: '
  read -r _UPD_DB
  if [[ "${_UPD_DB:-n}" =~ ^[Yy]$ ]]; then _OLD_DB_URL=""; fi
fi
if [[ -z "$_OLD_DB_URL" ]]; then
  printf '  Paste your Neon DATABASE_URL (postgresql://...neon.tech/...?sslmode=require):\n  > '
  read -r DATABASE_URL
  [[ -z "$DATABASE_URL" ]] && { printf '  DATABASE_URL required — aborting.\n'; exit 1; }
  aws ssm put-parameter --name "/${TF_VAR_name_prefix}/database-url" \
    --value "$DATABASE_URL" --type SecureString --overwrite --no-cli-pager >/dev/null
else
  DATABASE_URL="$_OLD_DB_URL"
fi
PGVECTOR_CONNECTION="${DATABASE_URL/postgresql:\/\//postgresql+psycopg://}"

echo ""
echo "[4/5] API keys..."
_prompt_key() {
  local _label="$1" _cur="${2:-}" _req="${3:-optional}"
  local _ans _val
  if [[ -n "$_cur" ]]; then
    printf '  %-24s  %s...%s  update? [y/N]: ' \
      "$_label" "${_cur:0:8}" "${_cur: -4}" >&2
    read -r _ans
    if [[ "$_ans" =~ ^[Yy]$ ]]; then
      printf '  New value: ' >&2; read -rs _val; printf '\n' >&2
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

_OLD_OPENAI=$(aws ssm get-parameter   --name "/${TF_VAR_name_prefix}/openai-key"    --with-decryption --query Parameter.Value --output text 2>/dev/null || echo "")
_OLD_ANTHROPIC=$(aws ssm get-parameter --name "/${TF_VAR_name_prefix}/anthropic-key" --with-decryption --query Parameter.Value --output text 2>/dev/null || echo "")
_OLD_NVIDIA=$(aws ssm get-parameter   --name "/${TF_VAR_name_prefix}/nvidia-key"    --with-decryption --query Parameter.Value --output text 2>/dev/null || echo "")

OPENAI_API_KEY=$(_prompt_key    "OPENAI_API_KEY"    "$_OLD_OPENAI"    required)
ANTHROPIC_API_KEY=$(_prompt_key "ANTHROPIC_API_KEY" "$_OLD_ANTHROPIC" optional)
NVIDIA_API_KEY=$(_prompt_key    "NVIDIA_API_KEY"    "$_OLD_NVIDIA"    optional)

_ssm_update() {
  local _pname="$1" _new="$2" _old="$3"
  [[ -z "$_new" ]] && return
  [[ "$_new" == "$_old" ]] && return
  aws ssm put-parameter --name "$_pname" --value "$_new" \
    --type SecureString --overwrite --no-cli-pager >/dev/null
  printf '  Updated SSM: %s\n' "$_pname"
}
_ssm_update "/${TF_VAR_name_prefix}/openai-key"    "${OPENAI_API_KEY:-}"    "$_OLD_OPENAI"
_ssm_update "/${TF_VAR_name_prefix}/anthropic-key" "${ANTHROPIC_API_KEY:-}" "$_OLD_ANTHROPIC"
_ssm_update "/${TF_VAR_name_prefix}/nvidia-key"    "${NVIDIA_API_KEY:-}"    "$_OLD_NVIDIA"

TAG=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)

_ecr_image_exists() {
  aws ecr describe-images --repository-name "$1" --image-ids "imageTag=$2" \
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

BE_REPO_NAME="${TF_VAR_name_prefix}-backend"
if _ecr_image_exists "$BE_REPO_NAME" "$TAG"; then
  printf '  Backend image %s already in ECR — skipping build.\n' "$TAG"
  _MANIFEST=$(aws ecr batch-get-image --repository-name "$BE_REPO_NAME" \
    --image-ids "imageTag=${TAG}" --query 'images[0].imageManifest' \
    --output text --no-cli-pager 2>/dev/null)
  aws ecr put-image --repository-name "$BE_REPO_NAME" --image-tag latest \
    --image-manifest "$_MANIFEST" --no-cli-pager >/dev/null 2>&1 \
    && printf '  Re-tagged %s as latest.\n' "$TAG" || true
else
  printf '  Uploading backend source to S3...\n'
  (cd "$ROOT/backend" && zip -qr "/tmp/rag-backend-source.zip" .)
  aws s3 cp "/tmp/rag-backend-source.zip" "s3://${BUILD_BUCKET}/backend-source.zip" --no-cli-pager >/dev/null
  printf '  Building backend (%s:%s)...\n' "$BE_ECR_URI" "$TAG"
  _BUILD_ID=$(aws codebuild start-build \
    --project-name "$CB_BE_PROJECT" \
    --environment-variables-override "name=IMAGE_TAG,value=${TAG},type=PLAINTEXT" \
    --query "build.id" --output text --no-cli-pager)
  _codebuild_wait "$_BUILD_ID" "backend"
fi

echo "  Finalising Lambda and remaining infra..."
cd "$INFRA_DIR"
terraform state rm aws_lambda_function_url.backend >/dev/null 2>&1 || true
terraform state rm aws_lambda_permission.public_url >/dev/null 2>&1 || true
terraform import aws_lambda_permission.apigw \
  "${TF_VAR_name_prefix}-backend/AllowAPIGatewayInvoke" >/dev/null 2>&1 || true
terraform apply -auto-approve -var "name_prefix=${TF_VAR_name_prefix}"
BACKEND_URL=$(_tf backend_url)
LAMBDA_NAME=$(_tf lambda_function_name)

echo ""
echo "[5/5] Updating Lambda config and deploying frontend to Vercel..."

printf '  Waiting for Lambda to be ready...\n'
aws lambda wait function-updated --function-name "$LAMBDA_NAME" --no-cli-pager

_ENV_FILE="$(mktemp /tmp/lambda-env-XXXXXX)"
python3 - "$DATABASE_URL" "$PGVECTOR_CONNECTION" "$OPENAI_API_KEY" \
  "${ANTHROPIC_API_KEY:-}" "${NVIDIA_API_KEY:-}" <<'PYEOF' > "$_ENV_FILE"
import json, sys
keys = ['DATABASE_URL','PGVECTOR_CONNECTION','OPENAI_API_KEY','ANTHROPIC_API_KEY','NVIDIA_API_KEY','CORS_ORIGINS']
vals = list(sys.argv[1:]) + ['*']
env = {k: v for k, v in zip(keys, vals) if v}
print(json.dumps({'Variables': env}))
PYEOF

aws lambda update-function-configuration \
  --function-name "$LAMBDA_NAME" \
  --environment "file://${_ENV_FILE}" \
  --no-cli-pager >/dev/null
rm -f "$_ENV_FILE"
aws lambda wait function-updated --function-name "$LAMBDA_NAME" --no-cli-pager

aws lambda update-function-code \
  --function-name "$LAMBDA_NAME" \
  --image-uri "${BE_ECR_URI}:${TAG}" \
  --no-cli-pager >/dev/null
aws lambda wait function-updated --function-name "$LAMBDA_NAME" --no-cli-pager
printf '  Lambda active.\n'

printf '  Backend: %s\n' "$BACKEND_URL"

if ! command -v vercel >/dev/null 2>&1; then
  printf '\n  Vercel CLI not found — installing...\n'
  npm install -g vercel
fi

cd "$ROOT/frontend"
[[ -d node_modules ]] || npm install

printf '\n  Setting Vercel environment variables...\n'
_vercel_env() {
  local _key="$1" _val="$2"
  [[ -z "$_val" ]] && return
  printf '%s' "$_val" | vercel env add "$_key" production --yes 2>/dev/null || \
  printf '%s' "$_val" | vercel env add "$_key" production --force 2>/dev/null || true
}
_vercel_env "BACKEND_URL"        "$BACKEND_URL"
_vercel_env "OPENAI_API_KEY"     "${OPENAI_API_KEY:-}"
_vercel_env "ANTHROPIC_API_KEY"  "${ANTHROPIC_API_KEY:-}"
_vercel_env "NVIDIA_API_KEY"     "${NVIDIA_API_KEY:-}"

printf '  Deploying frontend to Vercel...\n'
FRONTEND_URL=$(vercel --prod --yes 2>/dev/null | tail -1)

printf '\n✓ RAG + pgvector Demo live (serverless)\n'
printf '  App:      %s\n' "$FRONTEND_URL"
printf '  API:      %s\n' "$BACKEND_URL"
printf '  Cost:     ~$0/mo  (Lambda + Neon + Vercel free tiers)\n'
printf '  Tear down: ./scripts/infra-down.sh --aws\n'

PORTFOLIO_SET_LIVE="$(cd "$ROOT/../../portfolio/scripts" 2>/dev/null && pwd || true)/set-live-url.sh"
if [[ -f "$PORTFOLIO_SET_LIVE" ]]; then
  printf '\n  Updating portfolio live-urls.js...\n'
  bash "$PORTFOLIO_SET_LIVE" --tier "lite" rag "$FRONTEND_URL" "${BACKEND_URL}"
fi
