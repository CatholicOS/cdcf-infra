#!/usr/bin/env bash
#
# pg-dump.sh — daily backup for the cdcf-auth databases.
#
# Both databases live on the host's native PostgreSQL (the auth stack
# has no containerized DBs), so this uses the host's pg_dump directly.
# No docker exec needed.
#
# Dumps `zitadel` and `openfga` to gzipped files under
# /var/backups/cdcf-auth/, named with the UTC date. Off-server copy is
# the caller's responsibility (e.g. rclone, restic, Plesk's backup).
#
# Wire into cron:
#   15 3 * * * /opt/cdcf-auth/auth/backup/pg-dump.sh >> /var/log/cdcf-auth-backup.log 2>&1
#
# Reads connection credentials from /opt/cdcf-auth/auth/.env.production.
#
# IMPORTANT: this dump is NOT sufficient on its own. Zitadel decryption
# requires ZITADEL_MASTERKEY. Back it up separately, out-of-band.

set -euo pipefail

ENV_FILE="${ENV_FILE:-/opt/cdcf-auth/auth/.env.production}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/cdcf-auth}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
PG_HOST="${PG_HOST:-localhost}"
PG_PORT="${PG_PORT:-5432}"

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

mkdir -p "$BACKUP_DIR"
ts="$(date -u +%Y%m%d-%H%M%S)"

dump_one() {
    local user="$1" db="$2" password="$3"
    local out="$BACKUP_DIR/${db}-${ts}.sql.gz"
    PGPASSWORD="$password" pg_dump \
        --host="$PG_HOST" --port="$PG_PORT" --username="$user" \
        --dbname="$db" --format=plain --no-owner --no-privileges \
        | gzip -9 > "$out"
    echo "wrote $out ($(du -h "$out" | cut -f1))"
}

dump_one "$ZITADEL_DB_USER" "$ZITADEL_DB_NAME" "$ZITADEL_DB_PASSWORD"
dump_one "$OPENFGA_DB_USER" "$OPENFGA_DB_NAME" "$OPENFGA_DB_PASSWORD"

# Prune anything older than retention window
find "$BACKUP_DIR" -name '*.sql.gz' -mtime "+${RETENTION_DAYS}" -delete
