#!/usr/bin/env bash
#
# setup-openfga.selftest.sh — run auth/setup-openfga.sh against a stub OpenFGA
# and assert the exact exit code each failure is supposed to produce.
#
# Why this exists: setup-openfga.sh had no automated coverage at all. Its
# header documents an exit-code contract that operators are meant to act on —
# 7 means "a deployed model diverged from this repo, investigate before doing
# anything", 9 means "the call did not succeed and says nothing about what the
# store now holds" — and those call for opposite responses. Nothing checked it,
# and it drifted: the header claimed 7 was "upload_model_if_changed only — no
# other site uses this code" while two sites in seed_tuples_if_present also
# exited 7 (issue #27). A comment cannot enforce a contract; this can.
#
# Every case therefore names the exit code it must produce AND a substring its
# output must contain, so a regression that fails for the wrong reason does not
# count as a pass either — same rule as validate-expectations.selftest.sh.
#
# How it works: MODELS_DIR is derived from the script's own location, so each
# case runs a COPY of setup-openfga.sh inside a scratch sandbox whose models/
# holds throwaway fixtures. The stub speaks only the endpoints the script
# touches, and its behaviour is selected per case, which is how failures that
# need a misbehaving server (a 2xx whose body is still an error, a 500, a
# malformed listing) are reachable at all.
#
# Not covered, deliberately: exit 70 (EXIT_INTERNAL), the write-count mismatch.
# It is unreachable by construction — `written` accumulates the same jq slice
# lengths the loop bounds iterate over, and the loop's only early exits abort
# outright — so no server behaviour can provoke it. Reaching it would mean
# editing the script under test, which would no longer be testing the script.
#
# Requires python3 (preinstalled on ubuntu-latest, used for the stub only).
# Run it from anywhere:  ./auth/setup-openfga.selftest.sh
#
# Exit codes: 0 every case behaved as declared; 1 one or more did not.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/setup-openfga.sh"

if [[ -t 1 ]]; then
    R=$'\033[0;31m'; G=$'\033[0;32m'; B=$'\033[0;34m'; N=$'\033[0m'
else
    R=""; G=""; B=""; N=""
fi

PASSES=0
FAILURES=0

# Preflight: the harness has its own tool needs, separate from the script under
# test. Missing any of them would surface as cases failing on their assertions,
# which reads as "setup-openfga.sh is broken" — the one conclusion this script
# exists to make trustworthy. Fail up front and say which tool instead.
for tool in python3:"the stub OpenFGA" jq:"writing lock fixtures" curl:"probing the stub"; do
    command -v "${tool%%:*}" >/dev/null 2>&1 || {
        echo "${R}[selftest] ${tool%%:*} is required (${tool#*:}).${N}" >&2
        exit 1
    }
done
[[ -f "$TARGET" ]] || { echo "${R}[selftest] not found: $TARGET${N}" >&2; exit 1; }

SANDBOX="$(mktemp -d)"
STUB_PID=""
cleanup() {
    [[ -n "$STUB_PID" ]] && kill "$STUB_PID" 2>/dev/null
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

STORE_ID="01TESTSTORE0000000000000000"
MODEL_ID="01TESTMODEL0000000000000000"
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"

# --- sandbox ---------------------------------------------------------------

cp "$TARGET" "$SANDBOX/setup-openfga.sh"
chmod +x "$SANDBOX/setup-openfga.sh"
mkdir -p "$SANDBOX/models"

cat > "$SANDBOX/.env.local" <<EOF
OPENFGA_API_URL=http://127.0.0.1:${PORT}
OPENFGA_INTERNAL_URL=http://127.0.0.1:${PORT}
OPENFGA_PRESHARED_KEY=stub-key
EOF

# Must normalize equal to the model the stub serves, or every case would take
# the "model differs" path and never reach what it is actually testing.
cat > "$SANDBOX/models/TestStore.json" <<'EOF'
{
  "schema_version": "1.1",
  "type_definitions": [
    { "type": "user" },
    {
      "type": "widget",
      "relations": { "owner": { "this": {} } },
      "metadata": {
        "relations": {
          "owner": { "directly_related_user_types": [{ "type": "user" }] }
        }
      }
    }
  ],
  "conditions": {}
}
EOF

cat > "$SANDBOX/models/TestStore.tuples.json" <<'EOF'
{ "tuples": [ { "user": "user:alice", "relation": "owner", "object": "widget:one" } ] }
EOF

cat > "$SANDBOX/stub.py" <<'PYEOF'
"""Stub OpenFGA. Serves only what setup-openfga.sh calls; SCENARIO picks the
failure under test."""
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

STORE_ID = os.environ["STUB_STORE_ID"]
MODEL_ID = os.environ["STUB_MODEL_ID"]
SCENARIO = os.environ["STUB_SCENARIO"]

TYPES = [
    {"type": "user"},
    {
        "type": "widget",
        "relations": {"owner": {"this": {}}},
        "metadata": {
            "relations": {"owner": {"directly_related_user_types": [{"type": "user"}]}}
        },
    },
]
TUPLE = {"user": "user:alice", "relation": "owner", "object": "widget:one"}


def model(mid, types=None):
    return {
        "id": mid,
        "schema_version": "1.1",
        "type_definitions": TYPES if types is None else types,
        "conditions": {},
    }


class H(BaseHTTPRequestHandler):
    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return  # keep the selftest's output readable

    def do_GET(self):
        if self.path.startswith("/stores"):
            if "/authorization-models" in self.path:
                if SCENARIO == "models-500":
                    return self._send(500, {"code": "internal", "message": "boom"})
                if SCENARIO == "models-malformed":
                    return self._send(200, {"authorization_models": None})
                if SCENARIO == "no-model":
                    return self._send(200, {"authorization_models": []})
                if SCENARIO == "model-differs":
                    # Same id is irrelevant here; the CONTENT differs, which is
                    # what drives the upload/guard decision.
                    return self._send(
                        200,
                        {"authorization_models": [model(MODEL_ID, [{"type": "user"}])]},
                    )
                return self._send(200, {"authorization_models": [model(MODEL_ID)]})
            if SCENARIO == "stores-500":
                return self._send(500, {"code": "internal", "message": "boom"})
            if SCENARIO == "no-stores":
                return self._send(200, {"stores": [], "continuation_token": ""})
            if SCENARIO == "dup-stores":
                return self._send(
                    200,
                    {
                        "stores": [
                            {"id": STORE_ID, "name": "TestStore"},
                            {"id": "01OTHERSTORE000000000000000", "name": "TestStore"},
                        ],
                        "continuation_token": "",
                    },
                )
            return self._send(
                200,
                {
                    "stores": [{"id": STORE_ID, "name": "TestStore"}],
                    "continuation_token": "",
                },
            )
        return self._send(404, {"code": "not_found", "message": self.path})

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path.endswith("/read"):
            if SCENARIO == "tuples-present":
                return self._send(
                    200, {"tuples": [{"key": TUPLE}], "continuation_token": ""}
                )
            return self._send(200, {"tuples": [], "continuation_token": ""})
        if self.path.endswith("/write"):
            if SCENARIO == "reject-write":
                # The case the :690 site exists for: 2xx, body still an error.
                return self._send(
                    200, {"code": "validation_error", "message": "stubbed rejection"}
                )
            if SCENARIO == "write-500":
                return self._send(500, {"code": "internal", "message": "boom"})
            return self._send(200, {})
        if self.path.endswith("/authorization-models"):
            return self._send(201, {"authorization_model_id": "01UPLOADED000000000000000000"})
        if self.path == "/stores":
            return self._send(201, {"id": STORE_ID, "name": "TestStore"})
        return self._send(404, {"code": "not_found", "message": self.path})


HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF

# --- harness ---------------------------------------------------------------

set_lock() {  # set_lock MODEL_ID [STORE_ID]
    local mid="$1" sid="${2:-$STORE_ID}"
    jq -n --arg s "$sid" --arg m "$mid" \
        '{store_name: "TestStore", store_id: $s, model_id: $m}' \
        > "$SANDBOX/models/TestStore.lock.json"
}
clear_lock() { rm -f "$SANDBOX/models/TestStore.lock.json"; }

start_stub() {
    STUB_SCENARIO="$1" STUB_STORE_ID="$STORE_ID" STUB_MODEL_ID="$MODEL_ID" \
        python3 "$SANDBOX/stub.py" "$PORT" >"$SANDBOX/stub.log" 2>&1 &
    STUB_PID=$!
    local i
    for i in $(seq 1 50); do
        # Readiness is "something answered on the port", NOT "answered 2xx" —
        # several scenarios serve 500 deliberately, and a `curl -sf` probe would
        # call those stubs dead, then leak the process holding the port and take
        # every later case down with it.
        curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${PORT}/stores" && return 0
        sleep 0.1
    done
    stop_stub
    return 1
}

stop_stub() {
    [[ -n "$STUB_PID" ]] && kill "$STUB_PID" 2>/dev/null
    wait "$STUB_PID" 2>/dev/null
    STUB_PID=""
}

# expect EXPECTED_EXIT EXPECTED_SUBSTRING SCENARIO DESCRIPTION -- ARGS...
expect() {
    local want_exit="$1" want_text="$2" scenario="$3" desc="$4"; shift 4
    [[ "$1" == "--" ]] && shift

    if ! start_stub "$scenario"; then
        echo "${R}  FAIL${N}  $desc"
        echo "        stub failed to start on port $PORT"
        FAILURES=$((FAILURES + 1))
        return
    fi

    local out got_exit
    out=$(cd "$SANDBOX" && ./setup-openfga.sh "$@" 2>&1)
    got_exit=$?
    stop_stub

    local problem=""
    if [[ "$got_exit" -ne "$want_exit" ]]; then
        problem="expected exit $want_exit, got $got_exit"
    elif [[ "$out" != *"$want_text"* ]]; then
        problem="exit $got_exit as expected, but output did not contain: $want_text"
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

echo "${B}[selftest]${N} $TARGET"
echo "${B}[selftest]${N} --- 7 is the lock guard's code, and nothing else's ---"

set_lock "01ADIFFERENTMODEL0000000000"
expect 7 "Refusing to touch the model" ok \
    "same-store lock mismatch: the guard refuses, exit 7" -- \
    --target local --create-store TestStore

set_lock "01ADIFFERENTMODEL0000000000"
expect 0 "proceeding anyway" ok \
    "--force-model-upload overrides the guard rather than being ignored" -- \
    --target local --create-store TestStore --force-model-upload

clear_lock
expect 7 "This repo has no record of uploading that model" model-differs \
    "unknown store whose model differs refuses, exit 7" -- \
    --target local --create-store TestStore

clear_lock
expect 0 "No lock file yet" ok \
    "unknown store whose model matches adopts the lock and reports it" -- \
    --target local --create-store TestStore

set_lock "$MODEL_ID" "01SOMEOTHERSTORE00000000000"
expect 0 "guard bypassed" ok \
    "a lock scoped to another store is foreign: bypassed, not fired" -- \
    --target local --create-store TestStore

echo "${B}[selftest]${N} --- tuple seeding failures are API failures, not guard refusals ---"

clear_lock
expect 9 "Tuple write rejected by OpenFGA" reject-write \
    "a 2xx whose body still carries an error is exit 9, not 7 (issue #27)" -- \
    --target local --seed-tuples TestStore

expect 9 "Tuple write failed" write-500 \
    "a non-2xx on write is exit 9" -- \
    --target local --seed-tuples TestStore

expect 0 "Wrote 1 new structural tuple" ok \
    "the happy path still seeds and reports success" -- \
    --target local --seed-tuples TestStore

expect 0 "already present" tuples-present \
    "an already-seeded store writes nothing and still succeeds" -- \
    --target local --seed-tuples TestStore

echo "${B}[selftest]${N} --- API failures never masquerade as a verdict about state ---"

expect 9 "Could not list stores" stores-500 \
    "a failed store listing aborts rather than concluding the store is absent" -- \
    --target local --create-store TestStore

expect 9 "Could not read the authorization models" models-500 \
    "a failed model read aborts rather than concluding there is no model" -- \
    --target local --create-store TestStore

expect 9 "Unexpected body" models-malformed \
    "a null authorization_models is malformed, not an empty list" -- \
    --target local --create-store TestStore

expect 8 "Found 2 stores named" dup-stores \
    "two stores sharing a name is exit 8, not a silent pick" -- \
    --target local --create-store TestStore

echo "${B}[selftest]${N} --- pre-flight and usage exits ---"

expect 3 "Store not found:" no-stores \
    "--seed-tuples against a store that does not exist is exit 3" -- \
    --target local --seed-tuples TestStore

expect 4 "Model file not found" ok \
    "a missing model file is exit 4, distinct from a guard refusal" -- \
    --target local --create-store NoSuchStore

expect 6 "Tuples file not found" ok \
    "a missing tuples file under --seed-tuples is exit 6" -- \
    --target local --seed-tuples NoSuchStore

expect 64 "Usage" ok \
    "a target with no action is a usage error, not a no-op success" -- \
    --target local

expect 64 "Unknown target" ok \
    "an unknown target is rejected" -- \
    --target nowhere --create-store TestStore

echo
if [[ "$FAILURES" -gt 0 ]]; then
    echo "${R}[selftest] $FAILURES of $((PASSES + FAILURES)) case(s) FAILED.${N}"
    exit 1
fi
echo "${G}[selftest] all $PASSES case(s) behaved as declared.${N}"
exit 0
