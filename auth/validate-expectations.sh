#!/usr/bin/env bash
#
# validate-expectations.sh — validate auth/models/*.json against every
# consumer's declared expectations.
#
# Centralizing OpenFGA model ownership in this repo (see PR #26) turned each
# consumer's own contract test into something that asserts against a model
# this repo provisions. Left unchecked, a model change here can merge, sync
# to the VPS, and only surface as a consumer's test failure later — and that
# consumer test skips outright when no store is configured, so its CI can be
# green while verifying nothing. This script is the provider-side half: it
# fetches each consumer's published expectations file and checks the model
# they depend on against it, so a breaking change fails in this repo's CI,
# in the PR that causes it.
#
# Consumers are consumer-authored and consumer-hosted: this script only ever
# reads auth/models/consumers.json and the URLs it points at, and never
# writes an expectations file itself. The expectations schema:
#
#   {
#     "consumer": "SomeConsumer",
#     "store": "SomeStore",
#     "required_types": ["type_a", "type_b"],
#     "required_relations": { "type_a": ["admin", "viewer"] },
#     "forbidden_types": ["legacy_type"],
#     "forbidden_relations": { "*": ["deleter"] },
#     "relation_includes": { "*": { "editor": ["admin"] } }
#   }
#
# "*" as a type key in required_relations / forbidden_relations /
# relation_includes means "every type in the model that defines at least one
# relation" (a type like `user`, with no relations block at all, is never a
# match for a wildcard — there is nothing on it to require, forbid, or check
# a rewrite of). relation_includes asserts that the named relation's rewrite
# contains a computedUserset targeting each listed relation, on the SAME
# object — a direct computedUserset, or one reachable only by descending
# through union/intersection/difference combinators. A type that does not
# define the named relation at all is skipped for that check (there is
# nothing to include or fail to include).
#
# relation_includes deliberately does NOT descend into tupleToUserset
# subtrees, even though a tupleToUserset node's own computedUserset also
# names a relation. "editor from governed_by" (a TTU) and a same-object
# `union` child naming `editor` are different authorization semantics: the
# TTU grants whatever `editor` is on a *different* object reached through
# the tupleset, not `editor` on this object. Matching inside a TTU would let
# a consumer's "viewer must include editor" pass against a model that only
# inherits `editor` from elsewhere — a false pass, which for a contract
# validator is worse than a false failure (a false failure gets looked at; a
# false pass does not). If a consumer needs to assert TTU-based inheritance,
# that wants its own rule, not a loosened relation_includes.
#
# An empty auth/models/consumers.json is a pass, not a skip: with no
# consumers registered there is nothing to contradict, so the check is
# trivially satisfied. The script says so explicitly rather than exiting 0
# silently, because a silent pass and "nothing was checked" look identical
# from the caller's side otherwise.
#
# Every violation is reported, not just the first — an operator fixing a
# model wants the whole list in one pass, not one failure per CI run.
#
# A fetch failure (network error, non-2xx, or unparseable JSON) is reported
# and fails the run distinctly from a violation: an expectations file this
# script could not retrieve is a contract that could not be verified, which
# is never the same as a contract that was checked and found satisfied.
#
# Usage:
#   ./validate-expectations.sh
#       Reads auth/models/consumers.json, fetches every consumer's
#       expectations_url, and validates auth/models/<store>.json for each.
#
#   ./validate-expectations.sh --expectations-file PATH --store NAME
#       Validates a single local expectations file against
#       auth/models/NAME.json, with no network access. Used by this
#       script's own fixture tests under auth/models/testdata/.
#
# Requires: bash >= 4, curl, jq.
#
# Exit codes: 0 all consumers' expectations satisfied (including an empty
#   registry); 1 one or more expectations violated; 2 one or more consumers'
#   expectations files could not be fetched or parsed (never combined with
#   1's meaning — see above); 3 a referenced model file is missing; 64 usage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="${SCRIPT_DIR}/models"
CONSUMERS_FILE="${MODELS_DIR}/consumers.json"

EXIT_VIOLATION=1
EXIT_FETCH=2
EXIT_MODEL_MISSING=3
EXIT_USAGE=64

if [[ -t 2 ]]; then
    R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; B=$'\033[0;34m'; N=$'\033[0m'
else
    R=""; G=""; Y=""; B=""; N=""
fi

log()  { echo "${B}[validate-expectations]${N} $*" >&2; }
ok()   { echo "${G}    ✓${N} $*" >&2; }
warn() { echo "${Y}    ⚠${N} $*" >&2; }
err()  { echo "${R}    ✗${N} $*" >&2; }

usage() {
    cat >&2 <<EOF
Usage: $0 [--expectations-file PATH --store NAME]

With no arguments, validates every consumer registered in
auth/models/consumers.json against auth/models/<store>.json, fetching each
consumer's expectations_url over HTTPS.

  --expectations-file PATH   Validate this local expectations file instead
                              of fetching one. Must be paired with --store.
  --store NAME                Model to validate against is auth/models/NAME.json.
                              Must be paired with --expectations-file.

Exit codes: 0 pass, 1 violation(s) found, 2 could not fetch/parse an
expectations file, 3 model file missing, 64 usage.
EOF
    exit "$EXIT_USAGE"
}

EXP_FILE_ARG=""
STORE_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --expectations-file) [[ $# -ge 2 ]] || usage; EXP_FILE_ARG="$2"; shift 2 ;;
        --store)             [[ $# -ge 2 ]] || usage; STORE_ARG="$2"; shift 2 ;;
        -h|--help)           usage ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
    esac
done

if [[ -n "$EXP_FILE_ARG" || -n "$STORE_ARG" ]]; then
    [[ -n "$EXP_FILE_ARG" && -n "$STORE_ARG" ]] || usage
fi

# --- jq validation program --------------------------------------------------
#
# Takes $exp (the expectations object) and $model (the OpenFGA model object)
# and emits a JSON array of violation message strings — empty when clean.
# Single jq invocation per (consumer, model) pair rather than one invocation
# per rule: the model file is small, jq is fast, and this keeps the five rule
# checks' relationship to each other (they all resolve "*" the same way)
# expressed once instead of five times over in bash.
read -r -d '' VALIDATE_JQ <<'JQ_PROGRAM' || true
def relsOf($t):
  ([$model.type_definitions[] | select(.type == $t) | .relations] | first) // {};

def modelTypes:
  [$model.type_definitions[]?.type];

def wildcardTypes:
  [$model.type_definitions[] | select(.relations != null) | .type];

def typesForKey($k):
  if $k == "*" then wildcardTypes else [$k] end;

# includesRelation walks only same-object combinators (union, intersection,
# difference) looking for a direct computedUserset on $target. It must NOT
# descend into tupleToUserset: a TTU's computedUserset names a relation on a
# *different* object reached via the tupleset, not an inclusion of that
# relation on this object — see the header comment for why conflating the
# two is a false pass, not a harmless broadening.
def includesRelation($rewrite; $target):
  if ($rewrite | type) != "object" then
    false
  elif $rewrite | has("computedUserset") then
    $rewrite.computedUserset.relation == $target
  elif $rewrite | has("union") then
    ($rewrite.union.child // []) | any(includesRelation(.; $target))
  elif $rewrite | has("intersection") then
    ($rewrite.intersection.child // []) | any(includesRelation(.; $target))
  elif $rewrite | has("difference") then
    includesRelation($rewrite.difference.base; $target)
      or includesRelation($rewrite.difference.subtract; $target)
  else
    false
  end;

(
  [ ($exp.required_types // [])[] as $t
    | select((modelTypes | index($t)) == null)
    | "required_types: type \"" + $t + "\" not found in model"
  ]
) as $v1
|
(
  [ ($exp.forbidden_types // [])[] as $t
    | select((modelTypes | index($t)) != null)
    | "forbidden_types: type \"" + $t + "\" is present in model but forbidden"
  ]
) as $v2
|
(
  [ ($exp.required_relations // {}) | keys[] as $k
    | typesForKey($k)[] as $t
    | ($exp.required_relations[$k][]) as $rel
    | select((relsOf($t) | has($rel)) | not)
    | "required_relations: type \"" + $t + "\" missing required relation \"" + $rel + "\""
  ]
) as $v3
|
(
  [ ($exp.forbidden_relations // {}) | keys[] as $k
    | typesForKey($k)[] as $t
    | ($exp.forbidden_relations[$k][]) as $rel
    | select(relsOf($t) | has($rel))
    | "forbidden_relations: type \"" + $t + "\" has forbidden relation \"" + $rel + "\""
  ]
) as $v4
|
(
  [ ($exp.relation_includes // {}) | keys[] as $k
    | typesForKey($k)[] as $t
    | (relsOf($t)) as $rels
    | ($exp.relation_includes[$k] | keys[]) as $namedRel
    | select($rels | has($namedRel))
    | ($exp.relation_includes[$k][$namedRel][]) as $target
    | select(includesRelation($rels[$namedRel]; $target) | not)
    | "relation_includes: type \"" + $t + "\" relation \"" + $namedRel + "\" does not include \"" + $target + "\" via computedUserset"
  ]
) as $v5
|
$v1 + $v2 + $v3 + $v4 + $v5
JQ_PROGRAM

# validate_one EXP_FILE MODEL_FILE CONSUMER STORE
#
# Prints every violation (prefixed with consumer and store) to stderr via
# err, and echoes the violation count to stdout. Caller decides what a
# nonzero count means for the overall exit code.
validate_one() {
    local exp_file="$1" model_file="$2" consumer="$3" store="$4"
    local violations count

    if ! violations=$(jq -n --slurpfile exp "$exp_file" --slurpfile model "$model_file" \
            '($exp[0]) as $exp | ($model[0]) as $model | '"$VALIDATE_JQ" 2>&1); then
        err "[$consumer/$store] internal error evaluating expectations: $violations"
        echo "-1"
        return
    fi

    count=$(echo "$violations" | jq 'length')
    if [[ "$count" -gt 0 ]]; then
        echo "$violations" | jq -r '.[]' | while IFS= read -r line; do
            err "[$consumer/$store] $line"
        done
    fi
    echo "$count"
}

# --- single-file mode --------------------------------------------------------

if [[ -n "$EXP_FILE_ARG" ]]; then
    [[ -f "$EXP_FILE_ARG" ]] || { echo "Expectations file not found: $EXP_FILE_ARG" >&2; exit "$EXIT_USAGE"; }
    MODEL_FILE="${MODELS_DIR}/${STORE_ARG}.json"
    [[ -f "$MODEL_FILE" ]] || { err "Model file not found: $MODEL_FILE"; exit "$EXIT_MODEL_MISSING"; }

    CONSUMER=$(jq -r '.consumer // "unknown"' "$EXP_FILE_ARG")
    log "Validating auth/models/${STORE_ARG}.json against $EXP_FILE_ARG (consumer: $CONSUMER)"

    COUNT=$(validate_one "$EXP_FILE_ARG" "$MODEL_FILE" "$CONSUMER" "$STORE_ARG")
    if [[ "$COUNT" == "-1" ]]; then
        exit "$EXIT_FETCH"
    elif [[ "$COUNT" -gt 0 ]]; then
        err "$COUNT violation(s) found."
        exit "$EXIT_VIOLATION"
    fi
    ok "No violations. $STORE_ARG satisfies $CONSUMER's expectations."
    exit 0
fi

# --- registry mode -----------------------------------------------------------

[[ -f "$CONSUMERS_FILE" ]] || { err "Registry not found: $CONSUMERS_FILE"; exit "$EXIT_MODEL_MISSING"; }

if ! jq -e . "$CONSUMERS_FILE" >/dev/null 2>&1; then
    err "Registry is not valid JSON: $CONSUMERS_FILE"
    exit "$EXIT_USAGE"
fi

NUM_CONSUMERS=$(jq 'length' "$CONSUMERS_FILE")

if [[ "$NUM_CONSUMERS" -eq 0 ]]; then
    ok "auth/models/consumers.json has no registered consumers — there is nothing to contradict, so every model trivially satisfies an empty contract set. Pass."
    exit 0
fi

log "Validating models against $NUM_CONSUMERS registered consumer(s)."

TOTAL_VIOLATIONS=0
FETCH_FAILURES=0

for i in $(seq 0 $((NUM_CONSUMERS - 1))); do
    ENTRY=$(jq -c ".[$i]" "$CONSUMERS_FILE")
    CONSUMER=$(echo "$ENTRY" | jq -r '.consumer')
    STORE=$(echo "$ENTRY" | jq -r '.store')
    URL=$(echo "$ENTRY" | jq -r '.expectations_url')

    MODEL_FILE="${MODELS_DIR}/${STORE}.json"
    if [[ ! -f "$MODEL_FILE" ]]; then
        err "[$CONSUMER/$STORE] model file not found: $MODEL_FILE"
        exit "$EXIT_MODEL_MISSING"
    fi

    log "Fetching expectations for $CONSUMER ($STORE) from $URL"

    TMP_EXP=$(mktemp)
    TMP_ERR=$(mktemp)

    HTTP_STATUS=$(curl -sS -o "$TMP_EXP" -w '%{http_code}' --connect-timeout 10 --max-time 30 "$URL" 2>"$TMP_ERR") || {
        err "[$CONSUMER/$STORE] could not fetch expectations (transport error): $URL"
        [[ -s "$TMP_ERR" ]] && err "  $(cat "$TMP_ERR")"
        rm -f "$TMP_ERR" "$TMP_EXP"
        FETCH_FAILURES=$((FETCH_FAILURES + 1))
        continue
    }
    rm -f "$TMP_ERR"

    if [[ ! "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
        err "[$CONSUMER/$STORE] could not fetch expectations: HTTP $HTTP_STATUS from $URL"
        rm -f "$TMP_EXP"
        FETCH_FAILURES=$((FETCH_FAILURES + 1))
        continue
    fi

    if ! jq -e . "$TMP_EXP" >/dev/null 2>&1; then
        err "[$CONSUMER/$STORE] could not parse expectations as JSON: $URL"
        rm -f "$TMP_EXP"
        FETCH_FAILURES=$((FETCH_FAILURES + 1))
        continue
    fi

    COUNT=$(validate_one "$TMP_EXP" "$MODEL_FILE" "$CONSUMER" "$STORE")
    rm -f "$TMP_EXP"

    if [[ "$COUNT" == "-1" ]]; then
        FETCH_FAILURES=$((FETCH_FAILURES + 1))
    elif [[ "$COUNT" -gt 0 ]]; then
        TOTAL_VIOLATIONS=$((TOTAL_VIOLATIONS + COUNT))
    else
        ok "[$CONSUMER/$STORE] satisfied."
    fi
done

if [[ "$TOTAL_VIOLATIONS" -gt 0 && "$FETCH_FAILURES" -gt 0 ]]; then
    err "$TOTAL_VIOLATIONS expectations violation(s) violated, and $FETCH_FAILURES consumer(s)' expectations could not be fetched. An unfetched contract is unverified, not satisfied."
    exit "$EXIT_VIOLATION"
elif [[ "$TOTAL_VIOLATIONS" -gt 0 ]]; then
    err "$TOTAL_VIOLATIONS expectations violation(s) found."
    exit "$EXIT_VIOLATION"
elif [[ "$FETCH_FAILURES" -gt 0 ]]; then
    err "$FETCH_FAILURES consumer(s)' expectations could not be fetched — contract unverified, treated as a failure, distinct from a violation."
    exit "$EXIT_FETCH"
fi

ok "All $NUM_CONSUMERS consumer(s)' expectations satisfied."
exit 0
