#!/usr/bin/env bash
#
# validate-expectations.selftest.sh — run auth/validate-expectations.sh
# against every fixture under auth/models/testdata/ and assert the exact
# outcome each one is supposed to produce.
#
# Why this exists: the CI workflow runs the validator in registry mode, and
# auth/models/consumers.json is legitimately empty, so CI's entire coverage
# of the validator was "an empty registry passes" — not one line of the
# rewrite walk, the wildcard resolution or the schema check ran. Every fix to
# that walk so far has been a false pass (a contract reported satisfied when
# it was not), which is exactly the failure a green-but-vacuous check hides.
# This script is what makes the fixtures load-bearing: each case names the
# exit code it must produce AND a substring its output must contain, so a
# regression that fails for the wrong reason does not count as a pass either.
#
# Each fixture's own "_comment" says what invariant it pins. Run it from
# anywhere:  ./auth/validate-expectations.selftest.sh
#
# Exit codes: 0 every case behaved as declared; 1 one or more did not.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="${SCRIPT_DIR}/validate-expectations.sh"
TD="${SCRIPT_DIR}/models/testdata"

if [[ -t 1 ]]; then
    R=$'\033[0;31m'; G=$'\033[0;32m'; B=$'\033[0;34m'; N=$'\033[0m'
else
    R=""; G=""; B=""; N=""
fi

PASSES=0
FAILURES=0

# expect EXPECTED_EXIT EXPECTED_SUBSTRING DESCRIPTION -- ARGS...
expect() {
    local want_exit="$1" want_text="$2" desc="$3"; shift 3
    [[ "$1" == "--" ]] && shift

    local out got_exit
    out=$("$VALIDATOR" "$@" 2>&1)
    got_exit=$?

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

echo "${B}[selftest]${N} $VALIDATOR"
echo "${B}[selftest]${N} --- the model-shaped contract cases ---"

expect 0 "No violations" \
    "valid fixture: LiturgicalCalendar satisfies LitCal's real invariants" -- \
    --expectations-file "$TD/expectations-valid.json" --store LiturgicalCalendar

expect 1 "5 violation(s) found" \
    "violating fixture: one violation for each of the five rules" -- \
    --expectations-file "$TD/expectations-violating.json" --store LiturgicalCalendar

echo "${B}[selftest]${N} --- relation_includes sufficiency boundaries ---"

expect 1 'relation "can_edit" does not include "editor"' \
    "TTU boundary: tupleToUserset is a different object, not same-object inclusion" -- \
    --expectations-file "$TD/expectations-ttu-boundary.json" --store Martyrology

expect 1 'relation "viewer" does not include "admin"' \
    "difference boundary: reachable only via subtract is excluded, not included" -- \
    --expectations-file "$TD/expectations-difference-boundary.json" \
    --model-file "$TD/difference-boundary-model.json"

expect 1 'relation "needs_both" does not include "admin"' \
    "intersection boundary: target must be in EVERY branch, not just one" -- \
    --expectations-file "$TD/expectations-intersection-boundary-fail.json" \
    --model-file "$TD/intersection-boundary-model.json"

expect 0 "No violations" \
    "intersection companion: target in every branch IS sufficient, still passes" -- \
    --expectations-file "$TD/expectations-intersection-boundary-pass.json" \
    --model-file "$TD/intersection-boundary-model.json"

expect 1 'no type in scope defines relation "nonexistent_rel"' \
    "named relation absent model-wide is a violation, not a vacuous pass" -- \
    --expectations-file "$TD/expectations-missing-named-relation.json" --store LiturgicalCalendar

echo "${B}[selftest]${N} --- \"*\" wildcard scope ---"

expect 1 'type "national_calendar" missing required relation "admin"' \
    "wildcard scope: a type with NO relations block fails, not skipped" -- \
    --expectations-file "$TD/expectations-wildcard-scope.json" \
    --model-file "$TD/wildcard-scope-model.json"

expect 0 "No violations" \
    "wildcard scope: undeclared bare types stay out of scope, still passes" -- \
    --expectations-file "$TD/expectations-wildcard-scope-pass.json" \
    --model-file "$TD/wildcard-scope-model.json"

# Both halves of the requirement/prohibition split are pinned here, and they
# are pinned against the SAME fixture on purpose: a uniform "*" — whichever
# way it is unified — breaks exactly one of these two cases. Scope both to
# required_types and the first fails (secret_thing is never reached); scope
# both to the whole model and the second fails (secret_thing.editor adds a
# second violation). Neither can be made to pass by weakening the other.
echo "${B}[selftest]${N} --- \"*\" is a requirement's scope, not a prohibition's ---"

expect 1 'forbidden_relations: type "secret_thing" has forbidden relation "deleter"' \
    "prohibition: \"*\" is the whole model, reaching a type outside required_types" -- \
    --expectations-file "$TD/expectations-forbidden-scope.json" \
    --model-file "$TD/forbidden-scope-model.json"

expect 1 "1 violation(s) found" \
    "requirement: \"*\" stays scoped to required_types — exactly one violation, not two" -- \
    --expectations-file "$TD/expectations-forbidden-scope.json" \
    --model-file "$TD/forbidden-scope-model.json"

echo "${B}[selftest]${N} --- expectations schema, distinct from a violation ---"

expect 64 "not valid JSON (or is empty)" \
    "empty expectations file is rejected, not reported as satisfied" -- \
    --expectations-file "$TD/malformed-empty.json" --store LiturgicalCalendar

expect 64 "top level is null" \
    "null expectations file is rejected, not reported as satisfied" -- \
    --expectations-file "$TD/malformed-null.json" --store LiturgicalCalendar

expect 64 "top level is array" \
    "array-rooted file is rejected in the documented scheme, not jq's exit 5" -- \
    --expectations-file "$TD/malformed-array.json" --store LiturgicalCalendar

expect 64 'unknown top-level key "required_relation"' \
    "typo'd rule keys are rejected, not silently ignored" -- \
    --expectations-file "$TD/expectations-typo-key.json" --store LiturgicalCalendar

expect 64 "declares no rule keys at all" \
    "a contract asserting nothing is rejected, not reported as satisfied" -- \
    --expectations-file "$TD/expectations-no-rules.json" --store LiturgicalCalendar

echo "${B}[selftest]${N} --- operational exits ---"

expect 3 "Model file not found" \
    "missing model file exits 3, distinct from a violation" -- \
    --expectations-file "$TD/expectations-valid.json" --store NoSuchStore

expect 64 "Expectations file not found" \
    "missing expectations file exits 64" -- \
    --expectations-file "$TD/no-such-fixture.json" --store LiturgicalCalendar

expect 64 "mutually exclusive" \
    "--store and --model-file together is a usage error" -- \
    --expectations-file "$TD/expectations-valid.json" --store LiturgicalCalendar \
    --model-file "$TD/wildcard-scope-model.json"

echo
if [[ "$FAILURES" -gt 0 ]]; then
    echo "${R}[selftest] $FAILURES of $((PASSES + FAILURES)) case(s) FAILED.${N}"
    exit 1
fi
echo "${G}[selftest] all $PASSES case(s) behaved as declared.${N}"
exit 0
