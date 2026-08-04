#!/usr/bin/env bash
#
# setup-zitadel.sh — bootstrap and idempotent provisioning for cdcf-infra Zitadel.
#
# Reads credentials from .env.production (on the VPS) or .env.local (for
# pointing a dev-side script at a remote Zitadel). The automation PAT is
# loaded from the Zitadel data dir's automation-user.pat file written on
# first boot. Honors the --target {local,staging,production} convention from
# scripts/cdcf_api.py in the cdcf-website repo.
#
# Targets select which env file is sourced, and with it which Zitadel the
# script talks to. `staging` and `production` both resolve to the SAME
# production Zitadel: the staging frontends (litcal-staging.*,
# staging.catholicdigitalcommons.org) authenticate against it, which is why
# their origins are registered there. `local` is a separate Zitadel in its
# own compose stack. See issue #20 for why the URL-bearing actions do not
# yet vary their registered origins by target.
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
#   --provision-cdcf-website   Under the CDCF Org, create the "CDCF Website"
#                              Project + roles (team_member/editor/admin) + a
#                              confidential OIDC Web app (client_secret_post)
#                              for the Next.js frontend, with prod + staging +
#                              localhost dev callbacks registered. Emits
#                              client_secret ONCE on first run; re-runs against
#                              an existing app cannot recover the secret.
#   --provision-martyrology    Under the Martyrology Org, create the
#                              MartyrologyAPI Project + roles (admin,
#                              martyrology_editor, developer) + an API OIDC
#                              app with client_secret_basic (the API
#                              validates bearer tokens via Zitadel's
#                              /oauth/v2/introspect, which is HTTP-Basic
#                              authenticated with client_id/client_secret).
#                              The admin and martyrology_editor roles are a
#                              coarse population gate on curation writes;
#                              neither bypasses OpenFGA, which remains the
#                              authority on every per-resource decision
#                              against the Martyrology store. Emits
#                              client_secret ONCE on first run; re-runs
#                              against an existing app cannot recover the
#                              secret.
#   --rename-bootstrap-admin   If the IAM admin user still has the legacy
#                              `<username>@<orgdomain>` suffix in its
#                              username, rename it to $ZITADEL_ADMIN_EMAIL.
#   --all                      Run --rename-bootstrap-admin, --create-orgs,
#                              --provision-litcal, --provision-litcal-frontend,
#                              --provision-cdcf-website, --provision-martyrology
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
# Org names ride inside each ACTIONS entry ("create-org:NAME") rather than in a
# shared scalar: with one SINGLE_ORG, a second --create-org overwrote the first,
# so `--create-org A --create-org B` created B twice and silently dropped A.
# Same defect that was fixed for --create-store in setup-openfga.sh.

usage() {
    cat >&2 <<EOF
Usage: $0 --target {local,staging,production} ACTION [ACTION ...]

Targets:
  local       Separate local Zitadel (own compose stack), via .env.local
  staging     Production Zitadel, via .env.staging
  production  Production Zitadel, via .env.production

Actions:
  --create-orgs               Create CDCF, LiturgicalCalendar, BibleGet, OntoKit, Martyrology (idempotent)
  --create-org NAME           Create a single Org by name (idempotent)
  --provision-litcal          Provision LitCal Project + roles + API app
  --provision-litcal-frontend Provision LitCal Frontend OIDC app (Web/PKCE)
  --provision-cdcf-website    Provision CDCF Website Project + roles + Web OIDC app (client_secret_post)
  --provision-martyrology     Provision Martyrology Project + roles + API app (client_secret_basic)
  --provision-martyrology-frontend
                              Provision Martyrology Frontend OIDC app (Web/client_secret_post).
                              Origin follows --target: localhost+devMode on local,
                              romanmartyrology.com on production. Skips on staging
                              (no Martyrology staging deployment yet).
  --rename-bootstrap-admin    Rename IAM admin user to \$ZITADEL_ADMIN_EMAIL
  --all                       Above seven in dependency order

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
        # NAME must be present, non-empty and not itself an option: without the
        # last check `--create-org --provision-litcal` would swallow the action
        # and create an Org literally named "--provision-litcal".
        --create-org)                [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || usage; ACTIONS+=("create-org:$2"); shift 2 ;;
        --provision-litcal)          ACTIONS+=("provision-litcal"); shift ;;
        --provision-litcal-frontend) ACTIONS+=("provision-litcal-frontend"); shift ;;
        --provision-cdcf-website)    ACTIONS+=("provision-cdcf-website"); shift ;;
        --provision-martyrology)     ACTIONS+=("provision-martyrology"); shift ;;
        --provision-martyrology-frontend) ACTIONS+=("provision-martyrology-frontend"); shift ;;
        --rename-bootstrap-admin)    ACTIONS+=("rename-bootstrap-admin"); shift ;;
        --all)                       ACTIONS+=("rename-bootstrap-admin" "create-orgs" "provision-litcal" "provision-litcal-frontend" "provision-cdcf-website" "provision-martyrology" "provision-martyrology-frontend"); shift ;;
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
    staging)
        ENV_FILE="${ENV_FILE:-.env.staging}"
        ZITADEL_INTERNAL_URL_DEFAULT="http://127.0.0.1:8080"
        ;;
    production)
        ENV_FILE="${ENV_FILE:-.env.production}"
        ZITADEL_INTERNAL_URL_DEFAULT="http://127.0.0.1:8080"
        ;;
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
ORG_NAMES=(CDCF LiturgicalCalendar BibleGet OntoKit Martyrology)

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
    local name="$1"
    log "Provisioning single Org: $name"
    create_org "$name" >/dev/null
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
    # v2 PATCH /v2/users/{id} requires a `human` (or `machine`) type
    # discriminator in the body even when only top-level fields change.
    # Without the empty `human: {}`, the API returns 501
    # "user type is not implemented" — a misleading error that means
    # "missing type discriminator", not a real implementation gap.
    local rename_result
    rename_result=$(curl -sS -w "\n%{http_code}" -X PATCH \
        "${ZITADEL_INTERNAL_URL}/v2/users/${target_id}" \
        -H "Host: $ZITADEL_HOST" \
        -H "Authorization: Bearer $PAT" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$ZITADEL_ADMIN_EMAIL\",\"human\":{}}")
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

# `developer` is defined but enforced by nothing today: martyrology-api has no
# API-consumer features to gate. It exists so the role vocabulary is uniform
# across CDCF properties before principals are onboarded, since issuing a role
# to already-onboarded principals later is the disruptive path.
MARTYROLOGY_ROLES=("admin:System Administrator" \
                   "martyrology_editor:Martyrology Editor" \
                   "developer:Developer (API consumer)")

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

# Create an OIDC Web-type app. Used by browser-flow frontends. Idempotent:
# if the app exists, verify+sync redirect URIs (additive — server-side merge
# keeps URIs we don't enumerate).
#
# Auth method defaults to PKCE (NONE, no client secret) for backwards compat
# with existing LitCal frontend callers. Pass OIDC_AUTH_METHOD_TYPE_POST or
# OIDC_AUTH_METHOD_TYPE_BASIC for a confidential client (server-side flow with
# client_secret_post / client_secret_basic respectively — Auth.js v5, NextAuth,
# omniauth-oidc, etc.).
#
# Dev mode (default false) allows HTTP redirect URIs — required for localhost
# dev callbacks against this production Zitadel instance.
#
# Args:
#   $1 project_id
#   $2 app_name
#   $3 redirect_uris_json   JSON array, e.g. ["https://x/cb","https://y/cb"]
#   $4 post_logout_uris_json JSON array
#   $5 auth_method_type     OIDC_AUTH_METHOD_TYPE_NONE | _POST | _BASIC (default: _NONE)
#   $6 dev_mode             "true" | "false" (default: "false")
#
# Returns on stdout: "app_id|client_id|client_secret"
#   - client_secret is empty for PKCE apps (auth_method_type=NONE)
#   - client_secret is empty when the app ALREADY EXISTED (Zitadel's
#     ListApplications doesn't return secrets; rotation is a separate action
#     against the regenerate endpoint — not implemented here).
create_oidc_web_app() {
    local project_id="$1" name="$2" redirect_uris_json="$3" post_logout_uris_json="$4"
    local auth_method_type="${5:-OIDC_AUTH_METHOD_TYPE_NONE}"
    local dev_mode="${6:-false}"
    local oidc_payload
    oidc_payload=$(cat <<JSON
{
    "redirectUris": $redirect_uris_json,
    "postLogoutRedirectUris": $post_logout_uris_json,
    "responseTypes": ["OIDC_RESPONSE_TYPE_CODE"],
    "grantTypes": ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"],
    "applicationType": "OIDC_APP_TYPE_WEB",
    "authMethodType": "$auth_method_type",
    "accessTokenType": "OIDC_TOKEN_TYPE_JWT",
    "devMode": $dev_mode,
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
        # Client secret unrecoverable on the "exists" branch — emit empty.
        echo "$app_id|$client_id|"
        return 0
    fi
    log "Creating OIDC Web app: $name (authMethod=$auth_method_type, devMode=$dev_mode)"
    local result
    result=$(zapi POST /zitadel.application.v2.ApplicationService/CreateApplication \
        "{\"projectId\":\"$project_id\",\"name\":\"$name\",\"oidcConfiguration\":$oidc_payload}")
    app_id=$(echo "$result" | jq -r '.id // .applicationId // empty')
    client_id=$(echo "$result" | jq -r '.oidcConfiguration.clientId // .clientId // empty')
    if [[ -z "$app_id" ]]; then
        err "Failed to create Web app: $result"
        exit 10
    fi
    # Capture the one-time client secret for confidential clients. Zitadel
    # returns it inside oidcConfiguration on create; never retrievable later.
    local client_secret
    client_secret=$(echo "$result" | jq -r '.oidcConfiguration.clientSecret // .clientSecret // empty')
    # Fail fast if a confidential client was created without a secret —
    # otherwise the empty-secret on stdout is indistinguishable from the
    # "already exists" branch, and the caller silently loses the one-time
    # secret (Zitadel won't return it again on subsequent reads).
    if [[ "$auth_method_type" != "OIDC_AUTH_METHOD_TYPE_NONE" && -z "$client_secret" ]]; then
        err "Created confidential app $name ($app_id) but response had no client_secret."
        err "The secret cannot be recovered. Delete the app via the Zitadel console and re-run."
        exit 10
    fi
    ok "Created OIDC Web app: $name ($app_id, client_id=$client_id)"
    echo "$app_id|$client_id|$client_secret"
}

# Create an OIDC API-type app (no redirect URIs; for service-to-service /
# token-validation use). Idempotent: skips creation if an app of the same
# name already exists in the project.
#
# Auth method defaults to PRIVATE_KEY_JWT (no client secret — the client_id
# is used purely as the expected audience claim on locally-validated JWTs;
# this is what LitCal consumes). Pass API_AUTH_METHOD_TYPE_BASIC for a
# confidential API client that needs a client_secret — required when the
# consumer validates bearer tokens by calling Zitadel's /oauth/v2/introspect
# endpoint, which is HTTP-Basic authenticated with client_id/client_secret
# (this is what martyrology-api does).
#
# Args:
#   $1 project_id
#   $2 app_name
#   $3 auth_method_type   API_AUTH_METHOD_TYPE_PRIVATE_KEY_JWT (default) | _BASIC
#
# Returns on stdout: "app_id|client_id|client_secret"
#   - client_secret is empty for PRIVATE_KEY_JWT apps
#   - client_secret is empty when the app ALREADY EXISTED (Zitadel's
#     ListApplications doesn't return secrets; rotation is a separate action
#     against the regenerate endpoint — not implemented here).
create_oidc_api_app() {
    local project_id="$1" name="$2"
    local auth_method_type="${3:-API_AUTH_METHOD_TYPE_PRIVATE_KEY_JWT}"
    local existing
    existing=$(zapi POST /zitadel.application.v2.ApplicationService/ListApplications \
        "{\"filters\":[{\"project_id_filter\":{\"projectId\":\"$project_id\"}},{\"name_filter\":{\"name\":\"$name\"}}]}")
    local app_id client_id
    app_id=$(echo "$existing" | jq -r '.applications[0].id // .applications[0].applicationId // empty')
    if [[ -n "$app_id" ]]; then
        client_id=$(echo "$existing" | jq -r '.applications[0].oidcConfiguration.clientId // .applications[0].apiConfiguration.clientId // empty')
        ok "OIDC API app exists: $name ($app_id, client_id=$client_id)"
        # Client secret unrecoverable on the "exists" branch — emit empty.
        echo "$app_id|$client_id|"
        return 0
    fi
    log "Creating OIDC API app: $name (authMethod=$auth_method_type)"
    local result
    result=$(zapi POST /zitadel.application.v2.ApplicationService/CreateApplication \
        "{\"projectId\":\"$project_id\",\"name\":\"$name\",\"apiConfiguration\":{\"authMethodType\":\"$auth_method_type\"}}")
    app_id=$(echo "$result" | jq -r '.id // .applicationId // empty')
    client_id=$(echo "$result" | jq -r '.apiConfiguration.clientId // .clientId // empty')
    if [[ -z "$app_id" ]]; then
        err "Failed to create API app: $result"
        exit 8
    fi
    # Capture the one-time client secret for confidential API clients. Zitadel
    # returns it inside apiConfiguration on create; never retrievable later.
    local client_secret
    client_secret=$(echo "$result" | jq -r '.apiConfiguration.clientSecret // .clientSecret // empty')
    # Fail fast if a confidential client was created without a secret —
    # otherwise the empty-secret on stdout is indistinguishable from the
    # "already exists" branch, and the caller silently loses the one-time
    # secret (Zitadel won't return it again on subsequent reads).
    if [[ "$auth_method_type" != "API_AUTH_METHOD_TYPE_PRIVATE_KEY_JWT" && -z "$client_secret" ]]; then
        err "Created confidential API app $name ($app_id) but response had no client_secret."
        err "The secret cannot be recovered. Delete the app via the Zitadel console and re-run."
        exit 8
    fi
    ok "Created OIDC API app: $name ($app_id, client_id=$client_id)"
    echo "$app_id|$client_id|$client_secret"
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

    local app_info app_id client_id _client_secret
    app_info=$(create_oidc_web_app "$project_id" "$LITCAL_FRONTEND_APP_NAME" \
        "$redirect_uris_json" "$post_logout_uris_json")
    # LitCal frontend uses PKCE (default auth_method_type=NONE) so the secret
    # field is always empty here — discard it.
    IFS='|' read -r app_id client_id _client_secret <<<"$app_info"

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

# --- CDCF Website provisioning -------------------------------------------

CDCF_PROJECT_NAME="CDCF Website"
CDCF_APP_NAME="CDCF Website"
CDCF_APP_NAME_NONPROD="CDCF Website (Non-Prod)"
# Catalog of WP roles, mirrored 1:1 so the IAM layer is the canonical
# authority over capability names. `subscriber` is the implicit default —
# every email-verified Zitadel sign-up is treated as a Subscriber by the
# cdcf-website bearer validator + Auth.js role extraction, even before
# an explicit userGrant exists. Elevated roles (contributor → admin) get
# explicit Zitadel userGrant records via the Phase 6 role-elevation
# workflow. `team_member`-as-role was removed in Phase 5: the bio-edit
# ownership signal is the `author_team_member` ACF link, not a role —
# a linked Subscriber can still edit their bio.
CDCF_ROLES=("subscriber:Subscriber (default, no edit capabilities)" \
            "contributor:Contributor (drafts only)" \
            "author:Author (publish own posts)" \
            "editor:Editor (publish + edit others)" \
            "administrator:Administrator (full WP-admin)")

# Production origins (HTTPS only, devMode=false). Get their own confidential
# client + client_secret so production credentials are never shared with
# staging or localhost dev environments.
CDCF_FRONTEND_URLS=(
    "https://catholicdigitalcommons.org"
)
# Non-production origins (staging + localhost dev). Share a separate
# confidential client (devMode=true permits the HTTP localhost callback).
CDCF_FRONTEND_NONPROD_URLS=(
    "https://staging.catholicdigitalcommons.org"
    "http://localhost:3000"
)
CDCF_FRONTEND_CALLBACK_PATH="/api/auth/callback/zitadel"

# Create one CDCF Website OIDC app and emit its handoff block. Internal
# helper for do_provision_cdcf_website — runs the create + stdout
# formatting for either the prod or non-prod app.
#
# Args:
#   $1 project_id
#   $2 app_name        e.g. "CDCF Website" or "CDCF Website (Non-Prod)"
#   $3 dev_mode        "true" | "false"
#   $4 label           handoff section label, e.g. "Production" / "Non-Production"
#   $5..  origin URLs  one per arg
_emit_cdcf_app() {
    local project_id="$1" app_name="$2" dev_mode="$3" label="$4"
    shift 4
    local origins=("$@")

    local redirect_uris_json post_logout_uris_json
    redirect_uris_json=$(printf '%s\n' "${origins[@]}" \
        | jq -R --arg cb "$CDCF_FRONTEND_CALLBACK_PATH" '. + $cb' | jq -s '.')
    post_logout_uris_json=$(printf '%s\n' "${origins[@]}" | jq -R '.' | jq -s '.')

    # Confidential client with client_secret_post (Auth.js v5 server-side).
    local app_info app_id client_id client_secret
    app_info=$(create_oidc_web_app "$project_id" "$app_name" \
        "$redirect_uris_json" "$post_logout_uris_json" \
        "OIDC_AUTH_METHOD_TYPE_POST" "$dev_mode")
    IFS='|' read -r app_id client_id client_secret <<<"$app_info"

    echo
    echo "${B}=== CDCF Website handoff values — $label ===${N}"
    echo "ZITADEL_APP_ID=$app_id"
    echo "AUTH_ZITADEL_ID=$client_id          # ← client_id"
    if [[ -n "$client_secret" ]]; then
        echo "AUTH_ZITADEL_SECRET=$client_secret   # ← client_secret (one-time emit)"
    else
        warn "Client secret not emitted (app already existed; ListApplications"
        warn "  does not return secrets). Rotate via the Zitadel console:"
        warn "  CDCF Org → Projects → CDCF Website → Apps → $app_name → Regenerate Client Secret"
    fi
    echo "# Registered redirect URIs:"
    for url in "${origins[@]}"; do echo "#   $url$CDCF_FRONTEND_CALLBACK_PATH"; done
    echo "# Registered post-logout URIs:"
    for url in "${origins[@]}"; do echo "#   $url"; done
    echo "# devMode=$dev_mode"
}

do_provision_cdcf_website() {
    log "Provisioning CDCF Website"
    local org_id
    org_id=$(find_org_id "CDCF")
    if [[ -z "$org_id" ]]; then
        err "CDCF Org not found. Run --create-orgs first."
        exit 13
    fi
    ok "Found CDCF Org: $org_id"

    local project_id
    project_id=$(create_project "$org_id" "$CDCF_PROJECT_NAME")

    create_roles "$project_id" "${CDCF_ROLES[@]}"

    echo
    echo "${B}=== CDCF Website shared values ===${N}"
    echo "ZITADEL_ISSUER=$ZITADEL_ISSUER"
    echo "AUTH_ZITADEL_ISSUER=$ZITADEL_ISSUER"
    echo "ZITADEL_ORG_ID=$org_id"
    echo "ZITADEL_PROJECT_ID=$project_id"

    _emit_cdcf_app "$project_id" "$CDCF_APP_NAME" "false" "Production" \
        "${CDCF_FRONTEND_URLS[@]}"
    _emit_cdcf_app "$project_id" "$CDCF_APP_NAME_NONPROD" "true" "Non-Production (staging + localhost)" \
        "${CDCF_FRONTEND_NONPROD_URLS[@]}"
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

    local app_info app_id client_id _client_secret
    app_info=$(create_oidc_api_app "$project_id" "$LITCAL_API_APP_NAME")
    # LitCal's API app uses PRIVATE_KEY_JWT (default) so the secret field is
    # always empty here — discard it.
    IFS='|' read -r app_id client_id _client_secret <<<"$app_info"

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

# --- Martyrology provisioning ---------------------------------------------

MARTYROLOGY_ORG_NAME="Martyrology"
MARTYROLOGY_PROJECT_NAME="MartyrologyAPI"
MARTYROLOGY_API_APP_NAME="MartyrologyAPI Backend"

# --- Martyrology Frontend (OIDC login client) -----------------------------
#
# A confidential Web app in the SAME MartyrologyAPI project as the API
# validator app. Same project means create_project's projectRoleAssertion puts
# urn:zitadel:iam:org:project:<id>:roles into the token with no :aud scope
# requested — which is why this is not a project of its own.
#
# One app per Zitadel INSTANCE, not two apps in one instance. The origin and
# devMode are chosen by --target because each target is a different instance:
#
#   --target local       localhost origin, devMode=true  -> LOCAL Zitadel
#                        (its own compose stack, mirroring LitCal's setup)
#   --target production  production origin, devMode=false -> production Zitadel
#
# So no localhost client is ever registered in the production instance — that
# is the spec's D3, and this is the mechanism that implements it rather than a
# departure from it. Because local and production are separate instances, both
# apps can share one name without colliding; create_oidc_web_app matches an
# existing app by name WITHIN a project, so nothing is overwritten across
# instances.
#
# Martyrology has no staging deployment yet (design doc: "Staging environment |
# None"). --target staging therefore registers nothing and skips with a
# warning. If a staging origin appears later it goes in the production Zitadel
# under a DISTINCT app name — staging and production share an instance, so a
# shared name there would overwrite the production app's redirect URIs.
MARTYROLOGY_FRONTEND_APP_NAME="Martyrology Frontend"
case "$TARGET" in
    local)
        MARTYROLOGY_FRONTEND_URLS=("http://localhost:3000")
        MARTYROLOGY_FRONTEND_DEV_MODE="true"
        MARTYROLOGY_FRONTEND_LABEL="Local"
        ;;
    production)
        MARTYROLOGY_FRONTEND_URLS=("https://romanmartyrology.com")
        MARTYROLOGY_FRONTEND_DEV_MODE="false"
        MARTYROLOGY_FRONTEND_LABEL="Production"
        ;;
    *)
        MARTYROLOGY_FRONTEND_URLS=()
        MARTYROLOGY_FRONTEND_DEV_MODE="false"
        MARTYROLOGY_FRONTEND_LABEL="$TARGET"
        ;;
esac
# Auth.js v5 mounts its callback at /api/auth/callback/<provider-id>, and the
# built-in Zitadel provider's id is "zitadel". This string and the frontend's
# provider id must change together or sign-in fails at the redirect.
MARTYROLOGY_FRONTEND_CALLBACK_PATH="/api/auth/callback/zitadel"
# NOTE: three project roles exist (MARTYROLOGY_ROLES above): admin and
# martyrology_editor are a coarse population gate on curation writes, checked
# alongside — never instead of — OpenFGA. Zitadel remains identity-only
# beyond that (the `sub` claim plus these roles); every per-resource
# authorization decision is still an OpenFGA Check against the `Martyrology`
# store (auth/models/Martyrology.json). `create_project` already enables
# projectRoleAssertion, so these roles appear in tokens with no extra step.

do_provision_martyrology() {
    log "Provisioning Martyrology"
    local org_id
    org_id=$(find_org_id "$MARTYROLOGY_ORG_NAME")
    if [[ -z "$org_id" ]]; then
        err "$MARTYROLOGY_ORG_NAME Org not found. Run --create-orgs (or --create-org $MARTYROLOGY_ORG_NAME) first."
        exit 14
    fi
    ok "Found $MARTYROLOGY_ORG_NAME Org: $org_id"

    local project_id
    project_id=$(create_project "$org_id" "$MARTYROLOGY_PROJECT_NAME")

    create_roles "$project_id" "${MARTYROLOGY_ROLES[@]}"

    # client_secret_basic: the API validates incoming bearer tokens by POSTing
    # to $issuer/oauth/v2/introspect with HTTP Basic (client_id, client_secret).
    local app_info app_id client_id client_secret
    app_info=$(create_oidc_api_app "$project_id" "$MARTYROLOGY_API_APP_NAME" \
        "API_AUTH_METHOD_TYPE_BASIC")
    IFS='|' read -r app_id client_id client_secret <<<"$app_info"

    # Emit handoff values to stdout for the operator / handoff doc.
    echo
    echo "${B}=== Martyrology handoff values ===${N}"
    echo "ZITADEL_ORG_ID=$org_id"
    echo "ZITADEL_PROJECT_ID=$project_id"
    echo "ZITADEL_API_APP_ID=$app_id"
    echo
    echo "${B}--- for /etc/martyrology/api.env on the martyrology-api VPS ---${N}"
    echo "MARTYROLOGY_ZITADEL_ISSUER=$ZITADEL_ISSUER"
    echo "MARTYROLOGY_ZITADEL_CLIENT_ID=$client_id"
    if [[ -n "$client_secret" ]]; then
        echo "MARTYROLOGY_ZITADEL_CLIENT_SECRET=$client_secret   # ← ONE-TIME EMIT"
        warn "The client secret above is printed ONCE and is UNRECOVERABLE."
        warn "  Write it into /etc/martyrology/api.env NOW, before this shell scrolls."
    else
        warn "Client secret not emitted (app already existed; ListApplications"
        warn "  does not return secrets). Rotate via the Zitadel console:"
        warn "  $MARTYROLOGY_ORG_NAME Org → Projects → $MARTYROLOGY_PROJECT_NAME →"
        warn "  Apps → $MARTYROLOGY_API_APP_NAME → Regenerate Client Secret"
    fi
    echo "# Project roles (admin, martyrology_editor, developer) were created;"
    echo "# they are a coarse population gate only — per-resource authorization"
    echo "# is still decided by OpenFGA."
    echo "# Run: ./setup-openfga.sh --target $TARGET --create-martyrology-store"
    echo "# for MARTYROLOGY_OPENFGA_{API_URL,STORE_ID,MODEL_ID}, then seed the"
    echo "# governed_by tuples per handoffs/martyrology.md."
    echo
}

# Create one Martyrology Frontend OIDC app and emit its handoff block.
# Internal helper for do_provision_martyrology_frontend — mirrors
# _emit_cdcf_app, which solves the identical prod/non-prod problem.
#
# Args:
#   $1 project_id
#   $2 app_name
#   $3 dev_mode      "true" | "false"
#   $4 label         handoff section label
#   $5..  origin URLs, one per arg
_emit_martyrology_frontend_app() {
    local project_id="$1" app_name="$2" dev_mode="$3" label="$4"
    shift 4
    local origins=("$@")

    local redirect_uris_json post_logout_uris_json
    redirect_uris_json=$(printf '%s\n' "${origins[@]}" \
        | jq -R --arg cb "$MARTYROLOGY_FRONTEND_CALLBACK_PATH" '. + $cb' | jq -s '.')
    post_logout_uris_json=$(printf '%s\n' "${origins[@]}" | jq -R '.' | jq -s '.')

    # Confidential client with client_secret_post (Auth.js v5 server-side).
    local app_info app_id client_id client_secret
    app_info=$(create_oidc_web_app "$project_id" "$app_name" \
        "$redirect_uris_json" "$post_logout_uris_json" \
        "OIDC_AUTH_METHOD_TYPE_POST" "$dev_mode")
    IFS='|' read -r app_id client_id client_secret <<<"$app_info"

    echo
    echo "${B}=== Martyrology Frontend handoff values — $label ===${N}"
    echo "ZITADEL_APP_ID=$app_id"
    echo "AUTH_ZITADEL_ID=$client_id          # ← client_id"
    if [[ -n "$client_secret" ]]; then
        echo "AUTH_ZITADEL_SECRET=$client_secret   # ← client_secret (one-time emit)"
        warn "The client secret above is printed ONCE and is UNRECOVERABLE."
        warn "  Put it into the Plesk Node environment NOW, before this shell scrolls."
    else
        warn "Client secret not emitted (app already existed; ListApplications"
        warn "  does not return secrets). Rotate via the Zitadel console:"
        warn "  $MARTYROLOGY_ORG_NAME Org → Projects → $MARTYROLOGY_PROJECT_NAME →"
        warn "  Apps → $app_name → Regenerate Client Secret"
    fi
    echo "# Registered redirect URIs:"
    for url in "${origins[@]}"; do echo "#   $url$MARTYROLOGY_FRONTEND_CALLBACK_PATH"; done
    echo "# Registered post-logout URIs:"
    for url in "${origins[@]}"; do echo "#   $url"; done
    echo "# devMode=$dev_mode"
}

do_provision_martyrology_frontend() {
    log "Provisioning Martyrology Frontend OIDC app ($MARTYROLOGY_FRONTEND_LABEL)"
    # No origin defined for this target — skip before touching the API, so
    # `--all --target staging` sweeps past this action instead of registering
    # an app with an empty redirect URI list.
    if [[ ${#MARTYROLOGY_FRONTEND_URLS[@]} -eq 0 ]]; then
        warn "No Martyrology frontend origin is defined for --target $TARGET; skipping."
        warn "  Martyrology has no staging deployment yet. Use --target local"
        warn "  (localhost, against a local Zitadel) or --target production."
        return 0
    fi
    local org_id
    org_id=$(find_org_id "$MARTYROLOGY_ORG_NAME")
    if [[ -z "$org_id" ]]; then
        err "$MARTYROLOGY_ORG_NAME Org not found. Run --create-orgs (or --create-org $MARTYROLOGY_ORG_NAME) first."
        exit 15
    fi
    local project_id
    project_id=$(find_project_id "$org_id" "$MARTYROLOGY_PROJECT_NAME")
    if [[ -z "$project_id" ]]; then
        err "Project $MARTYROLOGY_PROJECT_NAME not found. Run --provision-martyrology first."
        exit 16
    fi
    ok "Found $MARTYROLOGY_PROJECT_NAME Project: $project_id"

    echo
    echo "${B}=== Martyrology Frontend shared values ===${N}"
    echo "AUTH_ZITADEL_ISSUER=$ZITADEL_ISSUER"
    echo "ZITADEL_PROJECT_ID=$project_id"

    _emit_martyrology_frontend_app "$project_id" "$MARTYROLOGY_FRONTEND_APP_NAME" \
        "$MARTYROLOGY_FRONTEND_DEV_MODE" "$MARTYROLOGY_FRONTEND_LABEL" \
        "${MARTYROLOGY_FRONTEND_URLS[@]}"
    echo
}

# --- main -----------------------------------------------------------------

log "Target: $TARGET (issuer: $ZITADEL_ISSUER, internal: $ZITADEL_INTERNAL_URL)"

for action in "${ACTIONS[@]}"; do
    case "${action%%:*}" in
        rename-bootstrap-admin)     do_rename_bootstrap_admin ;;
        create-orgs)                do_create_orgs ;;
        create-org)                 do_create_org "${action#*:}" ;;
        provision-litcal)           do_provision_litcal ;;
        provision-litcal-frontend)  do_provision_litcal_frontend ;;
        provision-cdcf-website)     do_provision_cdcf_website ;;
        provision-martyrology)      do_provision_martyrology ;;
        provision-martyrology-frontend) do_provision_martyrology_frontend ;;
    esac
done

log "Done."
