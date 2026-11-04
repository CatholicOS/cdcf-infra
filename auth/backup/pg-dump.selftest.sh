#!/usr/bin/env bash
#
# pg-dump.selftest.sh — run auth/backup/pg-dump.sh against stub pg_dump, sudo,
# psql and sftp, and assert what each case leaves behind on both ends.
#
# Why this exists: in October 2026 the off-server copy started failing because
# the remote was full — nothing ever pruned it, so it held every nightly
# multi-GB bibleget_dev dump since the push began. Each failed push then kept
# its large dump locally, /var/backups filled, and from then on the large dump
# itself failed every night, taking the rest of the run with it. No backup of
# bibleget_dev or marriage_booklet_production was taken for five nights, and
# none reached the remote for eleven. The cases below pin the three behaviours
# that would have prevented it: the remote is pruned after a confirmed push,
# a push is confirmed by size and not just by name, and unpushed large dumps
# cannot pile up locally.
#
# How it works: the stubs are put first on PATH. The stub sftp reads the batch
# file and plays it against a local directory standing in for the remote, with
# a real sftp's output shape (`ls -l` lists full paths, size in column 5) and
# its batch semantics (a failing command aborts the batch unless prefixed with
# `-`). STUB_FAIL_PUT, STUB_TRUNCATE and STUB_FAIL_RM select a misbehaving
# remote per case.
#
# Requires GNU date (ubuntu-latest has it). Run it from anywhere:
#   ./auth/backup/pg-dump.selftest.sh
#
# Exit codes: 0 every case behaved as declared; 1 one or more did not.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/pg-dump.sh"

if [[ -t 1 ]]; then
    R=$'\033[0;31m'; G=$'\033[0;32m'; B=$'\033[0;34m'; N=$'\033[0m'
else
    R=""; G=""; B=""; N=""
fi

PASSES=0
FAILURES=0

[[ -f "$TARGET" ]] || { echo "${R}[selftest] not found: $TARGET${N}" >&2; exit 1; }
date -u -d '-1 day' +%Y%m%d >/dev/null 2>&1 || {
    echo "${R}[selftest] GNU date is required (date -d).${N}" >&2
    exit 1
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# --- stubs -----------------------------------------------------------------

STUBS="$SANDBOX/bin"
mkdir -p "$STUBS"

cat > "$STUBS/pg_dump" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == --dbname=* ]] && db="${a#--dbname=}"; done
printf -- '-- stub dump of %s\n' "${db:-unknown}"
head -c 4096 /dev/zero | tr '\0' 'x'
EOF

cat > "$STUBS/psql" <<'EOF'
#!/usr/bin/env bash
echo 1
EOF

# `sudo -n -u postgres CMD ...` → CMD ...
cat > "$STUBS/sudo" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n) shift ;;
        -u) shift 2 ;;
        *) break ;;
    esac
done
exec "$@"
EOF

cat > "$STUBS/sftp" <<'EOF'
#!/usr/bin/env bash
batch=""
while [[ $# -gt 1 ]]; do
    case "$1" in
        -b) batch="$2"; shift 2 ;;
        -P|-i|-o) shift 2 ;;
        *) shift ;;
    esac
done
root="${STUB_REMOTE_ROOT:?}"
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    tolerant=0
    [[ "$line" == -* ]] && { tolerant=1; line="${line#-}"; }
    echo "sftp> $line"
    read -r cmd a1 a2 <<<"$line"
    ok=1
    case "$cmd" in
        mkdir) mkdir "$root$a1" 2>/dev/null || { echo "remote mkdir \"$a1\": Failure" >&2; ok=0; } ;;
        put)
            name="$(basename "$a1")"
            if [[ -n "${STUB_FAIL_PUT:-}" ]]; then
                echo "write remote \"$a2$name\": Failure" >&2; ok=0
            elif [[ "$name" == ${STUB_TRUNCATE:-__none__}* ]]; then
                head -c 10 "$a1" > "$root${a2%/}/$name"
            else
                cp "$a1" "$root${a2%/}/$name"
            fi ;;
        ls)
            dir="$a2"; [[ "$a1" != -* ]] && dir="$a1"
            for f in "$root$dir"/*; do
                [[ -e "$f" ]] || continue
                printf -- '-rw-r--r--    ? 999      987      %s Nov  4 03:20 %s/%s\n' \
                    "$(stat -c %s "$f")" "$dir" "$(basename "$f")"
            done ;;
        rm)
            if [[ -n "${STUB_FAIL_RM:-}" ]]; then
                echo "Couldn't delete file: Failure" >&2; ok=0
            else
                rm "$root$a1" 2>/dev/null || { echo "Couldn't delete file: No such file" >&2; ok=0; }
            fi ;;
        *) echo "stub sftp: unknown command $cmd" >&2; ok=0 ;;
    esac
    (( ok || tolerant )) || exit 1
done < "$batch"
EOF

chmod +x "$STUBS"/*

# --- helpers ---------------------------------------------------------------

day() { date -u -d "-$1 day" +%Y%m%d; }

# Fresh local + remote dirs and env file for one case.
setup_case() {
    CASE_DIR="$SANDBOX/case-$1"
    mkdir -p "$CASE_DIR/local" "$CASE_DIR/remote/uploads/cdcf-auth"
    cat > "$CASE_DIR/env" <<EOF
ZITADEL_DB_USER=zitadel
ZITADEL_DB_NAME=zitadel
ZITADEL_DB_PASSWORD=x
OPENFGA_DB_USER=openfga
OPENFGA_DB_NAME=openfga
OPENFGA_DB_PASSWORD=x
PEER_DBS=litcal_staging
LARGE_DBS=bibleget_dev
SFTP_HOST=stub.invalid
SFTP_KEY=$CASE_DIR/env
EOF
}

remote() { echo "$CASE_DIR/remote/uploads/cdcf-auth/$1"; }
local_() { echo "$CASE_DIR/local/$1"; }

# Runs the script for the current case; extra env assignments as arguments.
run_script() {
    OUTPUT="$(env PATH="$STUBS:$PATH" ENV_FILE="$CASE_DIR/env" \
        BACKUP_DIR="$CASE_DIR/local" STUB_REMOTE_ROOT="$CASE_DIR/remote" \
        "$@" bash "$TARGET" 2>&1)"
    STATUS=$?
}

CASE_OK=1
check() {  # check <description> <command...>
    local what="$1"; shift
    if ! "$@"; then
        echo "    ${R}✗ $what${N}"
        CASE_OK=0
    fi
}
expect_status() { if [[ "$1" == 0 ]]; then [[ "$STATUS" == 0 ]]; else [[ "$STATUS" != 0 ]]; fi; }
output_has() { grep -qF -- "$1" <<<"$OUTPUT"; }
count() { compgen -G "$1" | wc -l; }

finish_case() {
    if (( CASE_OK )); then
        echo "${G}✓${N} $1"; PASSES=$((PASSES + 1))
    else
        echo "${R}✗${N} $1 (exit $STATUS)"; FAILURES=$((FAILURES + 1))
        sed 's/^/      | /' <<<"$OUTPUT"
    fi
    CASE_OK=1
}

echo "${B}[selftest] pg-dump.sh${N}"

# --- 1. a confirmed push prunes the remote by the date in the name ---------

setup_case prune
old_z="zitadel-$(day 40)-031501.sql.gz"
old_b="bibleget_dev-$(day 20)-031501.sql.gz"
new_b="bibleget_dev-$(day 5)-031501.sql.gz"
for f in "$old_z" "$old_b" "$new_b" backup_2610130003.tar "otherdb-$(day 40)-031501.sql.gz"; do
    echo data > "$(remote "$f")"
done
run_script RETENTION_DAYS=14
check "exits 0" expect_status 0
check "old zitadel dump pruned" test ! -e "$(remote "$old_z")"
check "old bibleget_dev dump pruned" test ! -e "$(remote "$old_b")"
check "recent bibleget_dev dump kept" test -e "$(remote "$new_b")"
check "Plesk's own archive untouched" test -e "$(remote backup_2610130003.tar)"
check "a database this script does not dump is untouched" test -e "$(remote "otherdb-$(day 40)-031501.sql.gz")"
check "tonight's large dump is on the remote" test "$(count "$(remote 'bibleget_dev-*')")" = 2
check "tonight's large dump removed locally" test "$(count "$(local_ 'bibleget_dev-*')")" = 0
check "reports the prune" output_has "pruned 2 remote file(s)"
finish_case "a confirmed push prunes remote dumps older than the retention window"

# --- 2. REMOTE_RETENTION_DAYS=0 disables the remote prune ------------------

setup_case keep
echo data > "$(remote "$old_z")"
run_script REMOTE_RETENTION_DAYS=0
check "exits 0" expect_status 0
check "old remote dump kept" test -e "$(remote "$old_z")"
finish_case "REMOTE_RETENTION_DAYS=0 keeps the remote history"

# --- 3. a truncated upload is caught by size -------------------------------

setup_case truncate
echo data > "$(remote "$old_z")"
run_script STUB_TRUNCATE=bibleget_dev
check "exits non-zero" expect_status 1
check "names the size mismatch" output_has "size mismatch"
check "large dump kept locally" test "$(count "$(local_ 'bibleget_dev-*')")" = 1
check "remote not pruned after an unconfirmed push" test -e "$(remote "$old_z")"
finish_case "an upload the remote truncated is not reported as a backup"

# --- 4. a failing push cannot pile up large dumps locally ------------------

setup_case backlog
for d in 3 2 1; do echo data > "$(local_ "bibleget_dev-$(day "$d")-031501.sql.gz")"; done
echo data > "$(local_ "bibleget_dev_archive-$(day 3)-031501.sql.gz")"
run_script STUB_FAIL_PUT=1 LARGE_KEEP_UNPUSHED=2
check "exits non-zero" expect_status 1
check "two bibleget_dev dumps left locally" test "$(count "$(local_ 'bibleget_dev-*')")" = 2
check "the newest unpushed one is kept" test -e "$(local_ "bibleget_dev-$(day 1)-031501.sql.gz")"
check "an older one was removed" test ! -e "$(local_ "bibleget_dev-$(day 3)-031501.sql.gz")"
check "a database sharing the prefix is untouched" test -e "$(local_ "bibleget_dev_archive-$(day 3)-031501.sql.gz")"
check "tonight's dump was still taken" test "$(count "$(local_ 'zitadel-*')")" = 1
check "says what it removed" output_has "unpushed"
finish_case "unpushed large dumps are capped at LARGE_KEEP_UNPUSHED"

# --- 5. a failed remote prune is noisy but does not undo the push ----------

setup_case rmfail
echo data > "$(remote "$old_z")"
run_script STUB_FAIL_RM=1
check "exits non-zero" expect_status 1
check "names the failure" output_has "remote prune FAILED"
check "large dump still removed locally (its copy was confirmed)" test "$(count "$(local_ 'bibleget_dev-*')")" = 0
finish_case "a failed remote prune exits non-zero after finishing local cleanup"

echo
if (( FAILURES )); then
    echo "${R}[selftest] $FAILURES failed, $PASSES passed${N}"
    exit 1
fi
echo "${G}[selftest] all $PASSES cases passed${N}"
