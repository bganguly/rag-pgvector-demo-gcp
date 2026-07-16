#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
SEED=false
for arg in "$@"; do [[ "$arg" == "--seed" ]] && SEED=true; done

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

bold "── RAG pgvector · local dev (no Docker) ──"

# 1. Check prerequisites
for cmd in psql python3 node npm; do
  command -v "$cmd" &>/dev/null || { red "Missing: $cmd — install via brew install postgresql@16 python@3.12 node"; exit 1; }
done

PY_VER=$(python3 -c 'import sys; print(sys.version_info[:2] >= (3,12))')
[[ "$PY_VER" == "False" ]] && { red "Python 3.12+ required (found $(python3 --version))"; exit 1; }

# 2. Check services are running
psql postgres -c "" &>/dev/null || { red "PostgreSQL not running — brew services start postgresql@16"; exit 1; }

# 3. pgvector extension available?
HAS_VECTOR=$(psql postgres -tAc "SELECT COUNT(*) FROM pg_available_extensions WHERE name='vector';")
if [[ "$HAS_VECTOR" == "0" ]]; then
  bold "Installing pgvector via brew…"
  brew install pgvector
fi

# 4. .env setup
if [[ ! -f "$ROOT/.env" ]]; then
  cp "$ROOT/.env.example" "$ROOT/.env"
  bold "Created .env from .env.example — fill in API keys before continuing."
  red "Edit $ROOT/.env then re-run this script."
  exit 1
fi

# 5. Fix port: Homebrew postgres=5432 (not the Docker Compose 5433 default)
sed -i '' 's|localhost:5433|localhost:5432|g' "$ROOT/.env"

# 6. Create DB and enable extension
PG_DB="ragdb"
psql postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$PG_DB';" | grep -q 1 \
  || createdb "$PG_DB" && green "Created database $PG_DB"
psql "$PG_DB" -c "CREATE EXTENSION IF NOT EXISTS vector;" &>/dev/null && green "pgvector extension ready"

# 7. Backend venv + install + start
BACKEND="$ROOT/backend"
if [[ ! -d "$BACKEND/.venv" ]]; then
  bold "Creating Python venv…"
  python3 -m venv "$BACKEND/.venv"
fi
source "$BACKEND/.venv/bin/activate"
pip install -q -r "$BACKEND/requirements.txt"

bold "Starting FastAPI on :8001…"
cd "$BACKEND"
uvicorn app.main:app --port 8001 --reload --env-file "$ROOT/.env" &
BACKEND_PID=$!
cd "$ROOT"

# 8. Wait for backend
for i in $(seq 1 20); do
  curl -sf http://localhost:8001/health &>/dev/null && break
  sleep 1
done
curl -sf http://localhost:8001/health &>/dev/null || { red "Backend failed to start"; kill $BACKEND_PID 2>/dev/null; exit 1; }
green "Backend healthy"

# 9. Optional seed
if [[ "$SEED" == "true" ]]; then
  bold "Seeding Wikipedia knowledge base…"
  python3 "$SCRIPT_DIR/seed.py"
  green "Seed complete"
fi

# 10. Frontend install + start
FRONTEND="$ROOT/frontend"
if [[ ! -d "$FRONTEND/node_modules" ]]; then
  bold "Installing Node deps…"
  npm --prefix "$FRONTEND" install
fi

bold "Starting Next.js on :3010…"
npm --prefix "$FRONTEND" run dev &
FRONTEND_PID=$!

green ""
green "  App      → http://localhost:3010"
green "  API docs → http://localhost:8001/docs"
green ""
green "  Press Ctrl-C to stop both services."

trap "kill $BACKEND_PID $FRONTEND_PID 2>/dev/null" INT TERM
wait
