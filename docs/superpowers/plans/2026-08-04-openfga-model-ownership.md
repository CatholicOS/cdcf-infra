# OpenFGA Model Ownership Centralization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make cdcf-infra the single owner of every OpenFGA authorization model on the shared instance, and make it impossible for a stale model file to silently regress a store.

**Architecture:** cdcf-infra keeps `auth/models/<Store>.json` (+ optional `.tuples.json`) and gains `auth/models/<Store>.lock.json`, recording the model ID this repo last uploaded. `upload_model_if_changed` refuses to upload when the store's latest model ID differs from the lock, unless `--force-model-upload` is passed. LiturgicalCalendarAPI stops owning its model and consumes cdcf-infra's, exactly as `martyrology-api` already does.

**Tech Stack:** Bash 4+, `curl`, `jq`, Docker (for a throwaway OpenFGA used in verification), GitHub CLI (`gh`).

## Global Constraints

- Source design: `docs/superpowers/specs/2026-08-04-openfga-model-ownership-and-upgrade-design.md`.
- The lock file has exactly three fields: `store_name`, `store_id`, `model_id`. No timestamps, no commit hashes — provenance comes from the lock file's own git history.
- Production model IDs as of 2026-08-04: LiturgicalCalendar store `01KRSCF4GVX0X4ZNXXJQEC4XXJ` → model `01KW4FW2ZCT1E693PY8D9TJEFM`; Martyrology store `01KZ1M9NJR1JHTMTV091X5DMYZ` → model `01KZ3VZC7RAAX7TEMMVAYEBPW8`.
- `setup-openfga.sh` must stay idempotent and must never delete tuples.
- No secrets in any committed file. `OPENFGA_PRESHARED_KEY` stays out-of-band.
- LitCal PRs target the `development` branch (`Liturgical-Calendar` org default), not `main`.
- Production is never modified by this plan. Every production interaction is read-only verification. Applying the synced model to production is an operator step recorded in Task 8, run by hand.
- Do not run `./setup-openfga.sh --target production --create-litcal-store` at any point before Task 3 is merged — that is the regression this plan exists to prevent.

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `auth/models/LiturgicalCalendar.json` | LitCal authorization model, authoritative copy | Replaced with the deployed version |
| `auth/models/LiturgicalCalendar.lock.json` | Records the model ID cdcf-infra last uploaded to the LitCal store | Created |
| `auth/models/Martyrology.lock.json` | Same, for Martyrology | Created |
| `auth/setup-openfga.sh` | Store/model/tuple provisioning | `upload_model_if_changed` gains the lock guard; new `--force-model-upload` flag |
| `auth/README.md` | Infra reference | Documents the ownership rule + lock file |
| `docs/SYSADMIN.md` | Operator handbook | §4.8 interim warning removed, lock-file behaviour documented |
| `auth/handoffs/liturgicalcalendar.md` | LitCal handoff | Interim warning removed; model source now this repo |
| **LitCal repo** `scripts/openfga-model.json` | — | Deleted |
| **LitCal repo** `scripts/setup-openfga.sh` | Local env wiring | Reduced to reading IDs back + `--update-env`; no model upload |
| **LitCal repo** `docker-compose.yml` | Local stack | Gains `authz-seed` service |

---

### Task 1: Sync the LitCal model into cdcf-infra

**Files:**
- Modify: `auth/models/LiturgicalCalendar.json` (full replacement)
- Read-only reference: `/home/johnrdorazio/development/LiturgicalCalendar/LiturgicalCalendarAPI/scripts/openfga-model.json`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: an `auth/models/LiturgicalCalendar.json` whose normalized `type_definitions` equal the deployed model `01KW4FW2ZCT1E693PY8D9TJEFM`. Tasks 3 and 8 depend on this equality.

- [ ] **Step 1: Write the failing check**

Create `/tmp/model-parity-check.sh` (scratch, not committed). It compares the repo file against the LitCal source using the same normalization `upload_model_if_changed` uses:

```bash
#!/usr/bin/env bash
set -euo pipefail
INFRA=auth/models/LiturgicalCalendar.json
SRC=/home/johnrdorazio/development/LiturgicalCalendar/LiturgicalCalendarAPI/scripts/openfga-model.json
N='walk(if type == "object" then with_entries(select(.value != null and .value != "" and (.value != {} or .key == "this"))) else . end)'
a=$(jq -cS ".type_definitions | $N" "$INFRA")
b=$(jq -cS ".type_definitions | $N" "$SRC")
[[ "$a" == "$b" ]] && echo "PARITY: yes" || echo "PARITY: no"
```

- [ ] **Step 2: Run it to confirm it currently fails**

```bash
bash /tmp/model-parity-check.sh
```

Expected: `PARITY: no` — cdcf-infra's copy is two revisions behind.

- [ ] **Step 3: Copy the model in**

```bash
cp /home/johnrdorazio/development/LiturgicalCalendar/LiturgicalCalendarAPI/scripts/openfga-model.json \
   auth/models/LiturgicalCalendar.json
```

- [ ] **Step 4: Re-run the check**

```bash
bash /tmp/model-parity-check.sh
```

Expected: `PARITY: yes`.

- [ ] **Step 5: Confirm the deployed types are present**

```bash
jq -r '.type_definitions[].type' auth/models/LiturgicalCalendar.json | sort | tr '\n' ' '
```

Expected exactly: `diocesan_calendar diocesan_calendar_test general_roman_calendar general_roman_calendar_test national_calendar national_calendar_test user wider_region`

There must be **no** `test_definition`, and no `deleter` relation:

```bash
jq -r '[.type_definitions[].relations // {} | keys[]] | unique | join(" ")' auth/models/LiturgicalCalendar.json
```

Expected: `admin editor member_nation viewer`

- [ ] **Step 6: Commit**

```bash
git add auth/models/LiturgicalCalendar.json
git commit -m "Sync LiturgicalCalendar model from the LitCal repo

The deployed model (01KW4FW2ZCT1E693PY8D9TJEFM) has been evolved twice in
LiturgicalCalendarAPI since this copy was written on 2026-05-16. Adopt it
verbatim so cdcf-infra describes what is actually running: adds
general_roman_calendar and the three *_test types, adds member_nation on
wider_region, drops test_definition and the deleter relation."
```

---

### Task 2: Add the lock-file guard to `setup-openfga.sh`

**Files:**
- Modify: `auth/setup-openfga.sh` — `upload_model_if_changed`, `do_create_store`, the argument parser, the usage block, and the header comment.

**Interfaces:**
- Consumes: nothing from Task 1 (independent, but commit order in this plan is 1 → 2).
- Produces:
  - `lock_file_for NAME` → echoes `${MODELS_DIR}/NAME.lock.json`
  - `read_lock_model_id NAME` → echoes the recorded model ID, or empty string when the lock is absent/unreadable
  - `write_lock NAME STORE_ID MODEL_ID` → writes the three-field lock file
  - `upload_model_if_changed STORE_ID MODEL_FILE NAME` → **note the new third parameter**; still echoes the model ID on stdout
  - Global `FORCE_MODEL_UPLOAD` (`true`/`false`), set by `--force-model-upload`

- [ ] **Step 1: Start a throwaway OpenFGA for verification**

In-memory datastore, so nothing persists and no database is needed:

```bash
docker run --rm -d --name fga-test -p 127.0.0.1:18081:8080 \
  -e OPENFGA_AUTHN_METHOD=preshared \
  -e OPENFGA_AUTHN_PRESHARED_KEYS=test-key \
  openfga/openfga:v1.15.1 run
sleep 5
curl -sS -H "Authorization: Bearer test-key" http://127.0.0.1:18081/stores | jq .
```

Expected: `{"stores":[],...}` or an empty-ish store list — proves it is up and authenticating.

- [ ] **Step 2: Create the local env file the script needs**

```bash
cat > auth/.env.local <<'EOF'
OPENFGA_API_URL=http://127.0.0.1:18081
OPENFGA_INTERNAL_URL=http://127.0.0.1:18081
OPENFGA_PRESHARED_KEY=test-key
EOF
```

`auth/.env.local` is git-ignored; confirm with `git check-ignore -v auth/.env.local` before proceeding. If it is NOT ignored, stop and add it to `.gitignore` in this task.

- [ ] **Step 3: Reproduce the regression the guard must prevent**

Seed the throwaway store with the current model, then simulate the out-of-band upload by uploading a modified model directly, then run the script with the repo file:

```bash
cd auth
./setup-openfga.sh --target local --create-store LiturgicalCalendar     # creates store + model A
STORE=$(curl -sS -H "Authorization: Bearer test-key" http://127.0.0.1:18081/stores | jq -r '.stores[] | select(.name=="LiturgicalCalendar") | .id')
# out-of-band upload: same model minus one type, standing in for "someone else changed it"
jq '{schema_version, type_definitions: [.type_definitions[] | select(.type != "general_roman_calendar_test")]}' \
  models/LiturgicalCalendar.json > /tmp/oob-model.json
curl -sS -X POST "http://127.0.0.1:18081/stores/$STORE/authorization-models" \
  -H "Authorization: Bearer test-key" -H 'Content-Type: application/json' -d @/tmp/oob-model.json | jq -r .authorization_model_id
./setup-openfga.sh --target local --create-store LiturgicalCalendar     # ← the dangerous run
cd ..
```

Expected **before the fix**: the last run prints `⚠ Model differs from file — uploading new version` and `✓ Uploaded model: <new id>` — it overwrote the out-of-band model. That is the bug.

- [ ] **Step 4: Add the lock helpers**

In `auth/setup-openfga.sh`, immediately **above** `upload_model_if_changed()`, add:

```bash
# --- model lock ------------------------------------------------------------
#
# auth/models/<name>.lock.json records the model ID THIS repo last uploaded to
# the store. Under centralized ownership (see docs/superpowers/specs/
# 2026-08-04-openfga-model-ownership-and-upgrade-design.md) cdcf-infra is the
# only writer of models, so a store whose latest model ID is not the recorded
# one means someone uploaded out-of-band. Uploading over that would silently
# revert their work — which is exactly what nearly happened to the
# LiturgicalCalendar store on 2026-08-04 — so we refuse instead.
#
# Three fields only. No timestamp or commit hash: the lock file is committed,
# so `git log auth/models/<name>.lock.json` is the provenance record.

lock_file_for() {
    echo "${MODELS_DIR}/${1}.lock.json"
}

read_lock_model_id() {
    local lock; lock=$(lock_file_for "$1")
    [[ -f "$lock" ]] || { echo ""; return 0; }
    jq -r '.model_id // empty' "$lock" 2>/dev/null || echo ""
}

write_lock() {
    local name="$1" store_id="$2" model_id="$3"
    local lock; lock=$(lock_file_for "$name")
    jq -n --arg n "$name" --arg s "$store_id" --arg m "$model_id" \
        '{store_name: $n, store_id: $s, model_id: $m}' > "$lock"
    ok "Lock updated: $(basename "$lock") → $model_id"
}
```

- [ ] **Step 5: Add the guard inside `upload_model_if_changed`**

Change the function signature line from:

```bash
upload_model_if_changed() {
    local store_id="$1" model_file="$2"
```

to:

```bash
upload_model_if_changed() {
    local store_id="$1" model_file="$2" name="$3"
```

Then, inside the `if [[ -n "$existing_model_id" ]]; then` branch, **before** the normalization comparison, insert:

```bash
        local locked_model_id; locked_model_id=$(read_lock_model_id "$name")
        if [[ -n "$locked_model_id" && "$locked_model_id" != "$existing_model_id" ]]; then
            if [[ "$FORCE_MODEL_UPLOAD" == "true" ]]; then
                warn "Store's latest model ($existing_model_id) is not the locked one ($locked_model_id) — proceeding anyway (--force-model-upload)"
            else
                err "Refusing to touch the model for store '$name'."
                err "  store's latest: $existing_model_id"
                err "  lock file says: $locked_model_id"
                err "Someone uploaded a model outside this repo. Uploading now would revert it."
                err "Resolve by syncing $(basename "$model_file") from the source of truth and updating"
                err "$(basename "$(lock_file_for "$name")"), or re-run with --force-model-upload if you"
                err "really mean to replace the deployed model."
                exit 7
            fi
        fi
```

- [ ] **Step 6: Record the lock on both exit paths**

In the "unchanged" branch, replace:

```bash
        if [[ "$server_model" == "$file_model" ]]; then
            ok "Model unchanged ($existing_model_id) — no upload needed"
            echo "$existing_model_id"
            return 0
        fi
```

with:

```bash
        if [[ "$server_model" == "$file_model" ]]; then
            ok "Model unchanged ($existing_model_id) — no upload needed"
            [[ "$(read_lock_model_id "$name")" == "$existing_model_id" ]] \
                || write_lock "$name" "$store_id" "$existing_model_id"
            echo "$existing_model_id"
            return 0
        fi
```

And after the successful upload, replace:

```bash
    ok "Uploaded model: $model_id"
    echo "$model_id"
```

with:

```bash
    ok "Uploaded model: $model_id"
    write_lock "$name" "$store_id" "$model_id"
    echo "$model_id"
```

- [ ] **Step 7: Handle the adoption case (lock absent, file differs)**

Still inside the `if [[ -n "$existing_model_id" ]]` branch, replace the line:

```bash
        warn "Model differs from file — uploading new version"
```

with:

```bash
        if [[ -z "$locked_model_id" && "$FORCE_MODEL_UPLOAD" != "true" ]]; then
            err "No lock file for store '$name' and the model file differs from the store's latest ($existing_model_id)."
            err "This repo has no record of uploading that model, so it cannot tell an intended"
            err "update from a stale file. Sync the file and re-run (an identical file adopts the"
            err "lock silently), or pass --force-model-upload to upload this file as the new model."
            exit 7
        fi
        warn "Model differs from file — uploading new version"
```

- [ ] **Step 8: Update the single call site**

In `do_create_store`, change:

```bash
    model_id=$(upload_model_if_changed "$store_id" "$model_file")
```

to:

```bash
    model_id=$(upload_model_if_changed "$store_id" "$model_file" "$name")
```

- [ ] **Step 9: Add the flag**

Next to `TARGET=""` and `ACTIONS=()` near the top, add:

```bash
FORCE_MODEL_UPLOAD="false"
```

In the argument `while` loop, add before `-h|--help)`:

```bash
        --force-model-upload)   FORCE_MODEL_UPLOAD="true"; shift ;;
```

In `usage()`, under `Actions:`, add:

```text
  --force-model-upload      Upload the model file even when the store's latest model
                            is not the one recorded in auth/models/NAME.lock.json
                            (i.e. someone uploaded out-of-band). Off by default.
```

And in the header comment block, under the `--seed-tuples` entry, add:

```bash
#   --force-model-upload   Override the lock-file guard (see auth/models/*.lock.json).
#                          Without it, a store whose latest model was not uploaded by
#                          this repo is left alone and the run exits non-zero.
```

- [ ] **Step 10: Verify the guard blocks the regression**

Step 3's own "dangerous run" already re-uploaded a copy matching the repo
file, so by now the store's latest model is back in sync with
`models/LiturgicalCalendar.json` and no lock file was ever written — the
"unchanged" branch would fire, not the no-lock refusal branch this step is
supposed to exercise. Recreate the out-of-band mismatch first, by re-uploading
the same modified model Step 3 used:

```bash
STORE=$(curl -sS -H "Authorization: Bearer test-key" http://127.0.0.1:18081/stores | jq -r '.stores[] | select(.name=="LiturgicalCalendar") | .id')
OOB_MODEL=$(curl -sS -f -X POST "http://127.0.0.1:18081/stores/$STORE/authorization-models" \
  -H "Authorization: Bearer test-key" -H 'Content-Type: application/json' -d @/tmp/oob-model.json | jq -r '.authorization_model_id // empty')
[[ -n "$OOB_MODEL" && "$OOB_MODEL" != "null" ]] || { echo "out-of-band upload failed — aborting before it produces a false pass below" >&2; exit 1; }
echo "out-of-band model: $OOB_MODEL"
```

No lock file exists yet, and the model just uploaded no longer matches
`models/LiturgicalCalendar.json`, so the **no-lock refusal branch** must fire
— not adoption. (Adoption is the silent lock-write in the "unchanged" branch,
Step 6 above, and only applies when the file and the store's model already
match.)

```bash
cd auth && ./setup-openfga.sh --target local --create-store LiturgicalCalendar; echo "exit=$?"; cd ..
```

Expected: `✗ No lock file for store 'LiturgicalCalendar' …`, `exit=7`, and **no** new model uploaded. Confirm the store's latest model is unchanged:

```bash
curl -sS -H "Authorization: Bearer test-key" "http://127.0.0.1:18081/stores/$STORE/authorization-models?page_size=1" | jq -r '.authorization_models[0].id'
```

Expected: still `$OOB_MODEL`, the out-of-band model just re-uploaded above.

- [ ] **Step 11: Verify `--force-model-upload` overrides**

```bash
cd auth && ./setup-openfga.sh --target local --create-store LiturgicalCalendar --force-model-upload; echo "exit=$?"; cd ..
```

Expected: `⚠ Model differs from file — uploading new version`, `✓ Uploaded model: <id>`, `✓ Lock updated: LiturgicalCalendar.lock.json → <id>`, `exit=0`. A lock file now exists locally — **delete it**, because Task 3 writes the real one:

```bash
rm -f auth/models/LiturgicalCalendar.lock.json
```

- [ ] **Step 12: Verify the happy path still works**

```bash
cd auth && ./setup-openfga.sh --target local --create-store LiturgicalCalendar; echo "exit=$?"; cd ..
```

Expected: `✓ Model unchanged (<id>) — no upload needed`, a lock write (adoption, since the file matches), `exit=0`. Run it once more; expected: `Model unchanged`, no lock write (already correct), `exit=0`. Then clean up again:

```bash
rm -f auth/models/LiturgicalCalendar.lock.json
docker rm -f fga-test
rm -f auth/.env.local /tmp/oob-model.json
```

- [ ] **Step 13: Shellcheck**

```bash
shellcheck auth/setup-openfga.sh
```

Expected: no new warnings versus `git stash`-ed baseline. If `shellcheck` is unavailable, run `bash -n auth/setup-openfga.sh` and note that shellcheck was skipped.

- [ ] **Step 14: Commit**

```bash
git add auth/setup-openfga.sh
git commit -m "Refuse to upload a model over an out-of-band change

setup-openfga.sh uploaded whenever the model file differed from the store's
latest, so a stale file silently replaced a newer deployed model. Record the
model ID this repo uploads in auth/models/<name>.lock.json and refuse when the
store's latest is something else, with --force-model-upload as the deliberate
override. Verified against a throwaway in-memory OpenFGA: the run that
previously overwrote an out-of-band model now exits 7 and leaves it alone."
```

---

### Task 3: Generate the production lock files

**Files:**
- Create: `auth/models/LiturgicalCalendar.lock.json`
- Create: `auth/models/Martyrology.lock.json`

**Interfaces:**
- Consumes: `write_lock`'s three-field shape from Task 2.
- Produces: lock files matching production, so the first real run of either store action adopts silently instead of refusing.

- [ ] **Step 1: Read the deployed model IDs back from production (read-only)**

```bash
ssh ubuntu@catholicdigitalcommons.org 'bash -s' <<'EOS'
set -euo pipefail
KEY=$(grep -m1 '^OPENFGA_PRESHARED_KEY=' /opt/cdcf-auth/auth/.env.production | cut -d= -f2- | tr -d '"')
for s in 01KRSCF4GVX0X4ZNXXJQEC4XXJ 01KZ1M9NJR1JHTMTV091X5DMYZ; do
  printf '%s -> ' "$s"
  curl -sS "http://127.0.0.1:8081/stores/$s/authorization-models?page_size=1" \
    -H "Authorization: Bearer $KEY" | jq -r '.authorization_models[0].id'
done
EOS
```

Expected: `01KRSCF4GVX0X4ZNXXJQEC4XXJ -> 01KW4FW2ZCT1E693PY8D9TJEFM` and `01KZ1M9NJR1JHTMTV091X5DMYZ -> 01KZ3VZC7RAAX7TEMMVAYEBPW8`. **If either differs, stop** — something changed since 2026-08-04; use the values you just read and note the discrepancy in the commit message.

- [ ] **Step 2: Confirm deployed model CONTENT matches the committed file, not just the ID**

A matching ID is not enough — locking a model whose committed file doesn't
actually match what's deployed would make Step 3's lock a false record. Fetch
each deployed model's full `type_definitions` and compare against the repo
file using the exact same normalization `upload_model_if_changed` uses (see
`auth/setup-openfga.sh`'s `normalize` variable), so this check and the guard
it feeds agree on what "matches" means:

```bash
KEY=$(ssh ubuntu@catholicdigitalcommons.org \
  "grep -m1 '^OPENFGA_PRESHARED_KEY=' /opt/cdcf-auth/auth/.env.production | cut -d= -f2- | tr -d '\"'")
NORMALIZE='walk(if type == "object" then with_entries(select(.value != null and .value != "" and (.value != {} or .key == "this"))) else . end)'

for pair in "LiturgicalCalendar:01KRSCF4GVX0X4ZNXXJQEC4XXJ:01KW4FW2ZCT1E693PY8D9TJEFM" "Martyrology:01KZ1M9NJR1JHTMTV091X5DMYZ:01KZ3VZC7RAAX7TEMMVAYEBPW8"; do
  name=${pair%%:*}; rest=${pair#*:}; store=${rest%%:*}; expected_id=${rest##*:}
  ssh ubuntu@catholicdigitalcommons.org \
    "curl -sS 'http://127.0.0.1:8081/stores/$store/authorization-models' -H 'Authorization: Bearer $KEY'" \
    > "/tmp/deployed-$name.json"
  # Extract BOTH the id and the content from this one response — comparing
  # content alone and discarding the id it came with is how a coincidentally
  # identical model at a different id would slip past this check.
  deployed_id=$(jq -r '.authorization_models[0].id // empty' "/tmp/deployed-$name.json")
  deployed=$(jq -cS ".authorization_models[0].type_definitions | $NORMALIZE" "/tmp/deployed-$name.json")
  file=$(jq -cS ".type_definitions | $NORMALIZE" "auth/models/$name.json")
  if [[ "$deployed_id" == "$expected_id" && "$deployed" == "$file" ]]; then
    echo "$name: id ($deployed_id) and content match — safe to lock"
  else
    echo "$name: MISMATCH (deployed id=$deployed_id expected id=$expected_id) — do NOT write a lock for this store; sync auth/models/$name.json from the deployed model (or investigate) before Step 3" >&2
  fi
done
```

Expected: `content matches — safe to lock` for both stores. **If either reports a mismatch, stop** — do not write a lock file for that store in Step 3; resolve the file/deployed divergence first and note it in the commit message instead.

- [ ] **Step 3: Write the lock files**

Only for stores Step 2 confirmed match:

```bash
jq -n '{store_name:"LiturgicalCalendar", store_id:"01KRSCF4GVX0X4ZNXXJQEC4XXJ", model_id:"01KW4FW2ZCT1E693PY8D9TJEFM"}' \
  > auth/models/LiturgicalCalendar.lock.json
jq -n '{store_name:"Martyrology", store_id:"01KZ1M9NJR1JHTMTV091X5DMYZ", model_id:"01KZ3VZC7RAAX7TEMMVAYEBPW8"}' \
  > auth/models/Martyrology.lock.json
```

- [ ] **Step 4: Verify shape**

```bash
for f in auth/models/*.lock.json; do echo "$f"; jq -S . "$f"; done
```

Expected: each file has exactly the keys `store_name`, `store_id`, `model_id`, and nothing else. Confirm mechanically:

```bash
jq -r 'keys | join(",")' auth/models/*.lock.json
```

Expected for each: `model_id,store_id,store_name`.

- [ ] **Step 5: Commit**

```bash
git add auth/models/LiturgicalCalendar.lock.json auth/models/Martyrology.lock.json
git commit -m "Record deployed model IDs in per-store lock files

Read back from production on the day of the change. With these in place the
first --create-*-store run adopts silently instead of refusing, and the lock
becomes the committed record of each store's current model ID — the value the
handoff docs kept getting wrong."
```

---

### Task 4: Documentation — ownership rule, lock file, warning removal

**Files:**
- Modify: `auth/README.md` (new subsection under the architecture pin)
- Modify: `docs/SYSADMIN.md` §4.8 (remove interim warning, document the lock), §5.4 (LitCal row), component inventory row for the LitCal model
- Modify: `auth/handoffs/liturgicalcalendar.md` (remove the "⚠ The copy in this repo is stale" section; restate model source)

**Interfaces:**
- Consumes: behaviour defined in Task 2, lock files from Task 3.
- Produces: no code interfaces.

- [ ] **Step 1: Add the ownership rule to `auth/README.md`**

Under the "Architecture pin" bullet list, add:

```markdown
- **cdcf-infra owns every OpenFGA authorization model** on the shared instance —
  `auth/models/<Store>.json`, its optional `<Store>.tuples.json`, and the
  `--create-{project}-store` shorthand. Consumer repos keep no model file; their
  local stacks obtain the model by cloning this repo and running
  `setup-openfga.sh --target local` (see `martyrology-api`'s `authz-seed`
  service for the reference implementation). `auth/models/<Store>.lock.json`
  records the model ID this repo last uploaded; the provisioner refuses to
  upload when a store's latest model is something else, so an out-of-band
  change is reported rather than silently reverted.
```

- [ ] **Step 2: Replace the §4.8 warning in `docs/SYSADMIN.md`**

Delete the paragraph beginning `⚠ **`--create-litcal-store` is not safe to re-run as of 2026-08-04.**` and the `# ⚠ see warning below` comment on the command, then add after the tuples paragraph:

```markdown
Each store also has `auth/models/<Store>.lock.json`, recording the model ID this repo last uploaded. If a store's latest model is not the recorded one, someone uploaded outside this repo and the run **refuses** (exit 7) rather than replacing their model — pass `--force-model-upload` only when replacing the deployed model is what you actually intend. A store whose file already matches its latest model adopts the lock silently.
```

- [ ] **Step 3: Fix the §5.4 LitCal row and the component inventory**

In §5.4, change the LitCal store cell back to `` `LiturgicalCalendar` (`01KRSCF4GVX0X4ZNXXJQEC4XXJ`)`` with no ownership caveat. In the component inventory, restore the LitCal model row to:

```markdown
| Authz model (LitCal) | `auth/models/LiturgicalCalendar.json` + `.lock.json` | owned here; synced from `LiturgicalCalendarAPI/scripts/openfga-model.json` on 2026-08-04 when ownership was centralized |
```

- [ ] **Step 4: Update the LitCal handoff**

In `auth/handoffs/liturgicalcalendar.md`, delete the whole `### ⚠ The copy in this repo is stale — do not re-run --create-litcal-store` section, and change the **Model source** bullet to:

```markdown
- **Model source**: `cdcf-infra/auth/models/LiturgicalCalendar.json` — this repo owns it as of 2026-08-04; the copy in `LiturgicalCalendarAPI` was removed. Schema 1.1. Deployed types: `user`, `wider_region`, `national_calendar`, `diocesan_calendar`, `general_roman_calendar`, `national_calendar_test`, `diocesan_calendar_test`, `general_roman_calendar_test`; relations `admin`/`editor`/`viewer` throughout, plus `member_nation` on `wider_region`. The current model ID is recorded in `auth/models/LiturgicalCalendar.lock.json`.
```

- [ ] **Step 5: Check for leftover references**

```bash
grep -rn "not safe to re-run\|copy in this repo is stale\|owned by the LitCal repo\|model owned by the LitCal repo" docs/ auth/ || echo "clean"
```

Expected: `clean`.

- [ ] **Step 6: Commit**

```bash
git add auth/README.md docs/SYSADMIN.md auth/handoffs/liturgicalcalendar.md
git commit -m "Document centralized model ownership; drop the interim warning

The stale-copy hazard is resolved by the sync and the lock guard, so the
do-not-run warning added on 2026-08-04 comes back out."
```

---

### Task 5: Open the cdcf-infra PR

**Files:** none (git/gh only).

- [ ] **Step 1: Branch and push**

If Tasks 1-4 were committed on `main`, move them onto a branch first:

```bash
git log --oneline -4                      # confirm the four commits
git branch feat/centralize-openfga-models
git reset --hard origin/main              # only if the commits were made on main
git checkout feat/centralize-openfga-models
git push -u origin feat/centralize-openfga-models
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --base main --title "Centralize OpenFGA model ownership in cdcf-infra" --body "$(cat <<'BODY'
Implements `docs/superpowers/specs/2026-08-04-openfga-model-ownership-and-upgrade-design.md`.

- Syncs `auth/models/LiturgicalCalendar.json` from `LiturgicalCalendarAPI`, which had evolved the deployed model twice since this copy was written.
- Adds `auth/models/<Store>.lock.json` and makes `setup-openfga.sh` refuse to upload when a store's latest model is not the recorded one (`--force-model-upload` overrides). Verified against a throwaway in-memory OpenFGA: the run that previously overwrote an out-of-band model now exits 7.
- Documents the ownership rule and removes the interim "do not re-run" warning.

Follow-up in `LiturgicalCalendarAPI` removes that repo's model copy and adds an `authz-seed` service; it must land after this.
BODY
)"
```

- [ ] **Step 3: Merge after review**

```bash
gh pr merge --merge --delete-branch
```

The `sync-to-vps.yml` workflow fast-forwards `/opt/cdcf-auth` on merge. No compose restart happens, and no provisioning runs — those stay manual.

---

### Task 6: LitCal repo — replace model ownership with `authz-seed`

**Files (in `/home/johnrdorazio/development/LiturgicalCalendar/LiturgicalCalendarAPI`):**
- Delete: `scripts/openfga-model.json`
- Modify: `docker-compose.yml` (add `authz-seed` after the `openfga` service)
- Modify: `scripts/setup-openfga.sh` (drop model upload; keep store/model ID discovery and `--update-env`)
- Modify: `docs/ops/test-scope-migration-runbook.md`, `docs/enhancements/AUTHENTICATION_ROADMAP.md`, `infrastructure/README.md`

**Interfaces:**
- Consumes: cdcf-infra `main` containing Tasks 1-4 (the seed clones it).
- Produces: a local stack whose store and model come from cdcf-infra, with `OPENFGA_STORE_ID`/`OPENFGA_MODEL_ID` still written into env files by `scripts/setup-openfga.sh --update-env`.

- [ ] **Step 1: Confirm the prerequisite landed**

```bash
git -C /home/johnrdorazio/development/CatholicOS_org/cdcf-infra fetch origin main
git -C /home/johnrdorazio/development/CatholicOS_org/cdcf-infra log origin/main --oneline -1
```

Expected: the merge commit from Task 5. Do not proceed otherwise — the seed would clone a `main` without the synced model.

- [ ] **Step 2: Branch from `development`**

```bash
cd /home/johnrdorazio/development/LiturgicalCalendar/LiturgicalCalendarAPI
git checkout development && git pull --ff-only
git checkout -b feat/consume-cdcf-infra-openfga-model
```

- [ ] **Step 3: Inventory every consumer of the model file**

```bash
grep -rn "openfga-model.json" --include='*' . | grep -v '^./.git' 
```

Expected hits: `scripts/setup-openfga.sh:28`, `docs/ops/test-scope-migration-runbook.md`, `docs/enhancements/AUTHENTICATION_ROADMAP.md`, three `docs/superpowers/specs/*` files. Historical spec/plan documents under `docs/superpowers/` describe past work and are **left untouched**; only the operational docs are updated.

- [ ] **Step 4: Add the `authz-seed` service**

In `docker-compose.yml`, immediately after the `openfga` service block, add (ported from `martyrology-api/docker-compose.yml:172-197`, adapted to this stack's `zitadel` network and store name):

```yaml
  # Seeds the OpenFGA store + authorization model from cdcf-infra, which owns
  # every model on the shared umbrella instance. This repo intentionally keeps
  # no model file: a second copy is what let a stale model silently revert the
  # deployed one in August 2026.
  authz-seed:
    image: alpine:3.21
    restart: "no"
    environment:
      CDCF_INFRA_REF: "${CDCF_INFRA_REF:-main}"
      OPENFGA_PRESHARED_KEY: "${OPENFGA_AUTHN_PRESHARED_KEYS:-}"
    entrypoint:
      - /bin/sh
      - -c
      - |
        set -eu
        apk add --no-cache bash curl jq git >/dev/null
        rm -rf /tmp/cdcf-infra
        git clone --depth 1 --branch "$$CDCF_INFRA_REF" \
          https://github.com/CatholicOS/cdcf-infra.git /tmp/cdcf-infra
        cd /tmp/cdcf-infra/auth
        cat > .env.local <<EOF
        OPENFGA_API_URL=http://openfga:8080
        OPENFGA_INTERNAL_URL=http://openfga:8080
        OPENFGA_PRESHARED_KEY=$$OPENFGA_PRESHARED_KEY
        EOF
        ./setup-openfga.sh --target local --create-litcal-store
    networks:
      - zitadel
    depends_on:
      openfga:
        condition: service_healthy
```

Note: this stack defaults `OPENFGA_AUTHN_METHOD` to `none`, in which case `OPENFGA_PRESHARED_KEY` is empty and OpenFGA ignores the bearer token — the seed works either way.

- [ ] **Step 5: Reduce `scripts/setup-openfga.sh` to ID discovery + env wiring**

Delete the model-upload path — the `MODEL_FILE` variable (line 28), the function that POSTs to `/authorization-models`, and its call site — and replace the model-creation step with a read of the model the seed already uploaded:

```bash
# The authorization model is owned by cdcf-infra and uploaded by the
# `authz-seed` compose service. This script no longer creates or updates it;
# it reads back what is in the store and wires the IDs into .env files.
get_latest_model_id() {
    local store_id="$1" body
    body=$(curl -sS --fail-with-body "${OPENFGA_URL}/stores/${store_id}/authorization-models?page_size=1") || {
        echo -e "${RED}Failed to read authorization models for store ${store_id}${NC}" >&2
        exit 1
    }
    local model_id
    model_id=$(echo "$body" | jq -r '.authorization_models[0].id // empty')
    if [[ -z "$model_id" ]]; then
        echo -e "${RED}Store ${store_id} has no authorization model.${NC}" >&2
        echo -e "${YELLOW}Run 'docker compose up authz-seed' to seed it from cdcf-infra.${NC}" >&2
        exit 1
    fi
    echo "$model_id"
}
```

Update the header usage comment to state that the model comes from cdcf-infra via `authz-seed`, and that this script only discovers IDs and updates env files.

- [ ] **Step 6: Delete the model file**

```bash
git rm scripts/openfga-model.json
```

- [ ] **Step 7: Update the operational docs**

In `docs/ops/test-scope-migration-runbook.md`, replace the step that compares/applies `scripts/openfga-model.json` (around lines 47 and 215-216) with: change the model in `cdcf-infra/auth/models/LiturgicalCalendar.json`, get it merged, have the operator run `./setup-openfga.sh --target production --create-litcal-store` on the VPS, then re-pin `OPENFGA_MODEL_ID` from the new model ID. Apply the same substitution in `docs/enhancements/AUTHENTICATION_ROADMAP.md` and `infrastructure/README.md`.

- [ ] **Step 8: Verify the local stack end-to-end**

```bash
docker compose down -v
docker compose up -d db openfga-migrate openfga
docker compose up authz-seed
```

Expected: the seed clones cdcf-infra, prints `✓ Created store: LiturgicalCalendar` (or finds it), `✓ Uploaded model: <id>`, `✓ Lock updated: …` (inside the container only — the clone is disposable), and exits 0.

```bash
./scripts/setup-openfga.sh --update-env
grep -E '^OPENFGA_(STORE|MODEL)_ID=' .env.local
```

Expected: both IDs populated, the model ID matching what the seed uploaded.

- [ ] **Step 9: Confirm the deleted file has no remaining operational consumer**

```bash
grep -rn "openfga-model.json" --include='*' . | grep -v '^./.git' | grep -v 'docs/superpowers/'
```

Expected: no output.

- [ ] **Step 10: Commit and open the PR against `development`**

```bash
git add -A
git commit -m "Consume the OpenFGA model from cdcf-infra instead of owning a copy

cdcf-infra now owns every authorization model on the shared umbrella instance.
This repo's copy had diverged from it in both directions over time, and in
August 2026 the infra copy came within one command of reverting the deployed
model. Delete the local model, seed the store from cdcf-infra via an
authz-seed service (same pattern as martyrology-api), and reduce
scripts/setup-openfga.sh to ID discovery plus env wiring."
git push -u origin feat/consume-cdcf-infra-openfga-model
gh pr create --base development --title "Consume the OpenFGA model from cdcf-infra" --body "See CatholicOS/cdcf-infra design doc 2026-08-04-openfga-model-ownership-and-upgrade-design.md. Model ownership for the shared OpenFGA instance is centralized in cdcf-infra; this repo seeds its local store from there and no longer keeps a model file. Requires the cdcf-infra PR to be merged first (it is)."
```

---

### Task 7: Verify the guard on production, read-only

**Files:** none.

- [ ] **Step 1: Confirm the VPS has the merged code**

```bash
ssh ubuntu@catholicdigitalcommons.org 'git -C /opt/cdcf-auth log --oneline -1; ls /opt/cdcf-auth/auth/models/'
```

Expected: the Task 5 merge commit, and both `.lock.json` files present.

- [ ] **Step 2: Confirm the lock matches the live store**

```bash
ssh ubuntu@catholicdigitalcommons.org 'bash -s' <<'EOS'
set -euo pipefail
cd /opt/cdcf-auth/auth
KEY=$(grep -m1 '^OPENFGA_PRESHARED_KEY=' .env.production | cut -d= -f2- | tr -d '"')
MISMATCH=0
for n in LiturgicalCalendar Martyrology; do
  # jq -er with `// empty`: a missing field prints nothing and jq exits
  # non-zero, instead of printing the literal string "null" — two "null"s
  # (a broken lock file and a failed API call) would otherwise compare equal
  # and read as a pass.
  if ! s=$(jq -er '.store_id // empty' "models/$n.lock.json") || [[ -z "$s" ]]; then
    echo "$n: FAILURE — lock file missing store_id"; MISMATCH=1; continue
  fi
  if ! m=$(jq -er '.model_id // empty' "models/$n.lock.json") || [[ -z "$m" ]]; then
    echo "$n: FAILURE — lock file missing model_id"; MISMATCH=1; continue
  fi
  # Status-code check rather than `curl --fail-with-body` (requires curl
  # >= 7.76.0, not guaranteed on the VPS).
  http_code=$(curl -sS -o "/tmp/live-$n.json" -w '%{http_code}' "http://127.0.0.1:8081/stores/$s/authorization-models?page_size=1" -H "Authorization: Bearer $KEY")
  if [[ "$http_code" != "200" ]]; then
    echo "$n: FAILURE — live model request returned HTTP $http_code"; MISMATCH=1; continue
  fi
  if ! live=$(jq -er '.authorization_models[0].id // empty' "/tmp/live-$n.json") || [[ -z "$live" ]]; then
    echo "$n: FAILURE — live response has no model id"; MISMATCH=1; continue
  fi
  if [[ "$m" == "$live" ]]; then
    echo "$n: OK ($m)"
  else
    echo "$n: MISMATCH lock=$m live=$live"
    MISMATCH=1
  fi
done
exit "$MISMATCH"
EOS
```

Expected: `OK` for both, and the command exits 0. A mismatch prints `MISMATCH` for that
store **and** makes the script exit 1 — the explicit flag means a mismatch fails the
check instead of being swallowed by an `&&`/`||` chain that always reports success.
A `FAILURE` line (broken lock file, non-200 from the live request, or a response with
no model id) also sets the exit code — it is treated the same as a mismatch rather than
comparing empty-to-empty and passing. A mismatch or failure means investigate before
running any store action.

---

### Task 8: Operator — apply the synced model to production

**Files:** none (operator action on the VPS).

This is the only step that can change production, and it is expected to be a **no-op upload**: the synced file already equals the deployed model.

- [ ] **Step 1: Dry expectation**

State the expectation before running, so a surprise is obvious: the run should print `✓ Model unchanged (01KW4FW2ZCT1E693PY8D9TJEFM) — no upload needed` and must NOT print `Uploaded model`.

- [ ] **Step 2: Run it**

```bash
ssh ubuntu@catholicdigitalcommons.org
cd /opt/cdcf-auth/auth
./setup-openfga.sh --target production --create-litcal-store
```

- [ ] **Step 3: Check the outcome**

If it printed `Uploaded model`, the file and the deployed model diverged after all — record the new model ID, update `auth/models/LiturgicalCalendar.lock.json` in a follow-up PR, and tell the LitCal maintainers their `OPENFGA_MODEL_ID` pin must move. If it printed `Model unchanged`, nothing further is needed.

- [ ] **Step 4: Confirm the store is untouched**

```bash
KEY=$(grep -m1 '^OPENFGA_PRESHARED_KEY=' /opt/cdcf-auth/auth/.env.production | cut -d= -f2- | tr -d '"')
curl -sS "http://127.0.0.1:8081/stores/01KRSCF4GVX0X4ZNXXJQEC4XXJ/authorization-models" \
  -H "Authorization: Bearer $KEY" | jq -r '.authorization_models | length, .[0].id'
```

Expected: still `3` models, latest still `01KW4FW2ZCT1E693PY8D9TJEFM`.
