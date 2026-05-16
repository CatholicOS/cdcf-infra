#!/usr/bin/env bash
#
# setup-zitadel.sh — bootstrap and idempotent provisioning for cdcf-infra Zitadel.
#
# Reads credentials from .env.production (on the VPS) or .env.local (for
# pointing a dev-side script at a remote Zitadel). The PAT is loaded from
# the Zitadel data dir's automation-user.pat file written on first boot.
#
# Mirrors the --target {local,production} convention from
# cdcf-website/scripts/cdcf_api.py.
#
# Usage:
#   ./setup-zitadel.sh --target production --create-orgs
#       Creates Orgs: CDCF, LiturgicalCalendar, BibleGet, OntoKit
#       (idempotent — skip Orgs that already exist).
#
#   ./setup-zitadel.sh --target production --create-org <NAME>
#       Creates a single Org if it doesn't exist.
#
#   ./setup-zitadel.sh --target production --provision-litcal
#       Under the LiturgicalCalendar Org, creates the LiturgicalCalendarAPI
#       Project + OIDC API app + roles. Writes non-secret values to
#       ./handoffs/liturgicalcalendar.md.
#
# Implementation status: SKELETON. The Org list and provisioning logic
# below are the canonical specs; the actual API-call wiring is the next
# commit. Until then, treat this as documentation + a no-op runner.

set -euo pipefail

TARGET=""
ACTION=""
ARG=""

usage() {
    cat >&2 <<EOF
Usage: $0 --target {local,production} {--create-orgs | --create-org NAME | --provision-litcal}
EOF
    exit 64
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --create-orgs) ACTION="create-orgs"; shift ;;
        --create-org) ACTION="create-org"; ARG="$2"; shift 2 ;;
        --provision-litcal) ACTION="provision-litcal"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
    esac
done

[[ -z "$TARGET" || -z "$ACTION" ]] && usage

case "$TARGET" in
    local)      ENV_FILE=".env.local" ;;
    production) ENV_FILE=".env.production" ;;
    *) echo "Unknown target: $TARGET" >&2; usage ;;
esac

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Env file not found: $ENV_FILE" >&2
    exit 1
fi

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

# Discover Zitadel issuer + PAT. In production the issuer is read from
# config (or hardcoded to auth.catholicdigitalcommons.org); the PAT lives
# on the local VPS filesystem in the bind-mounted data dir.
ZITADEL_ISSUER="${ZITADEL_ISSUER:-https://auth.catholicdigitalcommons.org}"
PAT_FILE="${PAT_FILE:-/var/lib/cdcf-auth/zitadel-data/automation-user.pat}"

if [[ ! -r "$PAT_FILE" ]]; then
    echo "PAT file not readable: $PAT_FILE" >&2
    echo "Bring the stack up first; the PAT is written on first boot." >&2
    exit 2
fi

PAT="$(cat "$PAT_FILE")"
[[ -z "$PAT" ]] && { echo "PAT file is empty" >&2; exit 2; }

# Canonical Org list for the umbrella (per project_zitadel_umbrella_architecture).
ORG_NAMES=(CDCF LiturgicalCalendar BibleGet OntoKit)

zitadel_api() {
    # zitadel_api METHOD PATH [JSON_BODY]
    local method="$1" path="$2" body="${3:-}"
    local url="${ZITADEL_ISSUER}${path}"
    if [[ -n "$body" ]]; then
        curl -sS -X "$method" "$url" \
            -H "Authorization: Bearer $PAT" \
            -H 'Content-Type: application/json' \
            -d "$body"
    else
        curl -sS -X "$method" "$url" \
            -H "Authorization: Bearer $PAT" \
            -H 'Content-Type: application/json'
    fi
}

create_org() {
    local name="$1"
    # TODO: implement against POST /management/v1/orgs
    #       https://zitadel.com/docs/apis/resources/mgmt/management-service-add-org
    # Idempotency: list orgs first; skip if name already present.
    echo "[skeleton] would create Org: $name (via $ZITADEL_ISSUER)"
}

provision_litcal() {
    # TODO: implement
    #  1. Find LiturgicalCalendar Org ID
    #  2. POST /management/v1/projects with name=LiturgicalCalendarAPI
    #  3. POST /management/v1/projects/{id}/apps/api  with auth_method_type=API_AUTH_METHOD_TYPE_PRIVATE_KEY_JWT
    #  4. POST /management/v1/projects/{id}/roles for each role key
    #  5. Emit handoffs/liturgicalcalendar.md with issuer, project ID, client ID
    echo "[skeleton] would provision LiturgicalCalendarAPI under LiturgicalCalendar org"
}

case "$ACTION" in
    create-orgs)
        for org in "${ORG_NAMES[@]}"; do create_org "$org"; done
        ;;
    create-org)
        create_org "$ARG"
        ;;
    provision-litcal)
        provision_litcal
        ;;
esac
