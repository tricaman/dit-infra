#!/usr/bin/env bash
# migrate.sh — Esegue prisma migrate deploy in un container one-shot dit-api.
# Richiede che postgres sia su (lo avvia se necessario) e che dit-api image sia presente.
set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE="docker compose -f docker-compose.prod.yml --env-file .env.prod"

echo "==> Assicuro che postgres sia in esecuzione"
$COMPOSE up -d postgres
$COMPOSE exec -T postgres sh -c 'until pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"; do sleep 1; done'

echo "==> Applico migrazioni Prisma (prisma migrate deploy)"
$COMPOSE run --rm --no-deps \
    --entrypoint sh \
    dit-api -c "npx prisma migrate deploy"

echo "Migrazioni applicate."
