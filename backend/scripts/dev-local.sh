#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker is required for npm run dev:local" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "error: Docker daemon is not running." >&2
  echo "Start Docker Desktop (or your Docker daemon) and rerun: npm run dev:local" >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "error: docker compose plugin is required for npm run dev:local" >&2
  exit 1
fi

if [ ! -f ".env.local" ]; then
  cp ".env.local.example" ".env.local"
  echo "Created backend/.env.local from .env.local.example"
fi

# Ensure local Docker DB URL is set when using the example defaults.
if grep -q '^DATABASE_URL=postgres://user:pass@localhost:5432/remclaw$' ".env.local"; then
  awk '
  /^DATABASE_URL=/ { print "DATABASE_URL=postgres://remclaw:remclaw@localhost:54329/remclaw"; next }
  { print }
  ' ".env.local" > ".env.local.tmp" && mv ".env.local.tmp" ".env.local"
fi

# Repair malformed values from previous script versions.
if grep -q '^DATABASE_URL=postgres://remclaw:remclaw:54329/remclaw$' ".env.local"; then
  awk '
  /^DATABASE_URL=/ { print "DATABASE_URL=postgres://remclaw:remclaw@localhost:54329/remclaw"; next }
  { print }
  ' ".env.local" > ".env.local.tmp" && mv ".env.local.tmp" ".env.local"
fi

if grep -q '^JWT_SECRET=replace-with-random-secret$' ".env.local"; then
  JWT_SECRET_VALUE="$(openssl rand -base64 32)"
  perl -0pi -e "s#^JWT_SECRET=.*\$#JWT_SECRET=${JWT_SECRET_VALUE}#m" ".env.local"
fi

if grep -q '^GATEWAY_ENCRYPTION_KEY=replace-with-strong-key$' ".env.local"; then
  GATEWAY_KEY_VALUE="$(openssl rand -hex 32)"
  perl -0pi -e "s#^GATEWAY_ENCRYPTION_KEY=.*\$#GATEWAY_ENCRYPTION_KEY=${GATEWAY_KEY_VALUE}#m" ".env.local"
fi

echo "Starting local Postgres (Docker)..."
docker compose up -d db

echo "Waiting for Postgres health..."
for i in {1..30}; do
  status="$(docker inspect --format='{{.State.Health.Status}}' remclaw-backend-db 2>/dev/null || true)"
  if [ "$status" = "healthy" ]; then
    break
  fi
  sleep 1
done

status="$(docker inspect --format='{{.State.Health.Status}}' remclaw-backend-db 2>/dev/null || true)"
if [ "$status" != "healthy" ]; then
  echo "error: Postgres container did not become healthy" >&2
  exit 1
fi

echo "Starting backend dev server..."
npm run dev
