#!/usr/bin/env bash
#
# pg-dump.sh — daily backup for the cdcf-auth Postgres instances.
#
# Dumps both zitadel-db and openfga-db to gzipped files under
# /var/backups/cdcf-auth/, named with the UTC date. Off-server copy is
# the caller's responsibility (e.g. rclone, restic, Plesk's backup).
#
# Wire into cron:
#   15 3 * * * /opt/cdcf-auth/backup/pg-dump.sh >> /var/log/cdcf-auth-backup.log 2>&1
#
# Reads passwords from /opt/cdcf-auth/.env.production (gitignored).
#
# IMPORTANT: this dump is NOT sufficient on its own. Zitadel decryption
# requires ZITADEL_MASTERKEY. Back it up separately, out-of-band.

set -euo pipefail

ENV_FILE="${ENV_FILE:-/opt/cdcf-auth/.env.production}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/cdcf-auth}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

mkdir -p "$BACKUP_DIR"
ts="$(date -u +%Y%m%d-%H%M%S)"

dump_one() {
    local container="$1" user="$2" db="$3" password="$4"
    local out="$BACKUP_DIR/${db}-${ts}.sql.gz"
    PGPASSWORD="$password" docker exec -e PGPASSWORD="$password" "$container" \
        pg_dump -U "$user" -d "$db" --format=plain --no-owner --no-privileges \
        | gzip -9 > "$out"
    echo "wrote $out ($(du -h "$out" | cut -f1))"
}

dump_one cdcf-auth-zitadel-db-1 zitadel zitadel "$ZITADEL_DB_PASSWORD"
dump_one cdcf-auth-openfga-db-1 openfga openfga "$OPENFGA_DB_PASSWORD"

# Prune anything older than retention window
find "$BACKUP_DIR" -name '*.sql.gz' -mtime "+${RETENTION_DAYS}" -delete
