#!/usr/bin/env bash
# Boot the bundled single-file backend (DevHub_Portable/dist/bundled/index.js)
# against the repo's own node_modules and probe it. Used to iterate on the
# esbuild external list. Run from repo root.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
PORT="${1:-7077}"
export DEVHUB_PORT="$PORT"
export DEVHUB_DATA_DIR="$(mktemp -d)"
export DOC_URL="https://example.com"
export NODE_OPTIONS="--no-node-snapshot"
LOG=/tmp/devhub-boot.log
: > "$LOG"
node DevHub_Portable/dist/bundled/index.js --config DevHub_Portable/config/app-config.portable.yaml > "$LOG" 2>&1 &
PID=$!
RESULT="TIMEOUT"
for i in $(seq 1 90); do
  if ! kill -0 $PID 2>/dev/null; then RESULT="EXITED_EARLY"; break; fi
  # Root page is served unauthenticated by app-backend once the app is up.
  if curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then RESULT="UP"; break; fi
  sleep 1
done
if [ "$RESULT" = "UP" ]; then
  echo "=== BACKEND UP on :$PORT ==="
  curl -fsS "http://127.0.0.1:$PORT/" -o /tmp/devhub-root.html -w "root page: HTTP %{http_code}, %{size_download} bytes\n"
  grep -c "scaffolder\|catalog" /tmp/devhub-root.html >/dev/null 2>&1 && echo "(served frontend html)"
fi
kill $PID 2>/dev/null; wait $PID 2>/dev/null
echo "=== RESULT: $RESULT ==="
echo "=== last 30 log lines ==="
tail -30 "$LOG"
