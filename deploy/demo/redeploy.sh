#!/usr/bin/env bash
# Pull the latest demo image and (re)start the stack. Run on the Lightsail host.
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. Copy .env.example to .env and fill it in." >&2
  exit 1
fi

echo "Pulling latest images..."
docker compose pull

echo "Starting stack..."
docker compose up -d

echo "Pruning dangling images..."
docker image prune -f

echo "Done. Current state:"
docker compose ps
