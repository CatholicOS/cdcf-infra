#!/usr/bin/env bash
#
# setup-openfga.sh — bootstrap and idempotent provisioning for cdcf-infra OpenFGA.
#
# Creates a store and uploads its authorization model. Model files live in
# auth/models/<store-name>.json — the store name is the file basename.
#
# Actions:
#   --create-store NAME    Create store NAME if it doesn't exist, then upload
#                          auth/models/NAME.json as the latest model. Idempotent:
#                          skips upload if the model already matches what's there.
#   --create-litcal-store  Shorthand for `--create-store LiturgicalCalendar`.
#
# Usage:
#   ./setup-openfga.sh --target production --create-litcal-store
#   ./setup-openfga.sh --target production --create-store LiturgicalCalendar
#
# Requires: bash >= 4, curl, jq.

set -euo pipefail

# --- args -----------------------------------------------------------------

TARGET=""
ACTIONS=()
SINGLE_STORE=""

usage() {
    cat >&2 <<EOF
Usage: $0 --target {local,production} ACTION [ACTION ...]

Actions:
  --create-store NAME       Create store NAME + upload auth/models/NAME.json
  --create-litcal-store     Shorthand for --create-store LiturgicalCalendar

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
        --create-store)         ACTIONS+=("create-store"); SINGLE_STORE="$2"; shift 2 ;;
        --create-litcal-store)  ACTIONS+=("create-litcal-store"); shift ;;
        -h|--help)              usage ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
    esac
done

[[ -z "$TARGET" || ${#ACTIONS[@]} -eq 0 ]] && usage

case "$TARGET" in
    local)      ENV_FILE="${ENV_FILE:-.env.local}" ;;
    production) ENV_FILE="${ENV_FILE:-.env.production}" ;;
    *) echo "Unknown target: $TARGET" >&2; usage ;;
esac

[[ ! -f "$ENV_FILE" ]] && { echo "Env file not found: $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

[[ -z "${OPENFGA_PRESHARED_KEY:-}" ]] && { echo "OPENFGA_PRESHARED_KEY missing in $ENV_FILE" >&2; exit 1; }

# --- config ---------------------------------------------------------------

OPENFGA_API_URL="${OPENFGA_API_URL:-https://authz.catholicdigitalcommons.org}"
OPENFGA_INTERNAL_URL="${OPENFGA_INTERNAL_URL:-http://127.0.0.1:8081}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="${SCRIPT_DIR}/models"

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

create_or_find_store() {
    local name="$1"
    local existing_id
    existing_id=$(fga GET /stores | jq -r --arg n "$name" '.stores[]? | select(.name == $n) | .id // empty' | head -1)
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

upload_model_if_changed() {
    local store_id="$1" model_file="$2"
    [[ ! -f "$model_file" ]] && { err "Model file not found: $model_file"; exit 4; }

    log "Checking current model in store"
    local existing_models
    existing_models=$(fga GET "/stores/${store_id}/authorization-models")
    local existing_model_id
    existing_model_id=$(echo "$existing_models" | jq -r '.authorization_models[0]?.id // empty')

    if [[ -n "$existing_model_id" ]]; then
        # Normalize both sides to compare (strip empty/null fields the server adds).
        local normalize='walk(if type == "object" then with_entries(select(.value != "" and .value != null and .value != {})) else . end)'
        local server_model file_model
        server_model=$(echo "$existing_models" | jq -cS ".authorization_models[0].type_definitions | $normalize")
        file_model=$(jq -cS ".type_definitions | $normalize" "$model_file")
        if [[ "$server_model" == "$file_model" ]]; then
            ok "Model unchanged ($existing_model_id) — no upload needed"
            echo "$existing_model_id"
            return 0
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
    echo "$model_id"
}

do_create_store() {
    local name="$1"
    local model_file="${MODELS_DIR}/${name}.json"
    log "Provisioning store '$name' (model: $model_file)"

    local store_id model_id
    store_id=$(create_or_find_store "$name")
    model_id=$(upload_model_if_changed "$store_id" "$model_file")

    echo
    echo "${B}=== $name handoff values ===${N}"
    echo "OPENFGA_API_URL=$OPENFGA_API_URL"
    echo "OPENFGA_STORE_ID=$store_id"
    echo "OPENFGA_MODEL_ID=$model_id"
    echo "# OPENFGA_PRESHARED_KEY: deliver out-of-band; never put in handoff doc"
    echo
}

# --- main -----------------------------------------------------------------

log "Target: $TARGET (api: $OPENFGA_API_URL, internal: $OPENFGA_INTERNAL_URL)"

for action in "${ACTIONS[@]}"; do
    case "$action" in
        create-store)         do_create_store "$SINGLE_STORE" ;;
        create-litcal-store)  do_create_store "LiturgicalCalendar" ;;
    esac
done

log "Done."
