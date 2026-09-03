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
# PEER_DBS names further databases to dump on the same host through the
# local `postgres` superuser role instead of a per-service password —
# `litcal_staging` and `litcal_production` in production. They are dumped
# this way because their credentials live in the API's own env file on a
# different vhost, and copying a second service's password into this one
# to read a database the local superuser can already reach would create a
# credential to rotate for no gain.
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

# Databases dumped via the local `postgres` superuser (peer auth) rather
# than a password from ENV_FILE. Space-separated; empty disables.
PEER_DBS="${PEER_DBS:-}"

# Large peer databases. Dumped the same way, but at a cheaper compression
# level under nice/ionice, and DELETED locally once the off-server copy is
# confirmed — the remote keeps the history. /var/backups is small enough
# that a nightly multi-GB dump with a retention window would fill it.
LARGE_DBS="${LARGE_DBS:-}"
LARGE_GZIP_LEVEL="${LARGE_GZIP_LEVEL:-6}"

# Host configuration to archive: files and directories that exist in
# neither git nor a Plesk-backed vhost. Space-separated; empty disables.
#
# The archive is ALWAYS encrypted, and refuses to run unencrypted, because
# what makes these paths worth keeping is exactly what makes them
# dangerous to store: ZITADEL_MASTERKEY lives here, and the zitadel dump it
# decrypts is going to the same remote. Encrypting to a key held offline is
# what keeps that co-location from undoing the "back the masterkey up
# separately" rule.
CONFIG_PATHS="${CONFIG_PATHS:-}"
AGE_RECIPIENT="${AGE_RECIPIENT:-}"

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

# Everything this run produced, and the subset to delete once the copy is
# confirmed. Tracked explicitly rather than re-globbing: the artifacts no
# longer share one filename shape, and a glob that quietly matched nothing
# would push nothing while reporting success.
ARTIFACTS=()
EPHEMERAL=()

dump_one() {
    local user="$1" db="$2" password="$3"
    local out="$BACKUP_DIR/${db}-${ts}.sql.gz"
    PGPASSWORD="$password" pg_dump \
        --host="$PG_HOST" --port="$PG_PORT" --username="$user" \
        --dbname="$db" --format=plain --no-owner --no-privileges \
        | gzip -9 > "$out"
    ARTIFACTS+=("$out")
    echo "wrote $out ($(du -h "$out" | cut -f1))"
}

# Dumps a database through the local `postgres` role. `sudo -n` so a missing
# sudo right fails immediately and visibly rather than hanging on a prompt
# under cron.
dump_peer() {
    local db="$1"
    local out="$BACKUP_DIR/${db}-${ts}.sql.gz"
    sudo -n -u postgres pg_dump \
        --port="$PG_PORT" \
        --dbname="$db" --format=plain --no-owner --no-privileges \
        | gzip -9 > "$out"
    ARTIFACTS+=("$out")
    echo "wrote $out ($(du -h "$out" | cut -f1))"
}

# A large peer database. Two differences from dump_peer(), both about cost
# rather than correctness: a cheaper gzip level, and nice/ionice so a
# multi-GB dump competes less with the services sharing this box. Measured
# on bibleget_dev (4.7 GB), `gzip -9` was heavy enough to disturb the host.
#
# The result is registered as EPHEMERAL: it is deleted once the off-server
# copy is confirmed, so the local disk never holds a retention window of
# them.
dump_large() {
    local db="$1"
    local out="$BACKUP_DIR/${db}-${ts}.sql.gz"
    nice -n 19 ionice -c3 sudo -n -u postgres pg_dump \
        --port="$PG_PORT" \
        --dbname="$db" --format=plain --no-owner --no-privileges \
        | nice -n 19 gzip -"$LARGE_GZIP_LEVEL" > "$out"
    ARTIFACTS+=("$out")
    EPHEMERAL+=("$out")
    echo "wrote $out ($(du -h "$out" | cut -f1)) [large: local copy removed after push]"
}

# Host configuration that lives in neither git nor a Plesk-backed vhost.
#
# `age` is required, not optional: this archive carries ZITADEL_MASTERKEY,
# and the zitadel dump it decrypts is going to the same destination. The
# encryption is what keeps putting both in one place from being a mistake.
archive_config() {
    local out="$BACKUP_DIR/config-${ts}.tar.gz.age"
    local missing=()
    local p

    for p in $CONFIG_PATHS; do
        [[ -e "$p" ]] || missing+=("$p")
    done
    if (( ${#missing[@]} > 0 )); then
        echo "CONFIG_PATHS names paths that do not exist: ${missing[*]}" >&2
        return 1
    fi

    # tar reads through the paths as root; age encrypts before anything
    # touches the disk, so no cleartext copy of the secrets is ever written.
    tar -czf - --absolute-names $CONFIG_PATHS 2>/dev/null \
        | age -r "$AGE_RECIPIENT" > "$out"
    ARTIFACTS+=("$out")
    echo "wrote $out ($(du -h "$out" | cut -f1)) [age-encrypted]"
}

# Preflight, BEFORE anything is written: a PEER_DBS entry that does not exist
# is a configuration error, and finding out halfway through would leave a run
# that dumped some databases, pushed none, and exited non-zero. Checking first
# means the job either does all of its work or none of it.
if [[ -n "$CONFIG_PATHS" ]]; then
    if [[ -z "$AGE_RECIPIENT" ]]; then
        echo "CONFIG_PATHS is set but AGE_RECIPIENT is empty — refusing to archive secrets in the clear" >&2
        exit 1
    fi
    if ! command -v age >/dev/null 2>&1; then
        echo "CONFIG_PATHS is set but \`age\` is not installed" >&2
        exit 1
    fi
fi

if [[ -n "$PEER_DBS$LARGE_DBS" ]]; then
    for db in $PEER_DBS $LARGE_DBS; do
        if ! sudo -n -u postgres psql --port="$PG_PORT" -Atqc \
                "SELECT 1 FROM pg_database WHERE datname = '$db'" | grep -q 1; then
            echo "PEER_DBS names '$db', which does not exist on $PG_HOST" >&2
            exit 1
        fi
    done
fi

dump_one "$ZITADEL_DB_USER" "$ZITADEL_DB_NAME" "$ZITADEL_DB_PASSWORD"
dump_one "$OPENFGA_DB_USER" "$OPENFGA_DB_NAME" "$OPENFGA_DB_PASSWORD"

for db in $PEER_DBS; do
    dump_peer "$db"
done

for db in $LARGE_DBS; do
    dump_large "$db"
done

if [[ -n "$CONFIG_PATHS" ]]; then
    archive_config
fi

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

    local dumps=( "${ARTIFACTS[@]}" )
    if (( ${#dumps[@]} == 0 )); then
        echo "nothing was produced this run — refusing to report success" >&2
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

# Large dumps exist locally only long enough to be copied. This runs after
# push_off_server has confirmed each file against the remote listing, and
# `set -e` means a failed or unverified push never reaches it — so the local
# copy is deleted only once another one is known to exist.
if (( ${#EPHEMERAL[@]} > 0 )); then
    if [[ -z "$SFTP_HOST" ]]; then
        echo "keeping ${#EPHEMERAL[@]} large dump(s) locally: no SFTP_HOST, so nothing was copied off" >&2
    else
        for f in "${EPHEMERAL[@]}"; do
            rm -f "$f"
            echo "removed local $(basename "$f") (copy confirmed off-server)"
        done
    fi
fi

# Prune anything older than retention window. Runs last, and only after a
# successful push: `set -e` means a failed upload aborts before this, so a
# run that could not get its dump off the box never also deletes the older
# ones that did.
# Matches the config archives too: they are small, but "small and forever"
# is still unbounded.
find "$BACKUP_DIR" \( -name '*.sql.gz' -o -name '*.tar.gz.age' \) \
     -mtime "+${RETENTION_DAYS}" -delete
