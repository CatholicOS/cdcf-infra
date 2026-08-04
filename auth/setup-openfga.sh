#!/usr/bin/env bash
#
# setup-openfga.sh — bootstrap and idempotent provisioning for cdcf-infra OpenFGA.
#
# Creates a store, uploads its authorization model, and seeds its structural
# tuples. Model files live in auth/models/<store-name>.json — the store name is
# the file basename. Optional structural tuples live alongside as
# auth/models/<store-name>.tuples.json.
#
# Actions:
#   --create-store NAME    Create store NAME if it doesn't exist, then upload
#                          auth/models/NAME.json as the latest model, then seed
#                          auth/models/NAME.tuples.json if that file exists.
#                          Idempotent: skips upload if the model already matches
#                          what's there, and writes only tuples not already in
#                          the store.
#   --create-litcal-store  Shorthand for `--create-store LiturgicalCalendar`.
#   --create-martyrology-store
#                          Shorthand for `--create-store Martyrology`.
#   --seed-tuples NAME     Seed auth/models/NAME.tuples.json into the existing
#                          store NAME, without touching the model. Use after
#                          editing a tuples file. Fails if the store, its model,
#                          or the tuples file is missing.
#   --force-model-upload   Override the lock-file guard (see auth/models/*.lock.json).
#                          Without it, a store whose latest model was not uploaded by
#                          this repo is left alone and the run exits non-zero. The
#                          script never writes a lock file itself — it reports the
#                          JSON to commit via PR whenever one needs to change.
#
# Structural tuples only: a `.tuples.json` file carries wiring the model is
# useless without (for Martyrology, `edition → governed_by → governance_body`).
# Human role grants (`user:<sub>` → reader/editor/admin on a governance_body)
# are NOT seeded here — they are per-person operator actions; see
# handoffs/martyrology.md. This script never deletes tuples: tuples in the store
# that are absent from the file are reported as drift and left alone.
#
# Usage:
#   ./setup-openfga.sh --target production --create-litcal-store
#   ./setup-openfga.sh --target production --create-martyrology-store
#   ./setup-openfga.sh --target production --create-store LiturgicalCalendar
#   ./setup-openfga.sh --target production --seed-tuples Martyrology
#
# Requires: bash >= 4, curl, jq.

set -euo pipefail

# --- args -----------------------------------------------------------------

TARGET=""
ACTIONS=()
FORCE_MODEL_UPLOAD="false"
# Store names ride along inside each ACTIONS entry ("create-store:NAME") rather
# than in shared scalars: with one SINGLE_STORE/SEED_STORE variable, a second
# --create-store overwrote the first and the same store was provisioned twice
# while the earlier name was silently dropped.

usage() {
    cat >&2 <<EOF
Usage: $0 --target {local,staging,production} ACTION [ACTION ...]

Targets:
  local       Separate local OpenFGA (own compose stack), via .env.local
  staging     Production OpenFGA, via .env.staging
  production  Production OpenFGA, via .env.production

Actions:
  --create-store NAME       Create store NAME + upload auth/models/NAME.json
                            + seed auth/models/NAME.tuples.json if present
  --create-litcal-store     Shorthand for --create-store LiturgicalCalendar
  --create-martyrology-store
                            Shorthand for --create-store Martyrology
  --seed-tuples NAME        Seed auth/models/NAME.tuples.json into the existing
                            store NAME (no model upload)
  --force-model-upload      Upload the model file even when the store's latest model
                            is not the one recorded in auth/models/NAME.lock.json
                            (i.e. someone uploaded out-of-band). Off by default.

Environment variables (sourced from .env.\$target):
  OPENFGA_API_URL           (default: https://authz.catholicdigitalcommons.org)
  OPENFGA_INTERNAL_URL      (default: http://127.0.0.1:8081)
  OPENFGA_PRESHARED_KEY     (required — Bearer for HTTP API auth)
EOF
    exit 64
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)               TARGET="$2"; shift 2 ;;
        --create-store)         [[ $# -ge 2 ]] || usage; ACTIONS+=("create-store:$2"); shift 2 ;;
        --create-litcal-store)  ACTIONS+=("create-litcal-store"); shift ;;
        --create-martyrology-store) ACTIONS+=("create-martyrology-store"); shift ;;
        --seed-tuples)          [[ $# -ge 2 ]] || usage; ACTIONS+=("seed-tuples:$2"); shift 2 ;;
        --force-model-upload)   FORCE_MODEL_UPLOAD="true"; shift ;;
        -h|--help)              usage ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
    esac
done

[[ -z "$TARGET" || ${#ACTIONS[@]} -eq 0 ]] && usage

case "$TARGET" in
    local)      ENV_FILE="${ENV_FILE:-.env.local}" ;;
    staging)    ENV_FILE="${ENV_FILE:-.env.staging}" ;;
    production) ENV_FILE="${ENV_FILE:-.env.production}" ;;
    *) echo "Unknown target: $TARGET" >&2; usage ;;
esac

[[ ! -f "$ENV_FILE" ]] && { echo "Env file not found: $ENV_FILE" >&2; exit 1; }
# The directive has to sit immediately above `source` itself. On a compound
# line it binds to the first command (`set -a`) and never reaches `source`, so
# SC1090 fired here despite the disable being present.
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

[[ -z "${OPENFGA_PRESHARED_KEY:-}" ]] && { echo "OPENFGA_PRESHARED_KEY missing in $ENV_FILE" >&2; exit 1; }

# --- config ---------------------------------------------------------------

OPENFGA_API_URL="${OPENFGA_API_URL:-https://authz.catholicdigitalcommons.org}"
OPENFGA_INTERNAL_URL="${OPENFGA_INTERNAL_URL:-http://127.0.0.1:8081}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="${SCRIPT_DIR}/models"

# OpenFGA's default max tuples per write request is 100, and a write is
# transactional — chunk well under the cap so a large seed file still applies.
TUPLE_WRITE_CHUNK=50
# Page size for reading existing tuples back (OpenFGA caps page_size at 100).
TUPLE_READ_PAGE=100
# Hard stop on the read pagination loop, so a server that keeps handing back
# a continuation token can never spin forever.
TUPLE_READ_MAX_PAGES=1000

if [[ -t 1 ]]; then
    R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; B=$'\033[0;34m'; N=$'\033[0m'
else
    R=""; G=""; Y=""; B=""; N=""
fi

log()  { echo "${B}[setup-openfga]${N} $*" >&2; }
ok()   { echo "${G}    ✓${N} $*" >&2; }
warn() { echo "${Y}    ⚠${N} $*" >&2; }
err()  { echo "${R}    ✗${N} $*" >&2; }

# --- API helper -----------------------------------------------------------

# fga METHOD PATH [BODY_JSON]
fga() {
    local method="$1" path="$2" body="${3:-}"
    if [[ -n "$body" ]]; then
        curl -sS -X "$method" "${OPENFGA_INTERNAL_URL}${path}" \
            -H "Authorization: Bearer $OPENFGA_PRESHARED_KEY" \
            -H "Content-Type: application/json" \
            -d "$body"
    else
        curl -sS -X "$method" "${OPENFGA_INTERNAL_URL}${path}" \
            -H "Authorization: Bearer $OPENFGA_PRESHARED_KEY" \
            -H "Content-Type: application/json"
    fi
}

# --- actions --------------------------------------------------------------

# find_store_id NAME -> store id on stdout, empty if the store does not exist.
# OpenFGA does NOT enforce unique store names, so a name can legitimately match
# more than one store (two provisioning runs racing, or a store created by hand).
# Silently taking the first match would upload a model into one store and seed
# tuples into it while the handoff records whichever id happened to sort first —
# a split-brain that is invisible until a Check returns the wrong answer. Refuse
# to guess instead.
find_store_id() {
    local name="$1" ids count
    ids=$(fga GET /stores | jq -r --arg n "$name" '.stores[]? | select(.name == $n) | .id // empty')
    count=$(printf '%s' "$ids" | grep -c . || true)
    if [[ "$count" -gt 1 ]]; then
        err "Found $count stores named '$name'; refusing to guess which to use:"
        printf '%s\n' "$ids" | sed 's/^/        /' >&2
        err "Delete the duplicates, or point the script at a uniquely-named store."
        exit 8
    fi
    printf '%s' "$ids"
}

# latest_model_id STORE_ID -> id of the store's current model, empty if none.
latest_model_id() {
    local store_id="$1"
    fga GET "/stores/${store_id}/authorization-models" | jq -r '.authorization_models[0]?.id // empty'
}

create_or_find_store() {
    local name="$1"
    local existing_id
    existing_id=$(find_store_id "$name")
    if [[ -n "$existing_id" ]]; then
        ok "Store already exists: $name ($existing_id)"
        echo "$existing_id"
        return 0
    fi
    log "Creating store: $name"
    local result
    result=$(fga POST /stores "{\"name\":\"$name\"}")
    local store_id
    store_id=$(echo "$result" | jq -r '.id // empty')
    if [[ -z "$store_id" ]]; then
        err "Failed to create store: $result"
        exit 3
    fi
    ok "Created store: $name ($store_id)"
    echo "$store_id"
}

# --- model lock ------------------------------------------------------------
#
# auth/models/<name>.lock.json records the model ID THIS repo last uploaded to
# the store. Under centralized ownership (see docs/superpowers/specs/
# 2026-08-04-openfga-model-ownership-and-upgrade-design.md) cdcf-infra is the
# only writer of models, so a store whose latest model ID is not the recorded
# one means someone uploaded out-of-band. Uploading over that would silently
# revert their work — which is exactly what nearly happened to the
# LiturgicalCalendar store on 2026-08-04 — so we refuse instead.
#
# Three fields only. No timestamp or commit hash: the lock file is committed,
# so `git log auth/models/<name>.lock.json` is the provenance record.
#
# This script never WRITES a lock file — it only reads one. On the production
# VPS, auth/models/ is a git checkout owned by cdcfinfra-deploy and synced via
# `git pull --ff-only`, while the provisioner runs as ubuntu: it cannot write
# there, and even if it could, writing a tracked file into that checkout would
# dirty it and break the next sync. When this repo's action changes what a
# lock file should say, it reports the JSON on stderr for a human to commit
# via a PR instead of writing it directly.
#
# A lock file's `store_id` scopes it to one store. Model IDs are meaningless
# across stores — a local dev store and production can hold byte-identical
# models under completely different IDs — so a lock recorded for a store_id
# other than the one currently being provisioned is not applicable here: the
# guard is skipped and no lock update is reported. Without this, the
# production lock committed to the repo would make every local dev stack's
# second provisioning run refuse, since the local store's (freshly generated)
# model ID never matches production's.

lock_file_for() {
    echo "${MODELS_DIR}/${1}.lock.json"
}

read_lock_model_id() {
    local lock; lock=$(lock_file_for "$1")
    [[ -f "$lock" ]] || { echo ""; return 0; }
    jq -r '.model_id // empty' "$lock" 2>/dev/null || echo ""
}

read_lock_store_id() {
    local lock; lock=$(lock_file_for "$1")
    [[ -f "$lock" ]] || { echo ""; return 0; }
    jq -r '.store_id // empty' "$lock" 2>/dev/null || echo ""
}

# report_lock_update NAME STORE_ID MODEL_ID
#
# Prints (to stderr) the lock file content that should be committed for NAME.
# Never writes to disk — see the comment block above.
report_lock_update() {
    local name="$1" store_id="$2" model_id="$3"
    local lock_name; lock_name=$(basename "$(lock_file_for "$name")")
    warn "Lock out of date — commit this via PR to auth/models/${lock_name}:"
    jq -n --arg n "$name" --arg s "$store_id" --arg m "$model_id" \
        '{store_name: $n, store_id: $s, model_id: $m}' >&2
}

upload_model_if_changed() {
    local store_id="$1" model_file="$2" name="$3"
    [[ ! -f "$model_file" ]] && { err "Model file not found: $model_file"; exit 4; }

    log "Checking current model in store"
    local existing_models
    existing_models=$(fga GET "/stores/${store_id}/authorization-models")
    local existing_model_id
    existing_model_id=$(echo "$existing_models" | jq -r '.authorization_models[0]?.id // empty')

    # lock_foreign: true when a lock file exists for $name but was recorded
    # against a different store_id — i.e. it belongs to another environment
    # (typically production) and says nothing about the store we're
    # provisioning right now. Treated as if no lock existed for THIS store:
    # the guard is skipped and no lock update is ever reported for it. Computed
    # up front (not just when a model already exists) so the same rule governs
    # whether the very first upload to a brand-new store gets reported too.
    local lock_foreign="false"
    local locked_model_id; locked_model_id=$(read_lock_model_id "$name")
    local locked_store_id; locked_store_id=$(read_lock_store_id "$name")
    if [[ -n "$locked_store_id" && "$locked_store_id" != "$store_id" ]]; then
        lock_foreign="true"
        log "Lock file for '$name' is scoped to store $locked_store_id, not $store_id — not applicable here, skipping the lock guard"
        locked_model_id=""
    fi

    if [[ -n "$existing_model_id" ]]; then
        if [[ -n "$locked_model_id" && "$locked_model_id" != "$existing_model_id" ]]; then
            if [[ "$FORCE_MODEL_UPLOAD" == "true" ]]; then
                warn "Store's latest model ($existing_model_id) is not the locked one ($locked_model_id) — proceeding anyway (--force-model-upload)"
            else
                err "Refusing to touch the model for store '$name'."
                err "  store's latest: $existing_model_id"
                err "  lock file says: $locked_model_id"
                err "Someone uploaded a model outside this repo. Uploading now would revert it."
                err "Resolve by syncing $(basename "$model_file") from the source of truth and updating"
                err "$(basename "$(lock_file_for "$name")"), or re-run with --force-model-upload if you"
                err "really mean to replace the deployed model."
                exit 7
            fi
        fi
        # Normalize both sides to compare (strip empty/null fields the server
        # adds: "metadata": null, "relations": {}, "module": "", "condition": "").
        #
        # `.key == "this"` is load-bearing. In an OpenFGA model, {"this": {}} is
        # the direct-assignment userset — a relation's entire meaning. Without
        # the exemption, `select(.value != {})` strips the "this" key, leaving
        # {}, which the same rule then strips from the relation map, which then
        # empties `relations` and strips that too. Every `[user]` relation
        # disappears from the comparison: LiturgicalCalendar normalized to types
        # with NO relations at all, and Martyrology lost `governed_by` and
        # `governance_body.admin`. Deleting `governed_by` from the file compared
        # EQUAL to the server and silently never uploaded.
        local normalize='walk(if type == "object" then with_entries(select(.value != null and .value != "" and (.value != {} or .key == "this"))) else . end)'
        local server_model file_model
        server_model=$(echo "$existing_models" | jq -cS ".authorization_models[0].type_definitions | $normalize")
        file_model=$(jq -cS ".type_definitions | $normalize" "$model_file")
        if [[ "$server_model" == "$file_model" ]]; then
            ok "Model unchanged ($existing_model_id) — no upload needed"
            if [[ "$lock_foreign" != "true" && "$locked_model_id" != "$existing_model_id" ]]; then
                report_lock_update "$name" "$store_id" "$existing_model_id"
            fi
            echo "$existing_model_id"
            return 0
        fi
        if [[ -z "$locked_model_id" && "$FORCE_MODEL_UPLOAD" != "true" ]]; then
            err "No lock file for store '$name' and the model file differs from the store's latest ($existing_model_id)."
            err "This repo has no record of uploading that model, so it cannot tell an intended"
            err "update from a stale file. Sync the file and re-run (an identical file adopts the"
            err "lock silently), or pass --force-model-upload to upload this file as the new model."
            exit 7
        fi
        warn "Model differs from file — uploading new version"
    else
        log "No existing model — uploading first version"
    fi

    local payload
    payload=$(jq -c '.' "$model_file")
    local result
    result=$(fga POST "/stores/${store_id}/authorization-models" "$payload")
    local model_id
    model_id=$(echo "$result" | jq -r '.authorization_model_id // empty')
    if [[ -z "$model_id" ]]; then
        err "Failed to upload model: $result"
        exit 5
    fi
    ok "Uploaded model: $model_id"
    [[ "$lock_foreign" == "true" ]] || report_lock_update "$name" "$store_id" "$model_id"
    echo "$model_id"
}

# read_all_tuples STORE_ID -> JSON array of {user,relation,object} on stdout.
# Pages through POST /stores/{id}/read until the continuation token is exhausted.
read_all_tuples() {
    local store_id="$1"
    local token="" prev_token="" page page_tuples body
    local acc="[]"
    local pages=0

    while :; do
        pages=$((pages + 1))
        if [[ $pages -gt $TUPLE_READ_MAX_PAGES ]]; then
            err "Read pagination exceeded ${TUPLE_READ_MAX_PAGES} pages — refusing to continue"
            exit 7
        fi
        body=$(jq -cn --argjson ps "$TUPLE_READ_PAGE" --arg t "$token" \
            'if $t == "" then {page_size:$ps} else {page_size:$ps, continuation_token:$t} end')
        if ! page=$(fga POST "/stores/${store_id}/read" "$body"); then
            err "Read request failed (transport) against store ${store_id}"
            exit 7
        fi
        # A non-200 from OpenFGA still comes back as a 200-shaped curl success,
        # so the body — not the exit status — is what proves the read worked.
        if ! page_tuples=$(echo "$page" | jq -ce '[.tuples[]? | .key | {user, relation, object}]' 2>/dev/null) \
           || ! echo "$page" | jq -e 'has("tuples")' >/dev/null 2>&1; then
            err "Read returned an unexpected body: $page"
            exit 7
        fi
        acc=$(jq -cn --argjson a "$acc" --argjson b "$page_tuples" '$a + $b')

        prev_token="$token"
        token=$(echo "$page" | jq -r '.continuation_token // empty')
        [[ -z "$token" ]] && break
        if [[ "$token" == "$prev_token" ]]; then
            err "Read pagination stalled — server repeated continuation token"
            exit 7
        fi
    done

    echo "$acc"
}

# seed_tuples_if_present STORE_ID MODEL_ID NAME
#
# Applies auth/models/NAME.tuples.json idempotently. A missing file is a no-op
# (stores without structural tuples are unaffected); a malformed file is fatal —
# a silently skipped seed leaves the model inert, which is the failure this
# guards against.
seed_tuples_if_present() {
    local store_id="$1" model_id="$2" name="$3"
    local tuples_file="${MODELS_DIR}/${name}.tuples.json"

    if [[ ! -f "$tuples_file" ]]; then
        log "No tuples file at ${tuples_file} — nothing to seed for '$name'"
        return 0
    fi

    log "Seeding structural tuples from ${tuples_file}"

    # --- validate the file, loudly ---------------------------------------
    if ! jq -e . "$tuples_file" >/dev/null 2>&1; then
        err "Tuples file is not valid JSON: $tuples_file"
        exit 6
    fi
    if ! jq -e '(.tuples | type) == "array"' "$tuples_file" >/dev/null 2>&1; then
        err "Tuples file has no '.tuples' array: $tuples_file"
        exit 6
    fi
    local bad_count
    bad_count=$(jq '[.tuples[] | select(
        (.user     | type) != "string" or .user     == "" or
        (.relation | type) != "string" or .relation == "" or
        (.object   | type) != "string" or .object   == ""
    )] | length' "$tuples_file")
    if [[ "$bad_count" != "0" ]]; then
        err "$bad_count entr(y|ies) in $tuples_file lack a non-empty user/relation/object"
        jq -r '.tuples[] | select(
            (.user     | type) != "string" or .user     == "" or
            (.relation | type) != "string" or .relation == "" or
            (.object   | type) != "string" or .object   == ""
        ) | "        " + tojson' "$tuples_file" >&2
        exit 6
    fi

    local desired_count
    desired_count=$(jq '.tuples | length' "$tuples_file")
    if [[ "$desired_count" -eq 0 ]]; then
        warn "Tuples file declares an empty tuple list — nothing to seed"
        return 0
    fi

    # --- diff against what is already in the store -----------------------
    # OpenFGA rejects a write of an already-existing tuple, and writes are
    # transactional, so one duplicate would fail the whole batch. Read first,
    # write only the difference.
    local existing_json
    existing_json=$(read_all_tuples "$store_id")

    local key_expr='"\(.user)|\(.relation)|\(.object)"'
    local missing_json
    missing_json=$(jq -c -n --argjson existing "$existing_json" --slurpfile f "$tuples_file" "
        (\$existing | map({(${key_expr}): true}) | add // {}) as \$seen
        | [ \$f[0].tuples[] | {user, relation, object}
            | select(\$seen[${key_expr}] != true) ]")

    local missing_count
    missing_count=$(echo "$missing_json" | jq 'length')

    if [[ "$missing_count" -eq 0 ]]; then
        ok "All ${desired_count} structural tuple(s) already present — nothing to write"
    else
        local written=0 i payload result
        for (( i = 0; i < missing_count; i += TUPLE_WRITE_CHUNK )); do
            payload=$(echo "$missing_json" | jq -c \
                --argjson s "$i" --argjson c "$TUPLE_WRITE_CHUNK" --arg m "$model_id" \
                '{writes: {tuple_keys: .[$s : $s + $c]}, authorization_model_id: $m}')
            if ! result=$(fga POST "/stores/${store_id}/write" "$payload"); then
                err "Tuple write failed (transport) against store ${store_id}"
                exit 7
            fi
            # A successful write returns `{}`. Anything with a `code`/`message`
            # is an OpenFGA error delivered with a non-2xx status — curl -sS
            # exits 0 on those, so the body has to be inspected explicitly.
            if ! echo "$result" | jq -e . >/dev/null 2>&1 \
               || [[ -n "$(echo "$result" | jq -r '.code // .message // empty')" ]]; then
                err "Tuple write rejected by OpenFGA: $result"
                exit 7
            fi
            written=$((written + $(echo "$missing_json" | jq --argjson s "$i" --argjson c "$TUPLE_WRITE_CHUNK" '.[$s : $s + $c] | length')))
        done
        if [[ "$written" -ne "$missing_count" ]]; then
            err "Wrote ${written} tuple(s) but ${missing_count} were missing — refusing to report success"
            exit 7
        fi
        ok "Wrote ${written} new structural tuple(s) (${desired_count} declared in file)"
    fi

    # --- drift: report, never delete -------------------------------------
    # Anything this run wrote came from the file, so pre-write state is the
    # only place drift can live.
    local drift_json drift_count
    drift_json=$(jq -c -n --argjson existing "$existing_json" --slurpfile f "$tuples_file" "
        (\$f[0].tuples | map({user, relation, object})) as \$want
        | (\$want | map(.relation) | unique) as \$rels
        | (\$want | map({(${key_expr}): true}) | add // {}) as \$wantset
        | [ \$existing[]
            | select(.relation as \$r | \$rels | index(\$r))
            | select(\$wantset[${key_expr}] != true) ]")
    drift_count=$(echo "$drift_json" | jq 'length')
    if [[ "$drift_count" -gt 0 ]]; then
        warn "${drift_count} tuple(s) in the store use a relation this file manages but are absent from it:"
        echo "$drift_json" | jq -r '.[] | "        \(.user)  \(.relation)  \(.object)"' >&2
        warn "Left in place — this script never deletes tuples. Remove them deliberately if stale."
    fi
}

do_create_store() {
    local name="$1"
    local model_file="${MODELS_DIR}/${name}.json"
    log "Provisioning store '$name' (model: $model_file)"

    local store_id model_id
    store_id=$(create_or_find_store "$name")
    model_id=$(upload_model_if_changed "$store_id" "$model_file" "$name")
    seed_tuples_if_present "$store_id" "$model_id" "$name"

    echo
    echo "${B}=== $name handoff values ===${N}"
    echo "OPENFGA_API_URL=$OPENFGA_API_URL"
    echo "OPENFGA_STORE_ID=$store_id"
    echo "OPENFGA_MODEL_ID=$model_id"
    echo "# OPENFGA_PRESHARED_KEY: deliver out-of-band; never put in handoff doc"
    echo
}

do_seed_tuples() {
    local name="$1"
    local tuples_file="${MODELS_DIR}/${name}.tuples.json"
    log "Seeding tuples for store '$name' (file: $tuples_file)"

    if [[ ! -f "$tuples_file" ]]; then
        err "Tuples file not found: $tuples_file"
        exit 6
    fi

    local store_id model_id
    store_id=$(find_store_id "$name")
    if [[ -z "$store_id" ]]; then
        err "Store not found: $name — run --create-store $name first"
        exit 3
    fi
    ok "Store: $name ($store_id)"

    model_id=$(latest_model_id "$store_id")
    if [[ -z "$model_id" ]]; then
        err "Store '$name' has no authorization model — run --create-store $name first"
        exit 5
    fi
    ok "Model: $model_id"

    seed_tuples_if_present "$store_id" "$model_id" "$name"
}

# --- main -----------------------------------------------------------------

log "Target: $TARGET (api: $OPENFGA_API_URL, internal: $OPENFGA_INTERNAL_URL)"

for action in "${ACTIONS[@]}"; do
    case "${action%%:*}" in
        create-store)         do_create_store "${action#*:}" ;;
        create-litcal-store)  do_create_store "LiturgicalCalendar" ;;
        create-martyrology-store) do_create_store "Martyrology" ;;
        seed-tuples)          do_seed_tuples "${action#*:}" ;;
    esac
done

log "Done."
