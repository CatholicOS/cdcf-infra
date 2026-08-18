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

cat > "$SANDBOX/stub.py" <<'PYEOF'
"""Stub Zitadel. Serves only what setup-zitadel.sh calls.

Always reports zero existing applications, so every run takes the
CreateApplication path and the script prints the origins it registered —
which is what the selftest asserts against.
"""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

ORGS = ["CDCF", "LiturgicalCalendar", "BibleGet", "OntoKit", "Martyrology"]


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
        self.rfile.read(n)
        p = self.path
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
            # Always "no such app yet" -> CreateApplication path.
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

start_stub() {
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

# expect EXPECTED_EXIT MODE PATTERN DESCRIPTION -- ARGS...
#   MODE: has  -> output MUST contain PATTERN
#         lacks -> output must NOT contain PATTERN
expect() {
    local want_exit="$1" mode="$2" pattern="$3" desc="$4"; shift 4
    [[ "$1" == "--" ]] && shift

    local out got_exit
    out=$(cd "$SANDBOX" && ./setup-zitadel.sh "$@" 2>&1)
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

echo "${B}[selftest]${N} --- CDCF: one app per environment, no localhost in production Zitadel ---"

expect 0 has "http://localhost:3000/api/auth/callback/zitadel" \
    "local registers the localhost origin" -- \
    --target local --provision-cdcf-website

expect 0 has "devMode=true" \
    "local sets devMode, which the HTTP localhost callback requires" -- \
    --target local --provision-cdcf-website

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
    --target local --provision-martyrology-frontend

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
    --target local --all

echo "${B}[selftest]${N} --- usage exits are unchanged ---"

expect 64 has "Usage" \
    "a target with no action is still a usage error" -- \
    --target production

expect 64 has "Unknown target" \
    "an unknown target is still rejected" -- \
    --target nowhere --provision-cdcf-website

echo
if [[ "$FAILURES" -gt 0 ]]; then
    echo "${R}[selftest] $FAILURES of $((PASSES + FAILURES)) case(s) FAILED.${N}"
    exit 1
fi
echo "${G}[selftest] all $PASSES case(s) behaved as declared.${N}"
exit 0
