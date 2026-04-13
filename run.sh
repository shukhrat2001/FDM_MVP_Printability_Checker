#!/usr/bin/env bash
ROOT="$(cd "$(dirname "$0")" && pwd)"

# ── free ports before starting ───────────────────────────────────────────────
free_port() {
  local port=$1
  local pids
  pids=$(lsof -ti tcp:"$port" 2>/dev/null || true)
  if [ -n "$pids" ]; then
    echo "  Killing stale process(es) on port $port: $pids"
    echo "$pids" | xargs kill -9 2>/dev/null || true
    sleep 0.5
  fi
}

echo "Clearing ports 8000 and 5173…"
free_port 8000
free_port 5173

# ── clean shutdown on Ctrl-C ─────────────────────────────────────────────────
trap 'echo ""; echo "Shutting down…"; kill $(jobs -p) 2>/dev/null; wait 2>/dev/null; echo "Done."; exit 0' INT TERM

# ── backend ───────────────────────────────────────────────────────────────────
echo "Starting backend  → http://localhost:8000"
cd "$ROOT/backend"
source venv/bin/activate
uvicorn main:app --reload --port 8000 2>&1 &

# wait until backend is up (max 15 s)
echo -n "Waiting for backend"
for i in $(seq 1 30); do
  if curl -sf http://localhost:8000/health >/dev/null 2>&1; then
    echo " ✓"
    break
  fi
  echo -n "."
  sleep 0.5
done

# ── frontend ──────────────────────────────────────────────────────────────────
echo "Starting frontend → http://localhost:5173"
cd "$ROOT/frontend"
npm run dev 2>&1 &

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Open: http://localhost:5173"
echo "  API:  http://localhost:8000/docs"
echo "  Press Ctrl-C to stop both servers"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

wait
