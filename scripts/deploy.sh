#!/usr/bin/env bash
# deploy.sh — Pull delle immagini più recenti e restart dei servizi.
# Da lanciare sul droplet come utente dit, dalla root del repo dit-infra.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .env.prod ]; then
    echo "ERRORE: .env.prod non trovato. Crealo da .env.prod.example." >&2
    exit 1
fi

COMPOSE="docker compose -f docker-compose.prod.yml --env-file .env.prod"

echo "==> Pull immagini ultime"
$COMPOSE pull dit-api dit-ping dit-worker

echo "==> Migrazione database (se necessaria)"
./scripts/migrate.sh

echo "==> Restart servizi applicativi"
$COMPOSE up -d --no-deps dit-api dit-ping dit-worker

echo "==> Pulizia immagini obsolete"
docker image prune -f

echo "==> Stato corrente"
$COMPOSE ps

echo
echo "Deploy completato."
