#!/usr/bin/env bash
# infra-down.sh — tear down local processes, AWS Lambda stack, or GCP Cloud Run
# Usage: ./scripts/infra-down.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env.gcp"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }

printf '\n=== rag-pgvector-demo — tear down ===\n\n'
printf '  [1] Local   — stop uvicorn + Next.js processes\n'
printf '  [2] AWS     — destroy Lambda, ECR, CodeBuild, S3, VPC (workspace: lite)\n'
printf '  [3] GCP     — delete Cloud Run services + Cloud SQL\n'
printf '\nChoice [1/2/3]: '
read -r _MODE

# ── local ────────────────────────────────────────────────────────────────────
if [[ "$_MODE" == "1" ]]; then
  bold 'Stopping local processes...'
  pkill -f "uvicorn app.main:app" 2>/dev/null && green '  uvicorn stopped' || dim '  uvicorn not running'
  pkill -f "next dev"             2>/dev/null && green '  Next.js stopped' || dim '  Next.js not running'
  green 'Done.'
  exit 0
fi

# ── GCP ──────────────────────────────────────────────────────────────────────
if [[ "$_MODE" == "3" ]]; then
  [[ -f "$ENV_FILE" ]] || { red '.env.gcp not found — nothing to tear down.'; exit 0; }
  source "$ENV_FILE"
  bold "Tearing down GCP resources for project $GCP_PROJECT..."

  gcloud run services delete rag-frontend \
    --region="$GCP_REGION" --project="$GCP_PROJECT" --quiet 2>/dev/null \
    && green '  rag-frontend deleted' || dim '  rag-frontend not found'

  gcloud run services delete rag-backend \
    --region="$GCP_REGION" --project="$GCP_PROJECT" --quiet 2>/dev/null \
    && green '  rag-backend deleted' || dim '  rag-backend not found'

  if [[ -n "${DB_INSTANCE:-}" ]]; then
    bold "Deleting Cloud SQL instance $DB_INSTANCE..."
    gcloud sql instances delete "$DB_INSTANCE" \
      --project="$GCP_PROJECT" --quiet 2>/dev/null \
      && green "  $DB_INSTANCE deleted" || dim '  Cloud SQL instance not found'
  fi

  rm -f "$ENV_FILE"
  green 'GCP infrastructure torn down.'
  exit 0
fi

# ── AWS ──────────────────────────────────────────────────────────────────────
if [[ "$_MODE" != "2" ]]; then
  red 'Invalid choice.'; exit 1
fi

DEPLOY_WORKSPACE="lite"
TF_VAR_name_prefix="rag-lite"
INFRA_DIR="$ROOT/infra/aws"

bold "AWS teardown — workspace: $DEPLOY_WORKSPACE"

# prereq checks
if ! command -v terraform >/dev/null 2>&1; then
  red 'terraform not found in PATH — install from https://developer.hashicorp.com/terraform/install'
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  red 'aws CLI not found in PATH'
  exit 1
fi

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  red 'AWS credentials not configured — run: aws configure'
  exit 1
fi
dim "  Credentials: $(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)"

# terraform init
bold '\nInitialising Terraform...'
cd "$INFRA_DIR"
if ! terraform init -upgrade -input=false; then
  red 'terraform init failed — check provider connectivity and .terraform.lock.hcl'
  exit 1
fi

# workspace
if ! terraform workspace select "$DEPLOY_WORKSPACE" 2>/dev/null; then
  red "Workspace '$DEPLOY_WORKSPACE' not found — nothing to destroy."
  exit 0
fi

# count live resources
_count_resources() {
  local state_file="$INFRA_DIR/terraform.tfstate.d/$DEPLOY_WORKSPACE/terraform.tfstate"
  [[ -f "$state_file" ]] || { printf '0'; return; }
  python3 -c "
import json
with open('$state_file') as f:
  d = json.load(f)
print(sum(len(r.get('instances', [])) for r in d.get('resources', []) if r.get('instances')))
" 2>/dev/null || printf '0'
}

_BEFORE=$(_count_resources)
if [[ "$_BEFORE" == "0" ]]; then
  green 'Workspace is already empty — nothing to destroy.'
  exit 0
fi

printf '\n  Resources currently in state: %s\n' "$_BEFORE"
printf '  This will destroy: ECS, ALB, RDS, CloudFront, VPC, ECR, CodeBuild, S3\n'
printf '\n  Proceed? [Y/n]: '
read -r _CONFIRM
[[ "${_CONFIRM:-y}" =~ ^[Yy]$ ]] || { red 'Aborted.'; exit 1; }

# run destroy in background, poll progress
bold '\nRunning terraform destroy...'
LOG_FILE="$(mktemp /tmp/tf-destroy-XXXX.log)"
terraform destroy -auto-approve -var "name_prefix=${TF_VAR_name_prefix}" \
  >"$LOG_FILE" 2>&1 &
TF_PID=$!

_spinner_frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
_si=0
_elapsed=0
_last_destroyed=()

_print_progress() {
  local cur="$1" elapsed="$2" frame="$3"
  # clear current line then print spinner + counts
  printf '\r\033[K  %s  [%3ds]  %s / %s resources remaining' \
    "$frame" "$elapsed" "$cur" "$_BEFORE"

  # parse newly destroyed resources from log since last check
  local new_destroyed
  new_destroyed=$(grep -oP '(?<=Destroy complete! Resources: )\d+' "$LOG_FILE" 2>/dev/null | tail -1 || true)

  # print any newly completed resource lines from the log
  local completed
  completed=$(grep -E '^\s*(aws_|random_)[^:]+: Destruction complete' "$LOG_FILE" 2>/dev/null \
    | sed 's/.*Destruction complete.*//' \
    | awk '{print $1}' | sort -u || true)
  if [[ -n "$completed" ]]; then
    local line
    while IFS= read -r line; do
      if [[ -n "$line" ]] && ! printf '%s\n' "${_last_destroyed[@]:-}" | grep -qF "$line"; then
        _last_destroyed+=("$line")
        printf '\n  \033[32m✓\033[0m %s' "$line"
      fi
    done <<< "$completed"
    printf '\r\033[K  %s  [%3ds]  %s / %s resources remaining' \
      "$frame" "$elapsed" "$cur" "$_BEFORE"
  fi
}

while kill -0 "$TF_PID" 2>/dev/null; do
  _cur=$(_count_resources)
  _frame="${_spinner_frames[$(( _si % ${#_spinner_frames[@]} ))]}"
  _print_progress "$_cur" "$_elapsed" "$_frame"
  _si=$(( _si + 1 ))
  _elapsed=$(( _elapsed + 3 ))
  sleep 3
done

# capture exit code
wait "$TF_PID" && _TF_EXIT=0 || _TF_EXIT=$?
printf '\n'

if [[ "$_TF_EXIT" -ne 0 ]]; then
  red 'terraform destroy failed. Last 30 lines of output:'
  tail -30 "$LOG_FILE"
  red "\nFull log: $LOG_FILE"
  exit 1
fi

_AFTER=$(_count_resources)
if [[ "$_AFTER" -gt 0 ]]; then
  red "Destroy completed but $_AFTER resources still in state — check AWS console."
  red "Log: $LOG_FILE"
  exit 1
fi
rm -f "$LOG_FILE"
green "  All resources destroyed (was $_BEFORE, now 0)."

# SSM params
bold '\nRemoving SSM parameters...'
for _param in database-url openai-key anthropic-key nvidia-key; do
  aws ssm delete-parameter \
    --name "/${TF_VAR_name_prefix}/${_param}" \
    --no-cli-pager 2>/dev/null \
    && green "  deleted /${TF_VAR_name_prefix}/${_param}" \
    || dim  "  /${TF_VAR_name_prefix}/${_param} not found"
done

# Vercel
if command -v vercel >/dev/null 2>&1; then
  bold '\nRemoving Vercel project...'
  vercel remove rag-pgvector-demo --yes 2>/dev/null \
    && green '  Vercel project removed' \
    || dim  '  Vercel project not found or already removed'
fi

# portfolio update
PORTFOLIO_SET_LIVE="$(cd "$ROOT/../../portfolio/scripts" 2>/dev/null && pwd || true)/set-live-url.sh"
if [[ -f "$PORTFOLIO_SET_LIVE" ]]; then
  bash "$PORTFOLIO_SET_LIVE" --tier "$DEPLOY_WORKSPACE" --down rag
fi

green '\nAWS infrastructure torn down.'
