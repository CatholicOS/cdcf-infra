#!/usr/bin/env bash
#
# setup-openfga.sh — bootstrap and idempotent provisioning for cdcf-infra OpenFGA.
#
# Stores are per-property (one OpenFGA store per consumer that uses
# relationship-based authz). Phase 1 creates the liturgical_calendar
# store and seeds LitCal's authorization model.
#
# Usage:
#   ./setup-openfga.sh --target production --create-store <slug>
#       Creates a store with the given slug if it doesn't exist.
#       Looks for an authorization model at ./models/<slug>.fga (DSL) or
#       ./models/<slug>.json and applies it as the latest model.
#
# Implementation status: SKELETON. The store-and-model API wiring is the
# next commit. Until then, this is documentation + a no-op runner.

set -euo pipefail

TARGET=""
ACTION=""
ARG=""

usage() {
    cat >&2 <<EOF
Usage: $0 --target {local,production} --create-store SLUG
EOF
    exit 64
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --create-store) ACTION="create-store"; ARG="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
    esac
done

[[ -z "$TARGET" || -z "$ACTION" || -z "$ARG" ]] && usage

case "$TARGET" in
    local)      ENV_FILE=".env.local" ;;
    production) ENV_FILE=".env.production" ;;
    *) echo "Unknown target: $TARGET" >&2; usage ;;
esac

[[ ! -f "$ENV_FILE" ]] && { echo "Env file not found: $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

OPENFGA_API="${OPENFGA_API_URL:-https://authz.catholicdigitalcommons.org}"

[[ -z "${OPENFGA_PRESHARED_KEY:-}" ]] && {
    echo "OPENFGA_PRESHARED_KEY missing from $ENV_FILE" >&2; exit 1
}

openfga_api() {
    local method="$1" path="$2" body="${3:-}"
    local url="${OPENFGA_API}${path}"
    if [[ -n "$body" ]]; then
        curl -sS -X "$method" "$url" \
            -H "Authorization: Bearer ${OPENFGA_PRESHARED_KEY}" \
            -H 'Content-Type: application/json' \
            -d "$body"
    else
        curl -sS -X "$method" "$url" \
            -H "Authorization: Bearer ${OPENFGA_PRESHARED_KEY}" \
            -H 'Content-Type: application/json'
    fi
}

create_store() {
    local slug="$1"
    local model_file="models/${slug}.fga"
    local model_json="models/${slug}.json"

    # TODO: implement
    #  1. List stores; create the named store if absent (POST /stores).
    #  2. Load the authz model from models/<slug>.{fga,json}.
    #  3. POST /stores/{id}/authorization-models to upload the model.
    #  4. Emit non-secret store_id + model_id values into the handoff doc.
    echo "[skeleton] would create OpenFGA store: $slug"
    if [[ -f "$model_file" || -f "$model_json" ]]; then
        echo "[skeleton] would apply model from: $(ls models/${slug}.{fga,json} 2>/dev/null)"
    else
        echo "[skeleton] WARNING: no model file at $model_file or $model_json — store will be empty"
    fi
}

case "$ACTION" in
    create-store) create_store "$ARG" ;;
esac
