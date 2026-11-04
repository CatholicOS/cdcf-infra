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

# How many local dumps of each large database may exist at once, tonight's
# included, while pushes are failing. A failed push keeps its large dump, so
# without a cap every failing night adds one until /var/backups is full — and
# then the dump itself fails and takes the rest of the run with it, which is
# how October 2026 lost five nights of bibleget_dev. Older unpushed dumps are
# removed before tonight's is written; the newest ones are kept.
LARGE_KEEP_UNPUSHED="${LARGE_KEEP_UNPUSHED:-2}"

# Days of history to keep on the remote, by the date in each file name.
# Defaults to RETENTION_DAYS; 0 disables the remote prune. Without one the
# remote held every nightly dump until it was full and refused writes.
REMOTE_RETENTION_DAYS="${REMOTE_RETENTION_DAYS:-}"

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

# After the env file, so a RETENTION_DAYS set there carries over.
REMOTE_RETENTION_DAYS="${REMOTE_RETENTION_DAYS:-$RETENTION_DAYS}"

# Set when a step that does not undo the backup fails (the remote prune), so
# the run can finish its local work and still exit non-zero.
SOFT_FAILURE=0

mkdir -p "$BACKUP_DIR"
ts="$(date -u +%Y%m%d-%H%M%S)"

# Everything this run produced, and the subset to delete once the copy is
# confirmed. Tracked explicitly rather than re-globbing: the artifacts no
# longer share one filename shape, and a glob that quietly matched nothing
# would push nothing while reporting success.
ARTIFACTS=()
EPHEMERAL=()

# The artifact currently being written, if any. Dumps land on a `.part` name
# and are renamed only once complete, so an interrupted run can never leave a
# truncated file that looks like a finished one — `gzip` output is valid right
# up until it is not, and a half-written multi-GB dump is indistinguishable
# from a good one by size alone.
CURRENT_PART=""
cleanup_partial() {
    [[ -n "$CURRENT_PART" && -e "$CURRENT_PART" ]] || return 0
    rm -f "$CURRENT_PART"
    echo "removed incomplete $(basename "$CURRENT_PART")" >&2
}
trap cleanup_partial EXIT

# A SIGKILL skips the trap above, so also sweep anything a previous run left.
# Only cron runs this, and never concurrently, so nothing here can be in flight.
find "$BACKUP_DIR" -name '*.part' -delete 2>/dev/null || true

dump_one() {
    local user="$1" db="$2" password="$3"
    local out="$BACKUP_DIR/${db}-${ts}.sql.gz"
    CURRENT_PART="$out.part"
    PGPASSWORD="$password" pg_dump \
        --host="$PG_HOST" --port="$PG_PORT" --username="$user" \
        --dbname="$db" --format=plain --no-owner --no-privileges \
        | gzip -9 > "$CURRENT_PART"
    mv "$CURRENT_PART" "$out"; CURRENT_PART=""
    ARTIFACTS+=("$out")
    echo "wrote $out ($(du -h "$out" | cut -f1))"
}

# Dumps a database through the local `postgres` role. `sudo -n` so a missing
# sudo right fails immediately and visibly rather than hanging on a prompt
# under cron.
dump_peer() {
    local db="$1"
    local out="$BACKUP_DIR/${db}-${ts}.sql.gz"
    CURRENT_PART="$out.part"
    sudo -n -u postgres pg_dump \
        --port="$PG_PORT" \
        --dbname="$db" --format=plain --no-owner --no-privileges \
        | gzip -9 > "$CURRENT_PART"
    mv "$CURRENT_PART" "$out"; CURRENT_PART=""
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
    CURRENT_PART="$out.part"
    nice -n 19 ionice -c3 sudo -n -u postgres pg_dump \
        --port="$PG_PORT" \
        --dbname="$db" --format=plain --no-owner --no-privileges \
        | nice -n 19 gzip -"$LARGE_GZIP_LEVEL" > "$CURRENT_PART"
    mv "$CURRENT_PART" "$out"; CURRENT_PART=""
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
    CURRENT_PART="$out.part"
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
        | age -r "$AGE_RECIPIENT" > "$CURRENT_PART"
    mv "$CURRENT_PART" "$out"; CURRENT_PART=""
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

# Any local dump of a large database is one whose push failed: a confirmed
# push deletes it. Keep the newest LARGE_KEEP_UNPUSHED - 1 of them, leaving
# room for tonight's. The name must be exactly <db>-<date>-<time>.sql.gz, so
# a database whose name merely starts with this one is never touched.
cap_unpushed() {
    local db="$1" keep=$(( LARGE_KEEP_UNPUSHED > 1 ? LARGE_KEEP_UNPUSHED - 1 : 0 ))
    local f
    local -a found=()
    for f in "$BACKUP_DIR/${db}"-*.sql.gz; do
        [[ "$(basename "$f")" =~ ^${db}-[0-9]{8}-[0-9]{6}\.sql\.gz$ ]] && found+=("$f")
    done
    (( ${#found[@]} > keep )) || return 0
    # Timestamps in the names sort chronologically.
    mapfile -t found < <(printf '%s\n' "${found[@]}" | sort)
    for f in "${found[@]:0:${#found[@]}-keep}"; do
        rm -f "$f"
        echo "removed unpushed $(basename "$f") (keeping at most $LARGE_KEEP_UNPUSHED local dumps of $db)" >&2
    done
}

# Only when there is a remote: with SFTP_HOST empty the local dumps are the
# only copies, and the retention window, not this cap, governs them.
if [[ -n "$SFTP_HOST" ]]; then
    for db in $LARGE_DBS; do
        cap_unpushed "$db"
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
# confirmed landed is not a backup. Each file must appear in it at its local
# size, not merely by name. `-mkdir` is prefixed with `-` so an
# already-existing directory is not an error, which is the normal case.
#
# The listing is kept in REMOTE_LISTING for the remote prune.
REMOTE_LISTING=""
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
        printf 'ls -l %s\n' "$remote_dir"
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
    local name local_size remote_size
    for f in "${dumps[@]}"; do
        name="$(basename "$f")"
        local_size="$(stat -c %s "$f")"
        # `ls -l` lines end in the full remote path; the size is column 5.
        remote_size="$(awk -v p="$remote_dir/$name" '$1 ~ /^-/ && $NF == p { print $5 }' <<<"$out")"
        if [[ -z "$remote_size" ]]; then
            echo "off-server copy INCOMPLETE — $name not in remote listing" >&2
            return 1
        elif [[ "$remote_size" != "$local_size" ]]; then
            echo "off-server copy INCOMPLETE — $name size mismatch (local $local_size, remote $remote_size)" >&2
            return 1
        fi
        seen=$(( seen + 1 ))
    done
    REMOTE_LISTING="$out"

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

# --- remote prune ------------------------------------------------------
#
# Same window on the remote, judged by the date in each file name (sftp gives
# no usable mtime filter). Runs only after a confirmed push, so tonight's copy
# of every database is known to be there before any older one is removed. Only
# names this script writes are candidates — <db>-<YYYYMMDD>-<HHMMSS> plus
# .sql.gz or .tar.gz.age, for the databases it dumps — so Plesk's archives and
# anything else sharing the directory are never touched.
#
# A failure here does not undo the backup, so it does not stop the run; it is
# reported and turns the exit status non-zero at the end.
prune_remote() {
    local cutoff batch out name db n=0
    cutoff="$(date -u -d "-${REMOTE_RETENTION_DAYS} days" +%Y%m%d)"
    local -a ours=( "$ZITADEL_DB_NAME" "$OPENFGA_DB_NAME" $PEER_DBS $LARGE_DBS config )

    batch="$(mktemp)"
    trap 'rm -f "$batch"' RETURN

    while read -r name; do
        for db in "${ours[@]}"; do
            if [[ "$name" =~ ^${db}-([0-9]{8})-[0-9]{6}\.(sql\.gz|tar\.gz\.age)$ ]] \
                    && [[ "${BASH_REMATCH[1]}" < "$cutoff" ]]; then
                printf 'rm %s/%s\n' "$SFTP_PATH" "$name" >> "$batch"
                n=$(( n + 1 ))
                break
            fi
        done
    done < <(awk '$1 ~ /^-/ { n = split($NF, p, "/"); print p[n] }' <<<"$REMOTE_LISTING")

    (( n > 0 )) || { echo "remote prune: nothing older than $REMOTE_RETENTION_DAYS days"; return 0; }

    if ! out="$(sftp -b "$batch" \
                     -P "$SFTP_PORT" \
                     -i "$SFTP_KEY" \
                     -o BatchMode=yes \
                     -o StrictHostKeyChecking=accept-new \
                     "${SFTP_USER}@${SFTP_HOST}" 2>&1)"; then
        echo "remote prune FAILED — older dumps left on ${SFTP_HOST}" >&2
        echo "$out" >&2
        return 1
    fi
    echo "pruned $n remote file(s) older than $REMOTE_RETENTION_DAYS days"
}

if [[ -n "$SFTP_HOST" && "$REMOTE_RETENTION_DAYS" != 0 ]]; then
    prune_remote || SOFT_FAILURE=1
fi

exit "$SOFT_FAILURE"
