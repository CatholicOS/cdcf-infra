#!/usr/bin/env bash
#
# pg-dump.sh — daily backup for the cdcf-auth databases.
#
# Both databases live on the host's native PostgreSQL (the auth stack
# has no containerized DBs), so this uses the host's pg_dump directly.
# No docker exec needed.
#
# Dumps `zitadel` and `openfga` to gzipped files under
# /var/backups/cdcf-auth/, named with the UTC date, then copies them
# off-server over SFTP when SFTP_HOST is set.
#
# Wire into cron:
#   15 3 * * * /opt/cdcf-auth/auth/backup/pg-dump.sh >> /var/log/cdcf-auth-backup.log 2>&1
#
# Reads connection credentials from /opt/cdcf-auth/auth/.env.production.
#
# IMPORTANT: this dump is NOT sufficient on its own. Zitadel decryption
# requires ZITADEL_MASTERKEY. Back it up separately, out-of-band.
#
# OFF-SERVER COPY. A dump that never leaves the machine does not survive
# the failure it exists for, so the push is part of this script rather
# than a caller's responsibility. It targets the same SFTP host Plesk's
# own backups use, but authenticates with its OWN key: Plesk's key lives
# under /opt/psa/var/modules/sftp-backup/ssh-keys/ with a randomly
# generated filename that the extension may regenerate on update, and a
# backup job that borrows it would start failing silently the day it did.
#
# Plesk's backups do NOT cover these databases and cannot be made to:
# Plesk backs up what is in its own registry, and every database there is
# MySQL. `zitadel` and `openfga` are host PostgreSQL databases it has no
# knowledge of. This script is the only thing backing them up.
#
# The push is SKIPPED, not failed, when SFTP_HOST is empty — so a local
# or staging run needs no credentials. When it IS set, a failed upload
# exits non-zero with the local dump left in place: losing the off-server
# copy silently is the one outcome worth making noisy.

set -euo pipefail

ENV_FILE="${ENV_FILE:-/opt/cdcf-auth/auth/.env.production}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/cdcf-auth}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
PG_HOST="${PG_HOST:-localhost}"
PG_PORT="${PG_PORT:-5432}"

# Off-server copy. Empty SFTP_HOST disables the push entirely.
SFTP_HOST="${SFTP_HOST:-}"
SFTP_PORT="${SFTP_PORT:-22}"
SFTP_USER="${SFTP_USER:-plesk-backup}"
SFTP_PATH="${SFTP_PATH:-/uploads/cdcf-auth}"
SFTP_KEY="${SFTP_KEY:-/root/.ssh/cdcf-backup}"

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

# --- off-server copy ---------------------------------------------------
#
# Only this run's files are pushed, named by $ts, so a re-run never
# re-uploads the whole retention window.
#
# The remote listing afterwards is not decoration: sftp's `put` can report
# success for a transfer the far end truncated, and a backup you have not
# confirmed landed is not a backup. `-mkdir` is prefixed with `-` so an
# already-existing directory is not an error, which is the normal case.
push_off_server() {
    local remote_dir="$SFTP_PATH"
    local batch expected=0 seen=0

    # Without nullglob a no-match glob stays literal and would be "put" as a
    # path containing a `*`, which fails obscurely instead of saying so.
    shopt -s nullglob
    local dumps=( "$BACKUP_DIR"/*-"${ts}".sql.gz )
    shopt -u nullglob
    if (( ${#dumps[@]} == 0 )); then
        echo "no dumps matching ${ts} to push — refusing to report success" >&2
        return 1
    fi

    batch="$(mktemp)"
    trap 'rm -f "$batch"' RETURN

    {
        printf -- '-mkdir %s\n' "$remote_dir"
        for f in "${dumps[@]}"; do
            printf 'put %s %s/\n' "$f" "$remote_dir"
        done
        printf 'ls -1 %s\n' "$remote_dir"
    } > "$batch"

    local out
    if ! out="$(sftp -b "$batch" \
                     -P "$SFTP_PORT" \
                     -i "$SFTP_KEY" \
                     -o BatchMode=yes \
                     -o StrictHostKeyChecking=accept-new \
                     "${SFTP_USER}@${SFTP_HOST}" 2>&1)"; then
        echo "off-server copy FAILED — local dumps kept in $BACKUP_DIR" >&2
        echo "$out" >&2
        return 1
    fi

    expected=${#dumps[@]}
    for f in "${dumps[@]}"; do
        if grep -qF -- "$(basename "$f")" <<<"$out"; then
            seen=$(( seen + 1 ))
        else
            echo "off-server copy INCOMPLETE — $(basename "$f") not in remote listing" >&2
            return 1
        fi
    done

    echo "pushed $seen/$expected dump(s) to ${SFTP_USER}@${SFTP_HOST}:${remote_dir}"
}

if [[ -n "$SFTP_HOST" ]]; then
    if [[ ! -r "$SFTP_KEY" ]]; then
        echo "SFTP_HOST is set but SFTP_KEY ($SFTP_KEY) is unreadable" >&2
        exit 1
    fi
    push_off_server
else
    echo "SFTP_HOST unset — skipping off-server copy (local dumps only)"
fi

# Prune anything older than retention window. Runs last, and only after a
# successful push: `set -e` means a failed upload aborts before this, so a
# run that could not get its dump off the box never also deletes the older
# ones that did.
find "$BACKUP_DIR" -name '*.sql.gz' -mtime "+${RETENTION_DAYS}" -delete
