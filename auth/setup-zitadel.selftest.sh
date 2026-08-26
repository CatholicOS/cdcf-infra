#!/usr/bin/env bash
#
# setup-zitadel.selftest.sh — run auth/setup-zitadel.sh against a stub Zitadel
# and assert what each (action, --target) pair actually registers.
#
# Why this exists: the three URL-bearing actions used to register hardcoded
# production URLs regardless of --target (issue #20). The fix is an app split —
# one app per (property, environment), target selecting which — because
# create_oidc_web_app sends the whole redirectUris array to UpdateApplication,
# so a run REPLACES the registered set. While production and staging origins
# shared one app, a --target staging run would have stripped the production
# callback. That is the regression this file exists to make impossible to
# reintroduce quietly, and the case that matters most is the negative one:
# staging must never emit the production origin.
#
# Every case names the exit code it must produce AND a substring its output
# must contain (or must NOT contain), so a regression that fails for the wrong
# reason is not a pass either — same rule as validate-expectations.selftest.sh
# and setup-openfga.selftest.sh.
#
# How it works: setup-zitadel.sh resolves its env file relative to the working
# directory, so each case runs a COPY of the script inside a scratch sandbox
# with its own .env.<target> and a PAT file. The stub speaks only the endpoints
# the script calls and always reports the app as new, so every run takes the
# CreateApplication path and prints the origins it registered.
#
# Requires python3 (stub), curl and jq (the script under test uses them).
# Run it from anywhere:  ./auth/setup-zitadel.selftest.sh
#
# Exit codes: 0 every case behaved as declared; 1 one or more did not.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/setup-zitadel.sh"

if [[ -t 1 ]]; then
    R=$'\033[0;31m'; G=$'\033[0;32m'; B=$'\033[0;34m'; N=$'\033[0m'
else
    R=""; G=""; B=""; N=""
fi

PASSES=0
FAILURES=0

for tool in python3:"the stub Zitadel" jq:"the script under test" curl:"the script under test"; do
    command -v "${tool%%:*}" >/dev/null 2>&1 || {
        echo "${R}[selftest] ${tool%%:*} is required (${tool#*:}).${N}" >&2
        exit 1
    }
done
[[ -f "$TARGET_SCRIPT" ]] || { echo "${R}[selftest] not found: $TARGET_SCRIPT${N}" >&2; exit 1; }

SANDBOX="$(mktemp -d)"
STUB_PID=""
cleanup() {
    [[ -n "$STUB_PID" ]] && kill "$STUB_PID" 2>/dev/null
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"

cp "$TARGET_SCRIPT" "$SANDBOX/setup-zitadel.sh"
chmod +x "$SANDBOX/setup-zitadel.sh"
printf 'stub-pat\n' > "$SANDBOX/automation-user.pat"

# One env file per target. ZITADEL_ISSUER stays an https:// production-looking
# URL even for local, because the script derives ZITADEL_HOST from it for the
# Host header; the stub does not care, and this keeps the cases about origins
# rather than about issuer plumbing.
for t in local staging production; do
    cat > "$SANDBOX/.env.${t}" <<EOF
ZITADEL_ISSUER=https://auth.catholicdigitalcommons.org
ZITADEL_INTERNAL_URL=http://127.0.0.1:${PORT}
ZITADEL_PAT_FILE=${SANDBOX}/automation-user.pat
ZITADEL_ADMIN_EMAIL=stub@example.org
EOF
done

# Property-shaped sandboxes for the --target local cross-provisioning guard
# (issue #34). The guard infers the property from the PAT's own location —
# <property>/.zitadel-data/automation-user.pat — so these cases need real
# directory shape, not just a distinct filename.
#
# The plain .env.local above deliberately keeps its PAT at $SANDBOX root, which
# infers NO property. That is what a hand-rolled shared .env.local looks like,
# and the guard must refuse it for property-bound actions.
for prop in cdcf-website martyrology-api martyrology-frontend; do
    mkdir -p "$SANDBOX/${prop}/.zitadel-data"
    printf 'stub-pat\n' > "$SANDBOX/${prop}/.zitadel-data/automation-user.pat"
    cat > "$SANDBOX/.env.local.${prop}" <<EOF
ZITADEL_ISSUER=https://auth.catholicdigitalcommons.org
ZITADEL_INTERNAL_URL=http://127.0.0.1:${PORT}
ZITADEL_PAT_FILE=${SANDBOX}/${prop}/.zitadel-data/automation-user.pat
ZITADEL_ADMIN_EMAIL=stub@example.org
EOF
done

cat > "$SANDBOX/stub.py" <<'PYEOF'
"""Stub Zitadel. Serves only what setup-zitadel.sh calls.

Records every request body to $STUB_LOG as one JSON object per line, so cases
can assert on the PAYLOAD the script actually sent rather than only on what it
printed. The two differ in the way that matters: the handoff block is echoed
from shell variables, while redirectUris/postLogoutRedirectUris are assembled
separately by jq — an assertion on stdout alone would not catch a payload that
disagreed with the echo.

$STUB_EXISTING file holds one app name per line that ListApplications should
report as already present. It is read PER REQUEST, not at startup, so a single
long-lived stub can serve cases that disagree about what already exists.
Declaring an app flips the script from the CreateApplication path to the
UpdateApplication path, which is where the replace-semantics live:
UpdateApplication sends the WHOLE redirectUris array, so it is the call that can
strip a production callback off an existing app.
"""
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

ORGS = ["CDCF", "LiturgicalCalendar", "BibleGet", "OntoKit", "Martyrology"]
LOG = os.environ.get("STUB_LOG", "")
EXISTING_FILE = os.environ.get("STUB_EXISTING", "")


def existing_apps():
    try:
        with open(EXISTING_FILE) as fh:
            return [l.strip() for l in fh if l.strip()]
    except OSError:
        return []


class H(BaseHTTPRequestHandler):
    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n).decode() if n else ""
        p = self.path
        if LOG:
            with open(LOG, "a") as fh:
                fh.write(json.dumps({"path": p, "body": raw}) + "\n")
        if p.endswith("/ListOrganizations"):
            return self._send(200, {"result": [
                {"id": f"org-{i}", "name": name} for i, name in enumerate(ORGS)]})
        if p.endswith("/AddOrganization"):
            return self._send(200, {"organizationId": "org-new"})
        if p.endswith("/ListProjects"):
            return self._send(200, {"projects": [{"id": "proj-1"}]})
        if p.endswith("/CreateProject"):
            return self._send(200, {"id": "proj-1"})
        if p.endswith("/UpdateProject"):
            return self._send(200, {"changeDate": "2026-08-18T00:00:00Z"})
        if p.endswith("/ListProjectRoles"):
            return self._send(200, {"projectRoles": []})
        if p.endswith("/AddProjectRole"):
            return self._send(200, {"creationDate": "2026-08-18T00:00:00Z"})
        if p.endswith("/ListApplications"):
            # Report an app as existing only when the case declared it, so the
            # same stub covers both the create and the update path.
            try:
                name = json.loads(raw)["filters"][1]["name_filter"]["name"]
            except Exception:
                name = None
            if name in existing_apps():
                return self._send(200, {"applications": [{
                    "id": "app-existing",
                    "oidcConfiguration": {"clientId": "client-existing"},
                }]})
            return self._send(200, {"applications": []})
        if p.endswith("/CreateApplication"):
            # Both shapes: the script reads oidcConfiguration.* for Web apps
            # and apiConfiguration.* for API apps, and --all provisions both.
            # Omitting apiConfiguration makes --all abort on "response had no
            # client_secret", which is a stub gap, not a target-policy failure.
            return self._send(200, {
                "id": "app-1",
                "oidcConfiguration": {
                    "clientId": "client-1",
                    "clientSecret": "secret-1",
                },
                "apiConfiguration": {
                    "clientId": "api-client-1",
                    "clientSecret": "api-secret-1",
                },
            })
        if p.endswith("/UpdateApplication"):
            return self._send(200, {"changeDate": "2026-08-18T00:00:00Z"})
        if p == "/v2/users":
            return self._send(200, {"result": []})
        return self._send(200, {})

    def do_GET(self):
        return self._send(200, {})


HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF

REQ_LOG="$SANDBOX/requests.jsonl"
EXISTING_FILE="$SANDBOX/existing_apps"
: > "$EXISTING_FILE"

start_stub() {
    STUB_LOG="$REQ_LOG" STUB_EXISTING="$EXISTING_FILE" \
        python3 "$SANDBOX/stub.py" "$PORT" >"$SANDBOX/stub.log" 2>&1 &
    STUB_PID=$!
    local i
    for i in $(seq 1 50); do
        curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${PORT}/" && return 0
        sleep 0.1
    done
    kill "$STUB_PID" 2>/dev/null; STUB_PID=""
    return 1
}

# expect EXPECTED_EXIT MODE PATTERN DESCRIPTION -- [VAR=value...] ARGS...
#   MODE: has  -> output MUST contain PATTERN
#         lacks -> output must NOT contain PATTERN
#
# Any leading VAR=value tokens after the -- are exported for that run only, so
# a case can select its env file (ENV_FILE=.env.local.<property>) or set the
# guard override without leaking either into the next case.
expect() {
    local want_exit="$1" mode="$2" pattern="$3" desc="$4"; shift 4
    [[ "$1" == "--" ]] && shift

    local envs=()
    while [[ $# -gt 0 && "$1" == [A-Z_]*=* ]]; do envs+=("$1"); shift; done

    local out got_exit
    out=$(cd "$SANDBOX" && env ${envs[@]+"${envs[@]}"} ./setup-zitadel.sh "$@" 2>&1)
    got_exit=$?

    local problem=""
    if [[ "$got_exit" -ne "$want_exit" ]]; then
        problem="expected exit $want_exit, got $got_exit"
    elif [[ "$mode" == "has" && "$out" != *"$pattern"* ]]; then
        problem="exit $got_exit as expected, but output did not contain: $pattern"
    elif [[ "$mode" == "lacks" && "$out" == *"$pattern"* ]]; then
        problem="exit $got_exit as expected, but output WRONGLY contained: $pattern"
    fi

    if [[ -z "$problem" ]]; then
        echo "${G}  PASS${N}  $desc (exit $got_exit)"
        PASSES=$((PASSES + 1))
    else
        echo "${R}  FAIL${N}  $desc"
        echo "        $problem"
        echo "$out" | sed 's/^/        | /'
        FAILURES=$((FAILURES + 1))
    fi
}

# expect_payload ENDPOINT MODE PATTERN DESCRIPTION -- ARGS...
#
# Runs the script, then asserts against the request BODY the stub recorded for
# ENDPOINT (e.g. UpdateApplication) rather than against stdout. The two can
# disagree: the handoff block is echoed from shell variables, while
# redirectUris/postLogoutRedirectUris are assembled separately by jq.
#
# Declare pre-existing apps first with `existing_apps NAME...` to drive the
# script down the UpdateApplication path.
expect_payload() {
    local endpoint="$1" mode="$2" pattern="$3" desc="$4"; shift 4
    [[ "$1" == "--" ]] && shift

    local envs=()
    while [[ $# -gt 0 && "$1" == [A-Z_]*=* ]]; do envs+=("$1"); shift; done

    : > "$REQ_LOG"
    local out got_exit
    out=$(cd "$SANDBOX" && env ${envs[@]+"${envs[@]}"} ./setup-zitadel.sh "$@" 2>&1)
    got_exit=$?

    local body
    body=$(python3 - "$REQ_LOG" "$endpoint" <<'PYX'
import json, sys
path, endpoint = sys.argv[1], sys.argv[2]
hits = []
try:
    for line in open(path):
        rec = json.loads(line)
        if rec["path"].endswith("/" + endpoint):
            hits.append(rec["body"])
except OSError:
    pass
print(hits[-1] if hits else "")
PYX
)

    local problem=""
    if [[ "$got_exit" -ne 0 ]]; then
        problem="script exited $got_exit"
    elif [[ -z "$body" ]]; then
        problem="no $endpoint request was recorded — the path under test never ran"
    elif [[ "$mode" == "has" && "$body" != *"$pattern"* ]]; then
        problem="$endpoint payload did not contain: $pattern"
    elif [[ "$mode" == "lacks" && "$body" == *"$pattern"* ]]; then
        problem="$endpoint payload WRONGLY contained: $pattern"
    fi

    if [[ -z "$problem" ]]; then
        echo "${G}  PASS${N}  $desc"
        PASSES=$((PASSES + 1))
    else
        echo "${R}  FAIL${N}  $desc"
        echo "        $problem"
        [[ -n "$body" ]] && echo "        | $body"
        FAILURES=$((FAILURES + 1))
    fi
}

# existing_apps NAME... — declare which apps ListApplications reports as present.
existing_apps() {
    : > "$EXISTING_FILE"
    local n
    for n in "$@"; do echo "$n" >> "$EXISTING_FILE"; done
}

start_stub || { echo "${R}[selftest] stub failed to start on port $PORT${N}" >&2; exit 1; }

echo "${B}[selftest]${N} $TARGET_SCRIPT"
echo "${B}[selftest]${N} --- LitCal: production and staging are SEPARATE apps ---"

expect 0 has "LiturgicalCalendarFrontend (Staging)" \
    "staging registers the Staging app, not the production one" -- \
    --target staging --provision-litcal-frontend

expect 0 has "https://litcal-staging.johnromanodorazio.com/auth/callback.php" \
    "staging registers the staging callback" -- \
    --target staging --provision-litcal-frontend

expect 0 lacks "https://litcal.johnromanodorazio.com/auth/callback.php" \
    "staging NEVER emits the production origin — the outage this design prevents" -- \
    --target staging --provision-litcal-frontend

expect 0 has "https://litcal.johnromanodorazio.com/auth/callback.php" \
    "production registers the production callback" -- \
    --target production --provision-litcal-frontend

expect 0 lacks "litcal-staging" \
    "production never emits the staging origin" -- \
    --target production --provision-litcal-frontend

expect 0 has "LiturgicalCalendarAPI/scripts/setup-zitadel.sh" \
    "local skips and names the script that DOES provision it" -- \
    --target local --provision-litcal-frontend

echo "${B}[selftest]${N} --- UnitTestInterface: one app, both remote targets, JWT tokens ---"

expect 0 has "https://litcal-tests.johnromanodorazio.com/auth/callback.php" \
    "production registers the tests callback" -- \
    --target production --provision-litcal-tests-ui

# Not target-scoped, unlike the frontend: one deployment, one origin, so both remote
# targets write the same value and neither can strip the other. This asserts staging
# registers it too -- if it did not, the app would be converged by only one target and
# a staging run would silently leave it on whatever it had drifted to.
expect 0 has "https://litcal-tests.johnromanodorazio.com/auth/callback.php" \
    "staging registers the SAME tests callback -- the app is not target-scoped" -- \
    --target staging --provision-litcal-tests-ui

expect 0 lacks "litcal-staging" \
    "the tests app never picks up the frontend's staging origin" -- \
    --target staging --provision-litcal-tests-ui

expect 0 has "LiturgicalCalendarAPI/scripts/setup-zitadel.sh" \
    "local skips and names the script that DOES provision it" -- \
    --target local --provision-litcal-tests-ui

# The whole point of the action. The live app was hand-created in the console and so
# carried Zitadel's defaults -- an opaque access token, every assertion off -- which left
# UnitTestInterface unable to authenticate at all: its TokenValidator rejects a non-JWT
# structurally and falls back to an endpoint that refuses Zitadel tokens, giving a 401.
expect_payload CreateApplication has '"accessTokenType": "OIDC_TOKEN_TYPE_JWT"' \
    "the tests app is created with JWT access tokens, never Zitadel's opaque default" -- \
    --target production --provision-litcal-tests-ui

for assertion in idTokenRoleAssertion accessTokenRoleAssertion idTokenUserinfoAssertion; do
    expect_payload CreateApplication has "\"$assertion\": true" \
        "the tests app is created with $assertion, matching the frontend" -- \
        --target production --provision-litcal-tests-ui
done

# The adoption path: the app already exists on the live instance under this exact name,
# so a run must converge it through UpdateApplication rather than create a second one.
existing_apps "UnitTestInterface"
expect_payload UpdateApplication has '"accessTokenType": "OIDC_TOKEN_TYPE_JWT"' \
    "an EXISTING tests app is converged to JWT -- this is what repairs the hand-made one" -- \
    --target production --provision-litcal-tests-ui

expect_payload UpdateApplication has '"accessTokenRoleAssertion": true' \
    "an existing tests app is converged to accessTokenRoleAssertion too" -- \
    --target production --provision-litcal-tests-ui
existing_apps

echo "${B}[selftest]${N} --- CDCF: one app per environment, no localhost in production Zitadel ---"

expect 0 has "http://localhost:3000/api/auth/callback/zitadel" \
    "local registers the localhost origin" -- \
    ENV_FILE=.env.local.cdcf-website --target local --provision-cdcf-website

expect 0 has "devMode=true" \
    "local sets devMode, which the HTTP localhost callback requires" -- \
    ENV_FILE=.env.local.cdcf-website --target local --provision-cdcf-website

expect 0 has "https://staging.catholicdigitalcommons.org/api/auth/callback/zitadel" \
    "staging registers the staging origin on the Non-Prod app" -- \
    --target staging --provision-cdcf-website

expect 0 lacks "localhost:3000" \
    "staging NEVER registers localhost — that was the martyrology-api#26 drift" -- \
    --target staging --provision-cdcf-website

expect 0 has "https://catholicdigitalcommons.org/api/auth/callback/zitadel" \
    "production registers the production origin" -- \
    --target production --provision-cdcf-website

expect 0 lacks "staging.catholicdigitalcommons.org" \
    "production never registers the staging origin" -- \
    --target production --provision-cdcf-website

echo "${B}[selftest]${N} --- Martyrology: unchanged behaviour, shared skip helper ---"

expect 0 has "http://localhost:3000/api/auth/callback/zitadel" \
    "local registers the localhost origin" -- \
    ENV_FILE=.env.local.martyrology-frontend --target local --provision-martyrology-frontend

expect 0 has "https://romanmartyrology.com/api/auth/callback/zitadel" \
    "production registers the production origin" -- \
    --target production --provision-martyrology-frontend

expect 0 has "no staging deployment" \
    "staging skips with the reason, since Martyrology has no staging origin" -- \
    --target staging --provision-martyrology-frontend

echo "${B}[selftest]${N} --- the skip contract: exit 0, so --all sweeps past ---"

expect 0 has "skipping" \
    "--all --target staging sweeps past the actions with no staging origin" -- \
    --target staging --all

expect 0 has "skipping" \
    "--all --target local sweeps past LitCal rather than failing the sweep" -- \
    ZITADEL_ALLOW_FOREIGN_PAT=1 --target local --all

echo "${B}[selftest]${N} --- issue #34: --target local cross-provisioning guard ---"

# The failure this blocks is SILENT, not loud: a PAT that is a valid IAM_OWNER
# for cdcf-website's local Zitadel will happily create Martyrology's Project,
# roles and app inside it, and every API call succeeds. Both instances are
# "local", so there is no target-name difference to notice. The guard reads the
# property out of the PAT's own path and refuses when it disagrees with the
# action.

expect 17 has "martyrology-api" \
    "provisioning Martyrology with cdcf-website's PAT refuses, and names the property it wanted" -- \
    ENV_FILE=.env.local.cdcf-website --target local --provision-martyrology

expect 17 has "cdcf-website" \
    "the refusal also names the property the PAT actually belongs to" -- \
    ENV_FILE=.env.local.cdcf-website --target local --provision-martyrology

expect 17 lacks "handoff values" \
    "a refused run writes nothing — no handoff block means no Project was created" -- \
    ENV_FILE=.env.local.cdcf-website --target local --provision-martyrology

expect 0 has "Martyrology handoff values" \
    "the same action with its OWN property's PAT provisions normally" -- \
    ENV_FILE=.env.local.martyrology-api --target local --provision-martyrology

expect 17 has "martyrology-frontend" \
    "the frontend app belongs only in the frontend's own stack, not the API's" -- \
    ENV_FILE=.env.local.martyrology-api --target local --provision-martyrology-frontend

# A property's stack may legitimately host another property's Project.
# martyrology-frontend/scripts/setup-stack.sh runs --provision-martyrology
# against its OWN instance, because the frontend authenticates there and needs
# the Martyrology Project and roles to exist. Pinning the action to
# martyrology-api alone would refuse that correct run — so the check is an
# allow-list, and what stays refused is the cross-FAMILY case #34 reported.
expect 0 has "Martyrology handoff values" \
    "the frontend's stack may provision the Martyrology Project it authenticates against" -- \
    ENV_FILE=.env.local.martyrology-frontend --target local --provision-martyrology

expect 0 has "Martyrology Frontend" \
    "martyrology-frontend's real setup-stack.sh invocation is not broken by the guard" -- \
    ENV_FILE=.env.local.martyrology-frontend --target local \
    --create-org Martyrology --provision-martyrology --provision-martyrology-frontend

expect 17 has "martyrology-api or martyrology-frontend" \
    "but cdcf-website's stack still may not — that is the cross-family bug in #34" -- \
    ENV_FILE=.env.local.cdcf-website --target local --provision-martyrology

expect 17 has "ENV_FILE=.env.local." \
    "a bare shared .env.local infers no property at all, and is refused with the fix" -- \
    --target local --provision-cdcf-website

expect 0 has "Provisioning CDCF Website" \
    "the override lets an unusual layout through" -- \
    ZITADEL_ALLOW_FOREIGN_PAT=1 --target local --provision-cdcf-website

echo "${B}[selftest]${N} --- the guard is local-only, and instance-wide actions are exempt ---"

expect 0 has "Org already exists" \
    "--create-orgs is instance-wide, so it passes with any PAT" -- \
    --target local --create-orgs

expect 0 lacks "belongs to" \
    "--rename-bootstrap-admin is instance-wide too and is never guarded" -- \
    --target local --rename-bootstrap-admin

expect 0 has "CDCF Website handoff values" \
    "production is never guarded — the PAT path convention is a local-stack thing" -- \
    --target production --provision-cdcf-website

expect 0 has "CDCF Website (Non-Prod)" \
    "staging is never guarded either" -- \
    --target staging --provision-cdcf-website

expect 17 has "belongs to" \
    "a local --all spans properties, so it cannot resolve to one instance" -- \
    ENV_FILE=.env.local.cdcf-website --target local --all

echo "${B}[selftest]${N} --- LitCal has no local stack: skip, never a silent write ---"

expect 0 has "No local stack is defined for LiturgicalCalendar" \
    "--provision-litcal skips on local rather than landing LitCal in another property's Zitadel" -- \
    ENV_FILE=.env.local.cdcf-website --target local --provision-litcal

expect 0 lacks "LiturgicalCalendar handoff values" \
    "the skip is real: no Project, no roles, no app, no handoff block" -- \
    ENV_FILE=.env.local.cdcf-website --target local --provision-litcal

expect 0 has "LiturgicalCalendarAPI/scripts/setup-zitadel.sh" \
    "and it names the script that DOES provision LitCal locally" -- \
    ENV_FILE=.env.local.cdcf-website --target local --provision-litcal

echo "${B}[selftest]${N} --- usage exits are unchanged ---"

expect 64 has "Usage" \
    "a target with no action is still a usage error" -- \
    --target production

expect 64 has "Unknown target" \
    "an unknown target is still rejected" -- \
    --target nowhere --provision-cdcf-website

echo "${B}[selftest]${N} --- the UPDATE path: what a run sends to an app that already exists ---"

# These matter more than the create cases. UpdateApplication replaces the whole
# redirectUris array on an app that is already serving traffic, so this is the
# call that can strip a production callback. The create path cannot do that.

existing_apps "LiturgicalCalendarFrontend"
expect_payload UpdateApplication lacks "litcal-staging.johnromanodorazio.com" \
    "production update never sends a staging origin to the production app" -- \
    --target production --provision-litcal-frontend

existing_apps "LiturgicalCalendarFrontend"
expect_payload UpdateApplication has "https://litcal.johnromanodorazio.com/auth/callback.php" \
    "production update still sends the production callback" -- \
    --target production --provision-litcal-frontend

existing_apps "LiturgicalCalendarFrontend (Staging)"
expect_payload UpdateApplication lacks "https://litcal.johnromanodorazio.com/auth/callback.php" \
    "staging update targets the Staging app and never sends the production callback" -- \
    --target staging --provision-litcal-frontend

existing_apps "CDCF Website (Non-Prod)"
expect_payload UpdateApplication lacks "localhost:3000" \
    "CDCF staging update strips localhost from the non-prod app" -- \
    --target staging --provision-cdcf-website

existing_apps "CDCF Website (Non-Prod)"
expect_payload UpdateApplication has '"devMode": false' \
    "CDCF staging update sends devMode=false — HTTPS-only needs no dev mode" -- \
    --target staging --provision-cdcf-website

existing_apps "CDCF Website"
expect_payload UpdateApplication has "https://catholicdigitalcommons.org/api/auth/callback/zitadel" \
    "CDCF production update sends the production callback" -- \
    --target production --provision-cdcf-website

existing_apps "CDCF Website"
expect_payload UpdateApplication has '"devMode": true' \
    "CDCF local update sends devMode=true, which the HTTP callback requires" -- \
    ENV_FILE=.env.local.cdcf-website --target local --provision-cdcf-website

# The name filter is how the target picks WHICH app to touch. If it regressed,
# a staging run would find and then overwrite the production app.
existing_apps "CDCF Website (Non-Prod)"
expect_payload ListApplications has '"name":"CDCF Website (Non-Prod)"' \
    "staging looks up the Non-Prod app by name, not the production one" -- \
    --target staging --provision-cdcf-website

existing_apps
echo
if [[ "$FAILURES" -gt 0 ]]; then
    echo "${R}[selftest] $FAILURES of $((PASSES + FAILURES)) case(s) FAILED.${N}"
    exit 1
fi
echo "${G}[selftest] all $PASSES case(s) behaved as declared.${N}"
exit 0
