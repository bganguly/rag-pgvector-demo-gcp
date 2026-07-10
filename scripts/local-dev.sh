#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND="$ROOT/backend"
FRONTEND="$ROOT/frontend"

# ── env ──────────────────────────────────────────────────────────
if [ ! -f "$ROOT/.env" ]; then
  cp "$ROOT/.env.example" "$ROOT/.env"
  echo "Created .env from .env.example — fill in your API keys."
  exit 1
fi

# ── infra ────────────────────────────────────────────────────────
echo "Starting postgres + redis..."
docker compose -f "$ROOT/docker-compose.yml" up -d

echo "Waiting for postgres..."
until docker compose -f "$ROOT/docker-compose.yml" exec -T postgres pg_isready -U postgres &>/dev/null; do
  sleep 1
done
echo "Postgres ready."

# ── backend ──────────────────────────────────────────────────────
cd "$BACKEND"
[ -d .venv ] || python3 -m venv .venv
source .venv/bin/activate
pip install -q -r requirements.txt

# Copy env for backend
cp "$ROOT/.env" "$BACKEND/.env" 2>/dev/null || true

uvicorn app.main:app --host 0.0.0.0 --port 8001 --reload &
BACKEND_PID=$!
echo "Backend started (pid $BACKEND_PID) → http://localhost:8001"

# ── optional seed ────────────────────────────────────────────────
if [[ "${1:-}" == "--seed" ]]; then
  sleep 3
  echo "Seeding Wikipedia articles..."
  python3 "$ROOT/scripts/seed.py"
fi

# ── frontend ─────────────────────────────────────────────────────
cd "$FRONTEND"
[ -d node_modules ] || npm install

# Merge env vars for Next.js
grep -E '^(OPENAI|ANTHROPIC|NVIDIA|BACKEND)' "$ROOT/.env" > "$FRONTEND/.env.local" 2>/dev/null || true

npm run dev &
FRONTEND_PID=$!
echo "Frontend started (pid $FRONTEND_PID) → http://localhost:3010"

echo ""
echo "  Backend  http://localhost:8001/docs"
echo "  App      http://localhost:3010"
echo ""
echo "Press Ctrl+C to stop all processes."

cleanup() {
  echo "Stopping..."
  kill "$BACKEND_PID" "$FRONTEND_PID" 2>/dev/null || true
  docker compose -f "$ROOT/docker-compose.yml" down
}
trap cleanup EXIT INT TERM

wait "$BACKEND_PID" "$FRONTEND_PID"
