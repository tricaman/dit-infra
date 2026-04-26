#!/usr/bin/env bash
# deploy.sh — Pull delle immagini più recenti e restart dei servizi.
# Uso:
#   ./scripts/deploy.sh                # full deploy: pull tutto + migrate + restart all
#   ./scripts/deploy.sh dit-api        # pull solo dit-api + migrate + restart dit-api
#   ./scripts/deploy.sh dit-ping       # pull solo dit-ping + restart dit-ping (no migrate)
#   ./scripts/deploy.sh dit-worker     # pull solo dit-worker + restart dit-worker (no migrate)
# Da lanciare sul droplet come utente dit. Trova la root del repo automaticamente.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .env.prod ]; then
    echo "ERRORE: .env.prod non trovato. Crealo da .env.prod.example." >&2
    exit 1
fi

COMPOSE="docker compose -f docker-compose.prod.yml --env-file .env.prod"
SERVICE="${1:-}"

case "$SERVICE" in
  dit-api)
    echo "==> Pull dit-api"
    $COMPOSE pull dit-api
    echo "==> Migrazione database (Prisma)"
    ./scripts/migrate.sh
    echo "==> Restart dit-api"
    $COMPOSE up -d --no-deps dit-api
    ;;
  dit-ping|dit-worker)
    echo "==> Pull $SERVICE"
    $COMPOSE pull "$SERVICE"
    echo "==> Restart $SERVICE"
    $COMPOSE up -d --no-deps "$SERVICE"
    ;;
  "")
    echo "==> Pull immagini ultime (tutti i servizi)"
    $COMPOSE pull dit-api dit-ping dit-worker
    echo "==> Migrazione database (se necessaria)"
    ./scripts/migrate.sh
    echo "==> Restart servizi applicativi"
    $COMPOSE up -d --no-deps dit-api dit-ping dit-worker
    ;;
  *)
    echo "ERRORE: servizio sconosciuto '$SERVICE'." >&2
    echo "Servizi validi: dit-api, dit-ping, dit-worker" >&2
    exit 1
    ;;
esac

echo "==> Pulizia immagini obsolete"
docker image prune -f

echo "==> Stato corrente"
$COMPOSE ps

echo
echo "Deploy completato${SERVICE:+ ($SERVICE)}."
