#!/usr/bin/env bash
# backup-postgres.sh — pg_dump del database in /opt/dit/backups con rotazione.
# Da schedulare via cron, es:
#   0 3 * * * /opt/dit/scripts/backup-postgres.sh >> /var/log/dit-backup.log 2>&1
set -euo pipefail

cd "$(dirname "$0")/.."

BACKUP_DIR="${BACKUP_DIR:-./backups}"
KEEP_DAYS="${KEEP_DAYS:-14}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
COMPOSE="docker compose -f docker-compose.prod.yml --env-file .env.prod"

mkdir -p "$BACKUP_DIR"
OUT="$BACKUP_DIR/dit-$TIMESTAMP.sql.gz"

echo "==> Dump $OUT"
$COMPOSE exec -T postgres sh -c \
    'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=plain --no-owner --no-privileges' \
    | gzip -9 > "$OUT"

echo "==> Pulizia backup più vecchi di $KEEP_DAYS giorni"
find "$BACKUP_DIR" -name 'dit-*.sql.gz' -type f -mtime +"$KEEP_DAYS" -print -delete

echo "Backup completato: $OUT ($(du -h "$OUT" | cut -f1))"
