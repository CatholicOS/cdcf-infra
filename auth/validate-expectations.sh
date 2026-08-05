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
# The failure mode this script exists to avoid is a FALSE PASS — reporting a
# contract satisfied when it is not. A false violation is noisy and gets
# investigated; a false pass ships silently. Every design decision below
# resolves in that direction: when in doubt, report a problem.
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
# That schema is ENFORCED, not merely documented (see SCHEMA_JQ). An unknown
# top-level key is rejected rather than ignored, because `required_relation`
# or `relation_include` — singular, a plausible typo — would otherwise make a
# file its author believes asserts a contract assert nothing and report as
# satisfied. For the same reason a file declaring no rule key at all is
# rejected: a contract that asserts nothing must never be reported as a
# contract that holds. Schema rejection is reported and exits distinctly from
# a violation (see the exit codes below).
#
# "*" AS A TYPE KEY RESOLVES ASYMMETRICALLY, and the asymmetry is load-
# bearing — do not "simplify" the two call sites back into one:
#
#   - A REQUIREMENT (required_relations, relation_includes) is a claim about
#     the consumer's own declared surface — "the types I use must have these
#     relations" — so "*" is the types listed in required_types when the
#     consumer declared them, and every type in the model when they did not.
#   - A PROHIBITION (forbidden_relations) is a claim about the whole model —
#     "no type anywhere defines deleter" — so "*" is every type in the model,
#     unconditionally, whether or not required_types is present. Narrowing a
#     prohibition to the declared surface would let a type the consumer never
#     listed carry the forbidden relation and still report as satisfied,
#     which is the false-pass direction; a prohibition can only ever be
#     weakened by shrinking its scope.
#
# (forbidden_types is a plain list of type names, not a wildcard rule, and
# needs no scope of its own.)
#
# In either scope, a type that has NO relations block yields a violation for
# each relation required of it — it is emphatically not skipped. That is what
# keeps a bare type like `user` out of a requirement's scope for a consumer
# that never declared it, while making the deletion of an entire relations
# block fail loudly. (An earlier version resolved "*" to "types that have a
# relations block", which meant deleting one relation failed but deleting the
# whole block passed — the more destructive edit was the one that slipped
# through. The fix for that was then applied to prohibitions too, which
# produced the mirror-image false pass described above; hence the split.)
#
# relation_includes asserts a SUFFICIENT path: holding the target relation,
# on its own, is enough to hold the named relation. That is LitCal's real
# invariant — an admin can edit and view, because editor and viewer are
# unions including admin — and it is a sufficiency claim, not a necessity
# one. Within a scope, a type that does not define the named relation is
# skipped for that check (there is nothing there to include or fail to
# include) — but if NO type in scope defines the named relation at all, that
# is a violation, not a vacuous pass: the consumer named a relation the model
# does not have. Under an explicitly named type key rather than "*", a
# missing named relation on that type is likewise a violation.
#
# That one sufficiency rule is what the rewrite walk (see includesRelation's
# own comment for the full derivation) is built around, and it is also why
# the walk deliberately does NOT treat two constructs as inclusion:
#
#   - tupleToUserset is never descended into. "editor from governed_by" (a
#     TTU) grants whatever `editor` is on a *different* object reached
#     through the tupleset — holding `editor` there says nothing about
#     holding it on this object, so it is not a sufficient path here at all,
#     same-object or otherwise. If a consumer needs to assert TTU-based
#     inheritance, that wants its own rule, not a loosened relation_includes.
#   - Within `intersection` (R = A ∩ B, both required), the target must
#     appear in EVERY child, not just one: appearing in only A is a
#     necessary-but-not-sufficient condition for R, and reporting that as
#     inclusion is the same false-pass shape as the TTU case, one level
#     down. Within `difference` ("base, but not subtract"), a target
#     reachable only through `subtract` is being excluded, never a
#     sufficient path — inclusion requires `base` AND NOT `subtract`.
#   - computedUserset is compared by name only, one hop: it does not follow
#     the NAMED relation's own rewrite in turn. So a model where `viewer`
#     includes `editor` and `editor` (separately) includes `admin` will
#     report `viewer` as NOT including `admin` — a false VIOLATION, the
#     opposite failure mode from the two exclusions above, and one this
#     script's stated bias tolerates on purpose: it is noisy and gets
#     investigated, never silent. Making the walk transitive would need
#     cycle detection, and a rewrite graph can cycle; a mishandled cycle
#     risks the false-PASS shape this script exists to avoid, which is worse
#     than the false violation it would fix. Left alone deliberately.
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
# A fetch failure (network error, non-2xx, unparseable JSON, or a fetched
# file that fails schema validation) is reported and fails the run distinctly
# from a violation: an expectations file this script could not retrieve or
# could not make sense of is a contract that could not be VERIFIED, which is
# never the same as a contract that was checked and found satisfied. jq's own
# failures are trapped and mapped onto the documented exit codes below rather
# than being allowed to abort the script with jq's raw exit status.
#
# Usage:
#   ./validate-expectations.sh
#       Reads auth/models/consumers.json, fetches every consumer's
#       expectations_url, and validates auth/models/<store>.json for each.
#
#   ./validate-expectations.sh --expectations-file PATH --store NAME
#       Validates a single local expectations file against
#       auth/models/NAME.json, with no network access.
#
#   ./validate-expectations.sh --expectations-file PATH --model-file PATH
#       Same, but against a model file at an arbitrary path — which is how
#       the fixtures under auth/models/testdata/ are validated, since their
#       standalone boundary models are not stores under auth/models/ and so
#       have no --store name. auth/validate-expectations.selftest.sh runs
#       every one of them and is what CI executes.
#
# Requires: bash >= 4, curl, jq.
#
# Exit codes: 0 all consumers' expectations satisfied (including an empty
#   registry); 1 one or more expectations violated; 2 one or more consumers'
#   expectations files could not be fetched, parsed, schema-validated, or
#   evaluated (never combined with 1's meaning — see above); 3 a referenced
#   model file is missing; 64 usage error, including a locally supplied
#   expectations file or registry that is malformed or fails schema
#   validation.

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
Usage: $0 [--expectations-file PATH (--store NAME | --model-file PATH)]

With no arguments, validates every consumer registered in
auth/models/consumers.json against auth/models/<store>.json, fetching each
consumer's expectations_url over HTTPS.

  --expectations-file PATH   Validate this local expectations file instead
                              of fetching one. Must be paired with --store
                              or --model-file.
  --store NAME                Model to validate against is auth/models/NAME.json.
  --model-file PATH           Model to validate against is PATH. Use for the
                              standalone fixture models under
                              auth/models/testdata/, which are not stores.
                              Mutually exclusive with --store.

Exit codes: 0 pass, 1 violation(s) found, 2 could not fetch/parse/evaluate an
expectations file, 3 model file missing, 64 usage or malformed local input.
EOF
    exit "$EXIT_USAGE"
}

EXP_FILE_ARG=""
STORE_ARG=""
MODEL_FILE_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --expectations-file) [[ $# -ge 2 ]] || usage; EXP_FILE_ARG="$2"; shift 2 ;;
        --store)             [[ $# -ge 2 ]] || usage; STORE_ARG="$2"; shift 2 ;;
        --model-file)        [[ $# -ge 2 ]] || usage; MODEL_FILE_ARG="$2"; shift 2 ;;
        -h|--help)           usage ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
    esac
done

if [[ -n "$STORE_ARG" && -n "$MODEL_FILE_ARG" ]]; then
    echo "--store and --model-file are mutually exclusive." >&2
    usage
fi

if [[ -n "$EXP_FILE_ARG" || -n "$STORE_ARG" || -n "$MODEL_FILE_ARG" ]]; then
    [[ -n "$EXP_FILE_ARG" ]] || usage
    [[ -n "$STORE_ARG" || -n "$MODEL_FILE_ARG" ]] || usage
fi

# --- expectations schema program --------------------------------------------
#
# Emits a JSON array of schema-error strings — empty when the file is a
# well-formed expectations file. Unknown top-level keys and a total absence
# of rule keys are both errors (see the header). Rule values are type-checked
# too: a `required_types` given as a bare string, say, would otherwise blow
# up mid-walk inside the validation program as a raw jq error rather than as
# a legible complaint about the consumer's file.
read -r -d '' SCHEMA_JQ <<'JQ_PROGRAM' || true
def knownKeys: ["_comment","consumer","store",
                "required_types","required_relations",
                "forbidden_types","forbidden_relations","relation_includes"];
def ruleKeys:  ["required_types","required_relations",
                "forbidden_types","forbidden_relations","relation_includes"];
def listRules: ["required_types","forbidden_types"];
def mapRules:  ["required_relations","forbidden_relations"];

def isStringArray: (type == "array") and (all(.[]; type == "string"));

if type != "object" then
  ["expectations file must be a JSON object, but its top level is " + (type)]
else
  [ keys_unsorted[] as $k
    | select((knownKeys | index($k)) == null)
    | "unknown top-level key \"" + $k + "\" — known keys are: " + (knownKeys | join(", "))
  ]
  +
  ( if ([keys_unsorted[] as $k | select((ruleKeys | index($k)) != null)] | length) == 0 then
      ["declares no rule keys at all (needs at least one of: " + (ruleKeys | join(", "))
       + ") — a contract that asserts nothing must not be reported as satisfied"]
    else [] end )
  +
  [ listRules[] as $k
    | select(has($k))
    | select((.[$k] | isStringArray) | not)
    | "\"" + $k + "\" must be an array of strings"
  ]
  +
  [ mapRules[] as $k
    | select(has($k))
    | if (.[$k] | type) != "object" then
        "\"" + $k + "\" must be an object mapping a type name (or \"*\") to an array of relation names"
      else
        ( .[$k] | to_entries[] | select((.value | isStringArray) | not)
          | "\"" + $k + "." + .key + "\" must be an array of strings" )
      end
  ]
  +
  ( if (has("relation_includes") | not) then []
    elif (.relation_includes | type) != "object" then
      ["\"relation_includes\" must be an object mapping a type name (or \"*\") to relation rules"]
    else
      [ .relation_includes | to_entries[] as $e
        | if ($e.value | type) != "object" then
            "\"relation_includes." + $e.key + "\" must be an object mapping a relation name to an array of target relation names"
          else
            ( $e.value | to_entries[] | select((.value | isStringArray) | not)
              | "\"relation_includes." + $e.key + "." + .key + "\" must be an array of strings" )
          end
      ]
    end )
end
JQ_PROGRAM

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

# "*" resolves DIFFERENTLY for a requirement than for a prohibition, and the
# two must not be folded back together (see the file header). A requirement
# — required_relations, relation_includes — is a claim about the consumer's
# own declared surface, so "*" is required_types when the consumer declared
# one and the whole model otherwise. A prohibition — forbidden_relations —
# is a claim about the whole model ("nothing anywhere defines deleter"), so
# "*" is every type, unconditionally: narrowing a prohibition to the
# declared surface lets a brand-new type carry the forbidden relation and
# still pass, which is the false-pass direction.
#
# Neither is "types that happen to have a relations block", which is what
# both used to be: that made a type whose relations were deleted wholesale
# drop silently out of scope, so the destructive edit passed while a smaller
# one failed. A relation-less type in scope now reaches relsOf's {} default
# and fails every relation required of it, which is the point.
def requirementScope:
  # An empty required_types ([]) is treated the same as an absent key, not as
  # a deliberately empty scope: a consumer that writes "required_types": []
  # is declaring no surface, not zero surface, and falling back to the whole
  # model is the safe direction — the alternative silences a wildcard
  # required_relations/relation_includes rule instead of evaluating it.
  ($exp.required_types // []) as $rt | if ($rt | length) > 0 then $rt else modelTypes end;

def prohibitionScope:
  modelTypes;

def typesForRequirement($k):
  if $k == "*" then requirementScope else [$k] end;

def typesForProhibition($k):
  if $k == "*" then prohibitionScope else [$k] end;

# includesRelation asserts a SUFFICIENT path: holding $target, on its own,
# is enough to hold the relation described by $rewrite. Every branch below
# follows from that one rule:
#   - computedUserset: holding $target is literally what this node grants —
#     sufficient by definition.
#   - union: holding $target satisfies the union if it satisfies ANY one
#     child, since a union needs only one satisfied child — any(...).
#   - intersection: a relation R = A ∩ B needs BOTH A and B satisfied.
#     Holding $target only satisfies branches where $target itself appears;
#     if it's missing from even one branch, holding $target alone is not
#     sufficient for R. So intersection requires $target in EVERY child —
#     all(...) — not any(...); "any" here would report a merely necessary
#     branch as sufficient, the same false-pass shape as the two cases below.
#   - difference (base, but not subtract): $target reachable through
#     `subtract` is being explicitly EXCLUDED, never a sufficient path, so
#     inclusion requires $target reachable through `base` AND NOT reachable
#     through `subtract`.
#   - tupleToUserset: its computedUserset names $target on a *different*
#     object reached via the tupleset, not this object — holding $target
#     there says nothing about holding it here, so this is never descended
#     into at all; not "insufficient", simply not about the same object.
def includesRelation($rewrite; $target):
  if ($rewrite | type) != "object" then
    false
  elif $rewrite | has("computedUserset") then
    $rewrite.computedUserset.relation == $target
  elif $rewrite | has("union") then
    ($rewrite.union.child // []) | any(includesRelation(.; $target))
  elif $rewrite | has("intersection") then
    ($rewrite.intersection.child // []) | all(includesRelation(.; $target))
  elif $rewrite | has("difference") then
    includesRelation($rewrite.difference.base; $target)
      and (includesRelation($rewrite.difference.subtract; $target) | not)
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
    | typesForRequirement($k)[] as $t
    | ($exp.required_relations[$k][]) as $rel
    | select((relsOf($t) | has($rel)) | not)
    | "required_relations: type \"" + $t + "\" missing required relation \"" + $rel + "\""
  ]
) as $v3
|
(
  [ ($exp.forbidden_relations // {}) | keys[] as $k
    | typesForProhibition($k)[] as $t
    | ($exp.forbidden_relations[$k][]) as $rel
    | select(relsOf($t) | has($rel))
    | "forbidden_relations: type \"" + $t + "\" has forbidden relation \"" + $rel + "\""
  ]
) as $v4
|
# Per-type skipping is correct — a type that does not define the named
# relation is not in scope for a claim about that relation — but skipping
# every type in scope is not a pass, it is a claim about a relation the
# model does not have. Without this, relation_includes on a misspelled or
# since-removed relation reported "satisfied" while checking nothing.
(
  [ ($exp.relation_includes // {}) | keys[] as $k
    | ($exp.relation_includes[$k] | keys[]) as $namedRel
    | ([typesForRequirement($k)[] | select(relsOf(.) | has($namedRel))]) as $defining
    | if ($defining | length) == 0 then
        ( if $k == "*" then
            "relation_includes: no type in scope defines relation \"" + $namedRel
              + "\" — nothing in the model can satisfy a claim about it"
          else
            "relation_includes: type \"" + $k + "\" does not define relation \"" + $namedRel + "\""
          end )
      else
        ( $defining[] as $t
          | ($exp.relation_includes[$k][$namedRel][]) as $target
          | select(includesRelation(relsOf($t)[$namedRel]; $target) | not)
          | "relation_includes: type \"" + $t + "\" relation \"" + $namedRel
              + "\" does not include \"" + $target + "\" via computedUserset"
        )
      end
  ]
) as $v5
|
$v1 + $v2 + $v3 + $v4 + $v5
JQ_PROGRAM

# check_schema EXP_FILE LABEL
#
# Returns 0 when EXP_FILE parses as JSON and satisfies the expectations
# schema, 1 otherwise (reporting every problem). Every caller must run this
# before touching the file's contents: it is what stops a jq read of an
# array-rooted, HTML or truncated file from aborting the script with jq's own
# exit status, outside the documented scheme.
check_schema() {
    local exp_file="$1" label="$2"
    local schema_errs

    if ! jq -e 'type' "$exp_file" >/dev/null 2>&1; then
        err "[$label] expectations file is not valid JSON (or is empty)"
        return 1
    fi

    if ! schema_errs=$(jq -r "$SCHEMA_JQ"' | .[]' "$exp_file" 2>/dev/null); then
        err "[$label] internal error while schema-validating expectations"
        return 1
    fi

    if [[ -n "$schema_errs" ]]; then
        while IFS= read -r line; do
            err "[$label] expectations schema error: $line"
        done <<<"$schema_errs"
        return 1
    fi

    return 0
}

# validate_one EXP_FILE MODEL_FILE CONSUMER STORE
#
# Prints every violation (prefixed with consumer and store) to stderr via
# err, and echoes the violation count to stdout — or "-1" when jq itself
# failed, which the caller must treat as "unverified", never as clean.
validate_one() {
    local exp_file="$1" model_file="$2" consumer="$3" store="$4"
    local violations count jq_err

    jq_err=$(mktemp)

    # jq's stderr goes to its own file, never into $violations: the count
    # below parses $violations as JSON, and folding a diagnostic into it
    # would make an internal error look like malformed output instead.
    if ! violations=$(jq -n --slurpfile exp "$exp_file" --slurpfile model "$model_file" \
            '($exp[0]) as $exp | ($model[0]) as $model | '"$VALIDATE_JQ" 2>"$jq_err"); then
        err "[$consumer/$store] internal error evaluating expectations: $(tr '\n' ' ' <"$jq_err")"
        rm -f "$jq_err"
        echo "-1"
        return
    fi
    rm -f "$jq_err"

    if ! count=$(jq 'length' <<<"$violations" 2>/dev/null); then
        err "[$consumer/$store] internal error reading validation output"
        echo "-1"
        return
    fi

    if [[ "$count" -gt 0 ]]; then
        while IFS= read -r line; do
            err "[$consumer/$store] $line"
        done < <(jq -r '.[]' <<<"$violations")
    fi
    echo "$count"
}

# --- single-file mode --------------------------------------------------------

if [[ -n "$EXP_FILE_ARG" ]]; then
    [[ -f "$EXP_FILE_ARG" ]] || { echo "Expectations file not found: $EXP_FILE_ARG" >&2; exit "$EXIT_USAGE"; }

    if [[ -n "$MODEL_FILE_ARG" ]]; then
        MODEL_FILE="$MODEL_FILE_ARG"
        MODEL_DISPLAY="$MODEL_FILE_ARG"
        STORE_LABEL="$(basename "$MODEL_FILE_ARG" .json)"
    else
        MODEL_FILE="${MODELS_DIR}/${STORE_ARG}.json"
        MODEL_DISPLAY="auth/models/${STORE_ARG}.json"
        STORE_LABEL="$STORE_ARG"
    fi
    [[ -f "$MODEL_FILE" ]] || { err "Model file not found: $MODEL_FILE"; exit "$EXIT_MODEL_MISSING"; }

    # Schema first, and before any read of the file's contents: an empty or
    # null expectations file used to make every rule's `// {}` default fire
    # and print "✓ No violations" — a pass reported for a file that said
    # nothing at all.
    check_schema "$EXP_FILE_ARG" "$EXP_FILE_ARG" || exit "$EXIT_USAGE"

    if ! CONSUMER=$(jq -r '.consumer // "unknown"' "$EXP_FILE_ARG" 2>/dev/null); then
        err "Could not read consumer name from $EXP_FILE_ARG"
        exit "$EXIT_USAGE"
    fi
    log "Validating ${MODEL_DISPLAY} against $EXP_FILE_ARG (consumer: $CONSUMER)"

    COUNT=$(validate_one "$EXP_FILE_ARG" "$MODEL_FILE" "$CONSUMER" "$STORE_LABEL")
    if [[ "$COUNT" == "-1" ]]; then
        err "Expectations could not be evaluated — the contract is unverified, which is not the same as satisfied."
        exit "$EXIT_FETCH"
    elif [[ "$COUNT" -gt 0 ]]; then
        err "$COUNT violation(s) found."
        exit "$EXIT_VIOLATION"
    fi
    ok "No violations. $STORE_LABEL satisfies $CONSUMER's expectations."
    exit 0
fi

# --- registry mode -----------------------------------------------------------

[[ -f "$CONSUMERS_FILE" ]] || { err "Registry not found: $CONSUMERS_FILE"; exit "$EXIT_MODEL_MISSING"; }

if ! jq -e 'type == "array"' "$CONSUMERS_FILE" >/dev/null 2>&1; then
    err "Registry is not a JSON array of consumer entries: $CONSUMERS_FILE"
    exit "$EXIT_USAGE"
fi

# Every entry is checked up front, so the per-entry reads below cannot fail
# with jq's own exit status partway through the loop.
if ! REGISTRY_ERRS=$(jq -r '
        to_entries[]
        | select((.value | type) != "object"
                 or ([.value.consumer, .value.store, .value.expectations_url]
                     | any(type != "string")))
        | "entry [" + (.key | tostring) + "] must be an object with string consumer, store and expectations_url"
    ' "$CONSUMERS_FILE" 2>/dev/null); then
    err "Could not read registry: $CONSUMERS_FILE"
    exit "$EXIT_USAGE"
fi
if [[ -n "$REGISTRY_ERRS" ]]; then
    while IFS= read -r line; do err "Registry schema error: $line"; done <<<"$REGISTRY_ERRS"
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
    CONSUMER=$(jq -r '.consumer' <<<"$ENTRY")
    STORE=$(jq -r '.store' <<<"$ENTRY")
    URL=$(jq -r '.expectations_url' <<<"$ENTRY")

    MODEL_FILE="${MODELS_DIR}/${STORE}.json"
    if [[ ! -f "$MODEL_FILE" ]]; then
        err "[$CONSUMER/$STORE] model file not found: $MODEL_FILE"
        exit "$EXIT_MODEL_MISSING"
    fi

    # expectations_url is consumer-supplied data (it comes from the registry
    # file, not a literal in this script), so it gets the same "could not
    # verify" treatment as any other fetch failure rather than a fetch
    # attempt: a plain-http URL, or an https URL that redirects to http,
    # would otherwise send this script's requests in the clear.
    if [[ "$URL" != https://* ]]; then
        err "[$CONSUMER/$STORE] expectations_url is not https://, refusing to fetch: $URL"
        FETCH_FAILURES=$((FETCH_FAILURES + 1))
        continue
    fi

    log "Fetching expectations for $CONSUMER ($STORE) from $URL"

    TMP_EXP=$(mktemp)
    TMP_ERR=$(mktemp)

    # -L: a consumer reorganizing their repo and leaving a 301 behind should
    # not read as a permanently unverifiable contract. These are public raw
    # URLs with no credentials attached, so following redirects costs
    # nothing; --max-redirs bounds a redirect loop. --proto/--proto-redir
    # pin both the initial request and any redirect hop to https, backstopping
    # the scheme check above against an https URL that redirects to http.
    # --max-filesize bounds the response body: a real expectations file is a
    # few consumer-declared type/relation names, well under a kilobyte; 1 MiB
    # is generous headroom for that while still refusing an unbounded or
    # maliciously large body instead of downloading it until --max-time.
    HTTP_STATUS=$(curl -sS -L --max-redirs 5 --proto '=https' --proto-redir '=https' \
        --max-filesize 1048576 -o "$TMP_EXP" -w '%{http_code}' \
        --connect-timeout 10 --max-time 30 "$URL" 2>"$TMP_ERR") || {
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

    # A fetched file that is not a well-formed expectations file is an
    # unverifiable contract, not a satisfied one — same bucket as a 404.
    if ! check_schema "$TMP_EXP" "$CONSUMER/$STORE"; then
        err "[$CONSUMER/$STORE] expectations file at $URL is not usable — contract unverified."
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
    err "$TOTAL_VIOLATIONS expectations violation(s) found, and $FETCH_FAILURES consumer(s)' expectations could not be verified. An unverified contract is not a satisfied one."
    exit "$EXIT_VIOLATION"
elif [[ "$TOTAL_VIOLATIONS" -gt 0 ]]; then
    err "$TOTAL_VIOLATIONS expectations violation(s) found."
    exit "$EXIT_VIOLATION"
elif [[ "$FETCH_FAILURES" -gt 0 ]]; then
    err "$FETCH_FAILURES consumer(s)' expectations could not be fetched or validated — contract unverified, treated as a failure, distinct from a violation."
    exit "$EXIT_FETCH"
fi

ok "All $NUM_CONSUMERS consumer(s)' expectations satisfied."
exit 0
