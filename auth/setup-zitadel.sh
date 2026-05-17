#!/usr/bin/env bash
#
# setup-zitadel.sh — bootstrap and idempotent provisioning for cdcf-infra Zitadel.
#
# Reads credentials from .env.production (on the VPS) or .env.local (for
# pointing a dev-side script at a remote Zitadel). The automation PAT is
# loaded from the Zitadel data dir's automation-user.pat file written on
# first boot. Honors the --target {local,production} convention from
# scripts/cdcf_api.py in the cdcf-website repo.
#
# Actions:
#   --create-orgs              Create the four umbrella Orgs idempotently.
#   --create-org NAME          Create a single Org by name (idempotent).
#   --provision-litcal         Under LiturgicalCalendar Org, create the
#                              LiturgicalCalendarAPI Project + roles +
#                              the API OIDC app.
#   --provision-litcal-frontend
#                              Under the same Project, create a Web/PKCE OIDC
#                              app for the frontend, with prod + staging
#                              callbacks registered. Requires --provision-litcal
#                              to have run (or be running together).
#   --rename-bootstrap-admin   If the IAM admin user still has the legacy
#                              `<username>@<orgdomain>` suffix in its
#                              username, rename it to $ZITADEL_ADMIN_EMAIL.
#   --all                      Run --rename-bootstrap-admin, --create-orgs,
#                              --provision-litcal, --provision-litcal-frontend
#                              in sequence.
#
# Usage:
#   ./setup-zitadel.sh --target production --all
#   ./setup-zitadel.sh --target production --create-orgs
#   ./setup-zitadel.sh --target production --provision-litcal
#
# Requires: bash >= 4, curl, jq.

set -euo pipefail

# --- args -----------------------------------------------------------------

TARGET=""
ACTIONS=()
SINGLE_ORG=""

usage() {
    cat >&2 <<EOF
Usage: $0 --target {local,production} ACTION [ACTION ...]

Actions:
  --create-orgs               Create CDCF, LiturgicalCalendar, BibleGet, OntoKit (idempotent)
  --create-org NAME           Create a single Org by name (idempotent)
  --provision-litcal          Provision LitCal Project + roles + API app
  --provision-litcal-frontend Provision LitCal Frontend OIDC app (Web/PKCE)
  --rename-bootstrap-admin    Rename IAM admin user to \$ZITADEL_ADMIN_EMAIL
  --all                       Above four in dependency order

Environment variables (sourced from .env.\$target):
  ZITADEL_ISSUER                 (default: https://auth.catholicdigitalcommons.org)
  ZITADEL_INTERNAL_URL           (default: http://127.0.0.1:8080)
  ZITADEL_PAT_FILE               (default: /opt/cdcf-auth/runtime/zitadel-data/automation-user.pat)
  ZITADEL_ADMIN_EMAIL            (used by --rename-bootstrap-admin)
EOF
    exit 64
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)                    TARGET="$2"; shift 2 ;;
        --create-orgs)               ACTIONS+=("create-orgs"); shift ;;
        --create-org)                ACTIONS+=("create-org"); SINGLE_ORG="$2"; shift 2 ;;
        --provision-litcal)          ACTIONS+=("provision-litcal"); shift ;;
        --provision-litcal-frontend) ACTIONS+=("provision-litcal-frontend"); shift ;;
        --rename-bootstrap-admin)    ACTIONS+=("rename-bootstrap-admin"); shift ;;
        --all)                       ACTIONS+=("rename-bootstrap-admin" "create-orgs" "provision-litcal" "provision-litcal-frontend"); shift ;;
        -h|--help)                   usage ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
    esac
done

[[ -z "$TARGET" || ${#ACTIONS[@]} -eq 0 ]] && usage

case "$TARGET" in
    local)
        ENV_FILE="${ENV_FILE:-.env.local}"
        ZITADEL_INTERNAL_URL_DEFAULT="http://127.0.0.1:8080"
        ;;
    production)
        ENV_FILE="${ENV_FILE:-.env.production}"
        ZITADEL_INTERNAL_URL_DEFAULT="http://127.0.0.1:8080"
        ;;
    *) echo "Unknown target: $TARGET" >&2; usage ;;
esac

[[ ! -f "$ENV_FILE" ]] && { echo "Env file not found: $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

# --- config ---------------------------------------------------------------

ZITADEL_ISSUER="${ZITADEL_ISSUER:-https://auth.catholicdigitalcommons.org}"
ZITADEL_INTERNAL_URL="${ZITADEL_INTERNAL_URL:-$ZITADEL_INTERNAL_URL_DEFAULT}"
ZITADEL_PAT_FILE="${ZITADEL_PAT_FILE:-/opt/cdcf-auth/runtime/zitadel-data/automation-user.pat}"

# Public hostname presented in the Host header on internal calls (multi-instance routing).
ZITADEL_HOST=$(echo "$ZITADEL_ISSUER" | sed -E 's|^https?://||; s|/.*||')

[[ ! -r "$ZITADEL_PAT_FILE" ]] && { echo "PAT file not readable: $ZITADEL_PAT_FILE" >&2; exit 2; }
PAT="$(cat "$ZITADEL_PAT_FILE")"
[[ -z "$PAT" ]] && { echo "PAT file is empty" >&2; exit 2; }

# Canonical Org list for the umbrella.
ORG_NAMES=(CDCF LiturgicalCalendar BibleGet OntoKit)

# Colors only when stdout is a TTY (so scripted captures aren't cluttered with escapes).
if [[ -t 1 ]]; then
    R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; B=$'\033[0;34m'; N=$'\033[0m'
else
    R=""; G=""; Y=""; B=""; N=""
fi

log()  { echo "${B}[setup-zitadel]${N} $*" >&2; }
ok()   { echo "${G}    ✓${N} $*" >&2; }
warn() { echo "${Y}    ⚠${N} $*" >&2; }
err()  { echo "${R}    ✗${N} $*" >&2; }

# --- API helper -----------------------------------------------------------

# zapi METHOD PATH [BODY_JSON]
# Returns the response body on stdout. Caller checks .code or specific fields.
zapi() {
    local method="$1" path="$2" body="${3:-}"
    if [[ -n "$body" ]]; then
        curl -sS -X "$method" "${ZITADEL_INTERNAL_URL}${path}" \
            -H "Host: $ZITADEL_HOST" \
            -H "Authorization: Bearer $PAT" \
            -H "Connect-Protocol-Version: 1" \
            -H "Content-Type: application/json" \
            -d "$body"
    else
        curl -sS -X "$method" "${ZITADEL_INTERNAL_URL}${path}" \
            -H "Host: $ZITADEL_HOST" \
            -H "Authorization: Bearer $PAT" \
            -H "Connect-Protocol-Version: 1" \
            -H "Content-Type: application/json"
    fi
}

# --- actions --------------------------------------------------------------

# Find an Org by name. Echoes the org ID on stdout, or empty if not found.
find_org_id() {
    local name="$1"
    local body
    body=$(zapi POST /zitadel.org.v2.OrganizationService/ListOrganizations '{}')
    echo "$body" | jq -r --arg n "$name" '.result[]? | select(.name == $n) | .id // empty' | head -1
}

create_org() {
    local name="$1"
    local existing
    existing=$(find_org_id "$name")
    if [[ -n "$existing" ]]; then
        ok "Org already exists: $name ($existing)"
        echo "$existing"
        return 0
    fi
    log "Creating Org: $name"
    local result
    # Zitadel v2 uses AddOrganization (not CreateOrganization) for Orgs,
    # but CreateProject + CreateApplication for the other resources.
    result=$(zapi POST /zitadel.org.v2.OrganizationService/AddOrganization "{\"name\":\"$name\"}")
    local org_id
    org_id=$(echo "$result" | jq -r '.organizationId // empty')
    if [[ -z "$org_id" ]]; then
        err "Failed to create Org $name: $result"
        exit 3
    fi
    ok "Created Org: $name ($org_id)"
    echo "$org_id"
}

do_create_orgs() {
    log "Provisioning umbrella Orgs"
    for org in "${ORG_NAMES[@]}"; do
        create_org "$org" >/dev/null
    done
}

do_create_org() {
    log "Provisioning single Org: $SINGLE_ORG"
    create_org "$SINGLE_ORG" >/dev/null
}

do_rename_bootstrap_admin() {
    [[ -z "${ZITADEL_ADMIN_EMAIL:-}" ]] && {
        err "ZITADEL_ADMIN_EMAIL not set in $ENV_FILE — needed for --rename-bootstrap-admin"
        exit 4
    }
    log "Checking bootstrap IAM admin username"

    # Find the human admin in the default Zitadel org (org name "ZITADEL").
    local default_org_id
    default_org_id=$(find_org_id "ZITADEL")
    [[ -z "$default_org_id" ]] && { warn "Default 'ZITADEL' org not found — admin already provisioned?"; return 0; }

    local users_body
    users_body=$(zapi POST /v2/users "{\"queries\":[{\"organization_id_query\":{\"organizationId\":\"$default_org_id\"}},{\"type_query\":{\"type\":\"USER_TYPE_HUMAN\"}}]}")

    # Look for any human user whose username matches "<anything>@<orgdomain>".
    # The login_names3 projection's primary login_name corresponds to .username here.
    local target_id current_username
    target_id=$(echo "$users_body" | jq -r --arg email "$ZITADEL_ADMIN_EMAIL" '
        .result[]?
        | select(.username != $email)
        | select(.username | test("@[^@]+\\.[^@]+$"))
        | .userId // empty
    ' | head -1)

    if [[ -z "$target_id" ]]; then
        ok "No bootstrap admin with legacy suffix found — already renamed or never created."
        return 0
    fi

    current_username=$(echo "$users_body" | jq -r --arg id "$target_id" '.result[]? | select(.userId==$id) | .username')

    log "Renaming admin: $current_username → $ZITADEL_ADMIN_EMAIL (user $target_id)"
    local rename_result
    rename_result=$(curl -sS -w "\n%{http_code}" -X PUT \
        "${ZITADEL_INTERNAL_URL}/management/v1/users/${target_id}/username" \
        -H "Host: $ZITADEL_HOST" \
        -H "Authorization: Bearer $PAT" \
        -H "Content-Type: application/json" \
        -d "{\"userName\":\"$ZITADEL_ADMIN_EMAIL\"}")
    local rename_code
    rename_code=$(echo "$rename_result" | tail -1)
    if [[ "$rename_code" != "200" ]]; then
        err "Rename failed (HTTP $rename_code): $(echo "$rename_result" | head -n -1)"
        exit 5
    fi
    ok "Bootstrap admin renamed to $ZITADEL_ADMIN_EMAIL"
}

# --- LitCal provisioning --------------------------------------------------

LITCAL_PROJECT_NAME="LiturgicalCalendarAPI"
LITCAL_API_APP_NAME="LiturgicalCalendarAPI Backend"
LITCAL_FRONTEND_APP_NAME="LiturgicalCalendarFrontend"
LITCAL_ROLES=("admin:System Administrator" \
              "developer:Developer (API consumer)" \
              "calendar_editor:Calendar Editor" \
              "test_editor:Test Definition Author")

# Frontend deployment URLs (prod + staging). Used to register OIDC
# callback + post-logout URIs on the Frontend OIDC app.
LITCAL_FRONTEND_URLS=(
    "https://litcal.johnromanodorazio.com"
    "https://litcal-staging.johnromanodorazio.com"
)
LITCAL_FRONTEND_CALLBACK_PATH="/auth/callback.php"

# x-zitadel-orgid header lets a PAT operate on a different org than its home org.
# Wrapped zapi variant for org-scoped management API calls.
zapi_org() {
    local org_id="$1" method="$2" path="$3" body="${4:-}"
    if [[ -n "$body" ]]; then
        curl -sS -X "$method" "${ZITADEL_INTERNAL_URL}${path}" \
            -H "Host: $ZITADEL_HOST" \
            -H "Authorization: Bearer $PAT" \
            -H "x-zitadel-orgid: $org_id" \
            -H "Connect-Protocol-Version: 1" \
            -H "Content-Type: application/json" \
            -d "$body"
    else
        curl -sS -X "$method" "${ZITADEL_INTERNAL_URL}${path}" \
            -H "Host: $ZITADEL_HOST" \
            -H "Authorization: Bearer $PAT" \
            -H "x-zitadel-orgid: $org_id" \
            -H "Connect-Protocol-Version: 1" \
            -H "Content-Type: application/json"
    fi
}

find_project_id() {
    local org_id="$1" name="$2"
    local body
    body=$(zapi POST /zitadel.project.v2.ProjectService/ListProjects \
        "{\"filters\":[{\"project_name_filter\":{\"projectName\":\"$name\",\"method\":\"TEXT_FILTER_METHOD_EQUALS\"}},{\"organization_id_filter\":{\"organizationId\":\"$org_id\"}}]}")
    # Zitadel v2 ListProjects returns .projects[].id (was .projectId in earlier docs).
    echo "$body" | jq -r '.projects[0].id // .projects[0].projectId // empty'
}

create_project() {
    local org_id="$1" name="$2"
    local existing
    existing=$(find_project_id "$org_id" "$name")
    if [[ -n "$existing" ]]; then
        ok "Project already exists: $name ($existing)"
    else
        log "Creating Project: $name (in org $org_id)"
        local result
        result=$(zapi POST /zitadel.project.v2.ProjectService/CreateProject \
            "{\"name\":\"$name\",\"organizationId\":\"$org_id\"}")
        # CreateProject returns .id (v2) — fall back to .projectId for compat.
        existing=$(echo "$result" | jq -r '.id // .projectId // empty')
        if [[ -z "$existing" ]]; then
            err "Failed to create Project $name: $result"
            exit 6
        fi
        ok "Created Project: $name ($existing)"
    fi
    # Ensure projectRoleAssertion is enabled (so roles appear in tokens).
    # UpdateProject expects `projectId` in the body (not `id`).
    local upd
    upd=$(zapi POST /zitadel.project.v2.ProjectService/UpdateProject \
        "{\"projectId\":\"$existing\",\"projectRoleAssertion\":true}")
    if echo "$upd" | jq -e '.changeDate' >/dev/null 2>&1; then
        ok "Enabled projectRoleAssertion"
    elif echo "$upd" | jq -e '.code == "failed_precondition"' >/dev/null 2>&1; then
        ok "projectRoleAssertion already enabled"
    else
        warn "Could not confirm projectRoleAssertion: $upd"
    fi
    echo "$existing"
}

create_roles() {
    local project_id="$1"; shift
    log "Ensuring project roles ($# total)"
    local existing
    existing=$(zapi POST /zitadel.project.v2.ProjectService/ListProjectRoles \
        "{\"projectId\":\"$project_id\"}")
    for spec in "$@"; do
        local key="${spec%%:*}" display="${spec#*:}"
        if echo "$existing" | jq -e --arg k "$key" '.projectRoles[]? | select(.key == $k)' >/dev/null 2>&1; then
            ok "Role exists: $key"
            continue
        fi
        local result
        result=$(zapi POST /zitadel.project.v2.ProjectService/AddProjectRole \
            "{\"projectId\":\"$project_id\",\"roleKey\":\"$key\",\"displayName\":\"$display\"}")
        if echo "$result" | jq -e '.creationDate' >/dev/null 2>&1; then
            ok "Added role: $key ($display)"
        else
            err "Failed to add role $key: $result"
            exit 7
        fi
    done
}

# Create an OIDC Web-type app with PKCE (auth_method_type=NONE, no client
# secret). Used by browser-flow frontends. Idempotent: if the app exists,
# verify+sync redirect URIs to match what's passed in (additive — the
# server-side merge keeps any URIs we don't enumerate).
#
# Args:
#   $1 project_id
#   $2 app_name
#   $3 redirect_uris_json   JSON array, e.g. ["https://x/cb","https://y/cb"]
#   $4 post_logout_uris_json JSON array
create_oidc_web_app() {
    local project_id="$1" name="$2" redirect_uris_json="$3" post_logout_uris_json="$4"
    local oidc_payload
    oidc_payload=$(cat <<JSON
{
    "redirectUris": $redirect_uris_json,
    "postLogoutRedirectUris": $post_logout_uris_json,
    "responseTypes": ["OIDC_RESPONSE_TYPE_CODE"],
    "grantTypes": ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"],
    "applicationType": "OIDC_APP_TYPE_WEB",
    "authMethodType": "OIDC_AUTH_METHOD_TYPE_NONE",
    "accessTokenType": "OIDC_TOKEN_TYPE_JWT",
    "idTokenRoleAssertion": true,
    "accessTokenRoleAssertion": true,
    "idTokenUserinfoAssertion": true
}
JSON
)
    local existing
    existing=$(zapi POST /zitadel.application.v2.ApplicationService/ListApplications \
        "{\"filters\":[{\"project_id_filter\":{\"projectId\":\"$project_id\"}},{\"name_filter\":{\"name\":\"$name\"}}]}")
    local app_id client_id
    app_id=$(echo "$existing" | jq -r '.applications[0].id // .applications[0].applicationId // empty')
    if [[ -n "$app_id" ]]; then
        client_id=$(echo "$existing" | jq -r '.applications[0].oidcConfiguration.clientId // empty')
        ok "OIDC Web app exists: $name ($app_id, client_id=$client_id)"
        # Sync redirect URIs (idempotent — re-applying the same set is a no-op
        # server-side; if they've drifted, we converge them back).
        local upd
        upd=$(zapi POST /zitadel.application.v2.ApplicationService/UpdateApplication \
            "{\"projectId\":\"$project_id\",\"applicationId\":\"$app_id\",\"oidcConfiguration\":$oidc_payload}")
        if echo "$upd" | jq -e '.changeDate' >/dev/null 2>&1; then
            ok "Updated OIDC config (synced redirect URIs)"
        elif echo "$upd" | jq -e '.code == "failed_precondition"' >/dev/null 2>&1; then
            ok "OIDC config unchanged"
        else
            warn "Could not confirm OIDC config update: $upd"
        fi
        echo "$app_id|$client_id"
        return 0
    fi
    log "Creating OIDC Web app: $name"
    local result
    result=$(zapi POST /zitadel.application.v2.ApplicationService/CreateApplication \
        "{\"projectId\":\"$project_id\",\"name\":\"$name\",\"oidcConfiguration\":$oidc_payload}")
    app_id=$(echo "$result" | jq -r '.id // .applicationId // empty')
    client_id=$(echo "$result" | jq -r '.oidcConfiguration.clientId // .clientId // empty')
    if [[ -z "$app_id" ]]; then
        err "Failed to create Web app: $result"
        exit 10
    fi
    ok "Created OIDC Web app: $name ($app_id, client_id=$client_id)"
    echo "$app_id|$client_id"
}

# Create an OIDC API-type app (no redirect URIs; for service-to-service /
# token-validation use). Idempotent: skips creation if an app of the same
# name already exists in the project.
create_oidc_api_app() {
    local project_id="$1" name="$2"
    local existing
    existing=$(zapi POST /zitadel.application.v2.ApplicationService/ListApplications \
        "{\"filters\":[{\"project_id_filter\":{\"projectId\":\"$project_id\"}},{\"name_filter\":{\"name\":\"$name\"}}]}")
    local app_id client_id
    app_id=$(echo "$existing" | jq -r '.applications[0].id // .applications[0].applicationId // empty')
    if [[ -n "$app_id" ]]; then
        client_id=$(echo "$existing" | jq -r '.applications[0].oidcConfiguration.clientId // .applications[0].apiConfiguration.clientId // empty')
        ok "OIDC API app exists: $name ($app_id, client_id=$client_id)"
        echo "$app_id|$client_id"
        return 0
    fi
    log "Creating OIDC API app: $name"
    local result
    result=$(zapi POST /zitadel.application.v2.ApplicationService/CreateApplication \
        "{\"projectId\":\"$project_id\",\"name\":\"$name\",\"apiConfiguration\":{\"authMethodType\":\"API_AUTH_METHOD_TYPE_PRIVATE_KEY_JWT\"}}")
    app_id=$(echo "$result" | jq -r '.id // .applicationId // empty')
    client_id=$(echo "$result" | jq -r '.apiConfiguration.clientId // .clientId // empty')
    if [[ -z "$app_id" ]]; then
        err "Failed to create API app: $result"
        exit 8
    fi
    ok "Created OIDC API app: $name ($app_id, client_id=$client_id)"
    echo "$app_id|$client_id"
}

do_provision_litcal_frontend() {
    log "Provisioning LiturgicalCalendar Frontend OIDC app"
    local org_id project_id
    org_id=$(find_org_id "LiturgicalCalendar")
    [[ -z "$org_id" ]] && { err "LiturgicalCalendar Org not found. Run --create-orgs first."; exit 11; }
    project_id=$(find_project_id "$org_id" "$LITCAL_PROJECT_NAME")
    [[ -z "$project_id" ]] && { err "Project $LITCAL_PROJECT_NAME not found. Run --provision-litcal first."; exit 12; }

    # Build redirect_uris + post_logout_uris JSON arrays from LITCAL_FRONTEND_URLS.
    local redirect_uris_json post_logout_uris_json
    redirect_uris_json=$(printf '%s\n' "${LITCAL_FRONTEND_URLS[@]}" \
        | jq -R --arg cb "$LITCAL_FRONTEND_CALLBACK_PATH" '. + $cb' | jq -s '.')
    post_logout_uris_json=$(printf '%s\n' "${LITCAL_FRONTEND_URLS[@]}" | jq -R '.' | jq -s '.')

    local app_info
    app_info=$(create_oidc_web_app "$project_id" "$LITCAL_FRONTEND_APP_NAME" \
        "$redirect_uris_json" "$post_logout_uris_json")
    local app_id="${app_info%|*}" client_id="${app_info#*|}"

    echo
    echo "${B}=== LiturgicalCalendar Frontend handoff values ===${N}"
    echo "ZITADEL_ISSUER=$ZITADEL_ISSUER"
    echo "ZITADEL_PROJECT_ID=$project_id"
    echo "ZITADEL_FRONTEND_APP_ID=$app_id"
    echo "ZITADEL_FRONTEND_CLIENT_ID=$client_id"
    echo "# No client secret — PKCE (auth_method_type=NONE)"
    echo "# Registered redirect URIs:"
    for url in "${LITCAL_FRONTEND_URLS[@]}"; do echo "#   $url$LITCAL_FRONTEND_CALLBACK_PATH"; done
    echo "# Registered post-logout URIs:"
    for url in "${LITCAL_FRONTEND_URLS[@]}"; do echo "#   $url"; done
    echo
}

do_provision_litcal() {
    log "Provisioning LiturgicalCalendar"
    local org_id
    org_id=$(find_org_id "LiturgicalCalendar")
    if [[ -z "$org_id" ]]; then
        err "LiturgicalCalendar Org not found. Run --create-orgs first."
        exit 9
    fi
    ok "Found LiturgicalCalendar Org: $org_id"

    local project_id
    project_id=$(create_project "$org_id" "$LITCAL_PROJECT_NAME")

    create_roles "$project_id" "${LITCAL_ROLES[@]}"

    local app_info
    app_info=$(create_oidc_api_app "$project_id" "$LITCAL_API_APP_NAME")
    local app_id="${app_info%|*}" client_id="${app_info#*|}"

    # Emit handoff values to stdout for the operator / handoff doc.
    echo
    echo "${B}=== LiturgicalCalendar handoff values ===${N}"
    echo "ZITADEL_ISSUER=$ZITADEL_ISSUER"
    echo "ZITADEL_ORG_ID=$org_id"
    echo "ZITADEL_PROJECT_ID=$project_id"
    echo "ZITADEL_API_APP_ID=$app_id"
    echo "ZITADEL_CLIENT_ID=$client_id"
    echo "# Client secret + service-user keys must be generated separately"
    echo "# via the Zitadel console and delivered to LitCal out-of-band."
    echo
}

# --- main -----------------------------------------------------------------

log "Target: $TARGET (issuer: $ZITADEL_ISSUER, internal: $ZITADEL_INTERNAL_URL)"

for action in "${ACTIONS[@]}"; do
    case "$action" in
        rename-bootstrap-admin)     do_rename_bootstrap_admin ;;
        create-orgs)                do_create_orgs ;;
        create-org)                 do_create_org ;;
        provision-litcal)           do_provision_litcal ;;
        provision-litcal-frontend)  do_provision_litcal_frontend ;;
    esac
done

log "Done."
