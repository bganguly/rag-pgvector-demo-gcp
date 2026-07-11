#!/usr/bin/env bash
# deploy.sh — build and deploy rag-pgvector-demo to GCP Cloud Run
# Provisions: Artifact Registry, Cloud SQL PG16 (+pgvector), Cloud Run (backend + frontend)
# No local Docker required — images built via Cloud Build.
# Usage: ./scripts/deploy.sh [local [--seed]]
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
TARGET="${1:-cloud}"

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
  [[ -f "$ROOT/.env" ]] || { echo "Error: .env not found. Copy .env.example and fill in API keys, DATABASE_URL, REDIS_URL."; exit 1; }
  # shellcheck source=/dev/null
  source "$ROOT/.env"
  if [[ -z "${DATABASE_URL:-}" ]] || [[ -z "${REDIS_URL:-}" ]]; then
    printf '\nDATABASE_URL and/or REDIS_URL not set in .env.\n'
    printf '  Remote: use your deployed Cloud SQL connection URL and Redis URL.\n'
    printf '  Local:  brew install postgresql redis && brew services start postgresql redis\n'
    printf '          DATABASE_URL=postgresql://postgres:@localhost:5432/ragdb\n'
    printf '          REDIS_URL=redis://localhost:6379\n\n'
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

  if [[ "${2:-}" == "--seed" ]]; then
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

# ── gcloud ────────────────────────────────────────────────────────────────────
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
printf '\nTear down: ./scripts/infra-down.sh\n'
