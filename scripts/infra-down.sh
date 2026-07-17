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

STATE_FILE="$INFRA_DIR/terraform.tfstate.d/$DEPLOY_WORKSPACE/terraform.tfstate"

# outputs "<total>|db:cur/ini  sg:cur/ini  ..." reading INIT_FILE for initial counts
_group_stats() {
  local init_file="${1:-}"
  python3 - "$STATE_FILE" "$init_file" <<'PYEOF'
import json, sys
state_path = sys.argv[1]
init_path  = sys.argv[2] if len(sys.argv) > 2 else ''
GROUPS = [
  ('db',    ['aws_db_instance','aws_db_subnet_group']),
  ('sg',    ['aws_security_group']),
  ('ecs',   ['aws_ecs_cluster','aws_ecs_service','aws_ecs_task_definition']),
  ('cf',    ['aws_cloudfront_distribution']),
  ('ecr',   ['aws_ecr_repository','aws_ecr_lifecycle_policy']),
  ('alb',   ['aws_lb','aws_lb_listener','aws_lb_target_group']),
  ('vpc',   ['aws_vpc','aws_subnet','aws_internet_gateway','aws_route_table','aws_route_table_association']),
  ('iam',   ['aws_iam_role','aws_iam_role_policy','aws_iam_role_policy_attachment']),
  ('cb',    ['aws_codebuild_project']),
  ('s3',    ['aws_s3_bucket','aws_s3_bucket_lifecycle_configuration']),
  ('sched', ['aws_scheduler_schedule']),
  ('logs',  ['aws_cloudwatch_log_group']),
]
try:
  d = json.load(open(state_path))
except Exception:
  print('0|'); sys.exit()
counts = {}
total  = 0
for r in d.get('resources', []):
  n = len(r.get('instances', []))
  if n: counts[r['type']] = counts.get(r['type'], 0) + n; total += n
init = {}
if init_path:
  try:
    for line in open(init_path):
      if ':' in line: k, v = line.strip().split(':', 1); init[k] = int(v)
  except Exception: pass
parts = []
for label, types in GROUPS:
  cur = sum(counts.get(t, 0) for t in types)
  ini = init.get(label, cur)
  if ini > 0: parts.append(f'{label}:{cur}/{ini}')
print(f'{total}|' + '  '.join(parts))
PYEOF
}

# snapshot initial group counts to a temp file
INIT_FILE="$(mktemp /tmp/tf-init-XXXXXX)"
_RAW=$(_group_stats "")
_BEFORE="${_RAW%%|*}"
python3 - "$STATE_FILE" "$INIT_FILE" <<'PYEOF'
import json, sys
state_path, out_path = sys.argv[1], sys.argv[2]
GROUPS = [
  ('db',    ['aws_db_instance','aws_db_subnet_group']),
  ('sg',    ['aws_security_group']),
  ('ecs',   ['aws_ecs_cluster','aws_ecs_service','aws_ecs_task_definition']),
  ('cf',    ['aws_cloudfront_distribution']),
  ('ecr',   ['aws_ecr_repository','aws_ecr_lifecycle_policy']),
  ('alb',   ['aws_lb','aws_lb_listener','aws_lb_target_group']),
  ('vpc',   ['aws_vpc','aws_subnet','aws_internet_gateway','aws_route_table','aws_route_table_association']),
  ('iam',   ['aws_iam_role','aws_iam_role_policy','aws_iam_role_policy_attachment']),
  ('cb',    ['aws_codebuild_project']),
  ('s3',    ['aws_s3_bucket','aws_s3_bucket_lifecycle_configuration']),
  ('sched', ['aws_scheduler_schedule']),
  ('logs',  ['aws_cloudwatch_log_group']),
]
try: d = json.load(open(state_path))
except: d = {}
counts = {}
for r in d.get('resources', []):
  n = len(r.get('instances', []))
  if n: counts[r['type']] = counts.get(r['type'], 0) + n
with open(out_path, 'w') as f:
  for label, types in GROUPS:
    c = sum(counts.get(t, 0) for t in types)
    if c > 0: f.write(f'{label}:{c}\n')
PYEOF

if [[ "$_BEFORE" == "0" ]]; then
  green 'Workspace is already empty — nothing to destroy.'
  rm -f "$INIT_FILE"
  exit 0
fi

printf '\n  Resources currently in state: %s\n' "$_BEFORE"
printf '  This will destroy: ECS, ALB, RDS, CloudFront, VPC, ECR, CodeBuild, S3\n'
printf '\n  Proceed? [Y/n]: '
read -r _CONFIRM
[[ "${_CONFIRM:-y}" =~ ^[Yy]$ ]] || { red 'Aborted.'; rm -f "$INIT_FILE"; exit 1; }

# flush ECR repos so Terraform can delete them
bold '\nFlushing ECR images...'
for _repo in "${TF_VAR_name_prefix}-backend" "${TF_VAR_name_prefix}-frontend"; do
  _ids=$(aws ecr list-images --repository-name "$_repo" \
    --query 'imageIds[*]' --output json --no-cli-pager 2>/dev/null || echo '[]')
  if [[ "$_ids" != "[]" && "$_ids" != "" ]]; then
    aws ecr batch-delete-image --repository-name "$_repo" \
      --image-ids "$_ids" --no-cli-pager >/dev/null 2>&1 \
      && green "  $_repo — images deleted" || dim "  $_repo — delete skipped"
  else
    dim "  $_repo — already empty"
  fi
done

# run destroy in background, poll progress
bold '\nRunning terraform destroy...'
LOG_FILE="$(mktemp /tmp/tf-destroy-XXXXXX)"
terraform destroy -auto-approve -var "name_prefix=${TF_VAR_name_prefix}" \
  >"$LOG_FILE" 2>&1 &
TF_PID=$!

_spinner_frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
_si=0
_elapsed=0
_last_destroyed=()

_print_progress() {
  local elapsed="$1" frame="$2"
  local raw groups total
  raw=$(_group_stats "$INIT_FILE")
  total="${raw%%|*}"
  groups="${raw#*|}"
  # print any newly completed resource lines from the log
  local completed line
  completed=$(grep -E ': Destruction complete' "$LOG_FILE" 2>/dev/null \
    | grep -oE '^[^:]+' | sed 's/^[[:space:]]*//' | sort -u || true)
  if [[ -n "$completed" ]]; then
    while IFS= read -r line; do
      if [[ -n "$line" ]] && ! printf '%s\n' "${_last_destroyed[@]:-}" | grep -qxF "$line"; then
        _last_destroyed+=("$line")
        printf '\r\033[K  \033[32m✓\033[0m %s\n' "$line"
      fi
    done <<< "$completed"
  fi
  printf '\r\033[K  %s  [%3ds]  %s/%s remaining  —  %s' \
    "$frame" "$elapsed" "$total" "$_BEFORE" "$groups"
}

while kill -0 "$TF_PID" 2>/dev/null; do
  _frame="${_spinner_frames[$(( _si % ${#_spinner_frames[@]} ))]}"
  _print_progress "$_elapsed" "$_frame"
  _si=$(( _si + 1 ))
  _elapsed=$(( _elapsed + 3 ))
  sleep 3
done

# capture exit code
wait "$TF_PID" && _TF_EXIT=0 || _TF_EXIT=$?
printf '\n'
rm -f "$INIT_FILE"

if [[ "$_TF_EXIT" -ne 0 ]]; then
  red 'terraform destroy failed. Last 30 lines of output:'
  tail -30 "$LOG_FILE"
  red "\nFull log: $LOG_FILE"
  exit 1
fi

_AFTER_RAW=$(_group_stats "")
_AFTER="${_AFTER_RAW%%|*}"
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
