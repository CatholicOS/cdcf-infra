# Target-Aware OIDC Provisioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the three URL-bearing provisioning actions in `auth/setup-zitadel.sh` select their app name and origin set by `--target`, so `--target local` stops writing production URLs into a local Zitadel and `--target staging` can never strip a production callback.

**Architecture:** Per-action `case "$TARGET"` data blocks (the shape `do_provision_martyrology_frontend` already uses) plus one shared `no_origins_for_target` helper carrying the skip-with-warning behaviour. The app split is the actual fix: once production and staging origins live in separately-named apps, `UpdateApplication`'s replace semantics can no longer strip production, because no run touches both.

**Tech Stack:** Bash, Zitadel management API v2, bats-free selftest in the style of `auth/setup-openfga.selftest.sh` (stub HTTP server + asserted exit codes).

**Spec:** `docs/superpowers/specs/2026-08-17-target-aware-oidc-provisioning-design.md`

**Unblocked:** the spec's §2.4 prerequisite — a local Zitadel in `cdcf-website` — shipped on 2026-08-17 (PR #286) and its browser sign-in was verified by the operator. CDCF's localhost origin can now be removed rather than retained.

## Global Constraints

Copied from the spec. Every task's requirements implicitly include these.

- **The policy matrix (§2.1) is the contract.** Nine `(action, target)` cells:
  - `--provision-litcal-frontend`: local → **skip+warn**; staging → app `LiturgicalCalendarFrontend (Staging)`, `https://litcal-staging.johnromanodorazio.com`, devMode=false; production → app `LiturgicalCalendarFrontend`, `https://litcal.johnromanodorazio.com`, devMode=false.
  - `--provision-cdcf-website`: local → app `CDCF Website`, `http://localhost:3000`, devMode=true; staging → app `CDCF Website (Non-Prod)`, `https://staging.catholicdigitalcommons.org` **only**; production → app `CDCF Website`, `https://catholicdigitalcommons.org`, devMode=false.
  - `--provision-martyrology-frontend`: unchanged — local → `http://localhost:3000` devMode=true; staging → **skip+warn**; production → `https://romanmartyrology.com`.
- **Callback paths are unchanged**: `/auth/callback.php` for LitCal, `/api/auth/callback/zitadel` for CDCF and Martyrology.
- **Skip behaviour is one behaviour**: empty origin set → warn and `return 0`, whether the action was named explicitly or swept by `--all`. Never a non-zero exit.
- **The API-type actions are untouched**: `--provision-litcal`, `--provision-martyrology` use `create_oidc_api_app`, register no URIs, and stay target-agnostic. The distinction is URL-bearing vs not.
- **LitCal's production app keeps client_id `373289176235245570`** — the existing app remains the production app. Only staging gets a new app and a new client_id.
- **LitCal `local` registers nothing on purpose** (§2.2): its local Zitadel is provisioned by `LiturgicalCalendarAPI/scripts/setup-zitadel.sh` under a *different* app name, so a second provisioner here would accumulate rather than converge. The warning must name that script.
- **`--all` on a target provisions one app per property, not all of them.** A full refresh is two sweeps (`--target production --all`, then `--target staging --all`). This must be documented in `usage()`.
- **Exit-code contract is inherited from #27** and must not be widened: 7 belongs to the model-lock guard in `setup-openfga.sh` and has no analogue here; a skip is exit 0.

---

### Task 1: Target-aware policy in `setup-zitadel.sh`

**Files:**

- Modify: `auth/setup-zitadel.sh` — add `no_origins_for_target` beside the other helpers; replace `LITCAL_FRONTEND_URLS` (`:332`) and the `CDCF_FRONTEND_URLS`/`CDCF_FRONTEND_NONPROD_URLS` pair (`:647`, `:652`) with `case "$TARGET"` blocks; refactor `do_provision_martyrology_frontend` (`:927`) onto the helper; make `do_provision_cdcf_website` (`:703`) call `_emit_cdcf_app` once; extend `usage()`.

**Interfaces:**

- Consumes: existing `create_oidc_web_app(project_id, name, redirect_json, postlogout_json, auth_method, dev_mode)` and `_emit_cdcf_app(project_id, app_name, dev_mode, label, origins...)`. Neither changes signature.
- Produces: `no_origins_for_target COUNT TARGET GUIDANCE...` → returns 0 (true) after warning when COUNT is 0. Callers read `no_origins_for_target … && return 0`. Task 2 asserts against the resulting behaviour.

- [ ] **Step 1: Add the shared helper**

Place it beside the other helpers (near `log`/`warn`/`err`), so all three actions can reach it:

```bash
# no_origins_for_target COUNT TARGET GUIDANCE...
#
# True when the resolved origin set is empty, after warning. Callers read:
#   no_origins_for_target "${#X_URLS[@]}" "$TARGET" "..." && return 0
#
# One behaviour whether the action was named explicitly or swept by --all:
# a target a property has no deployment for is not an error, it is nothing to
# do. Exiting non-zero here would make `--all` unusable on any target where
# any one property lacks an origin, which is true of --target staging today.
no_origins_for_target() {
    local count="$1" target="$2"; shift 2
    [[ "$count" -gt 0 ]] && return 1
    warn "No origin is defined for --target ${target}; skipping."
    local line
    for line in "$@"; do warn "  $line"; done
    return 0
}
```

- [ ] **Step 2: Replace `LITCAL_FRONTEND_URLS` with a target-aware block**

At `:332`, replace the two-origin array with:

```bash
# App name AND origins follow --target, because production and staging share
# ONE Zitadel instance. create_oidc_web_app sends the whole redirectUris array
# to UpdateApplication, so a run REPLACES the registered set: if prod and
# staging origins shared an app, `--target staging` would strip the production
# callback. Separately-named apps make that impossible — no run touches both.
#
# --target local registers NOTHING on purpose. LitCal's local Zitadel is
# provisioned by LiturgicalCalendarAPI/scripts/setup-zitadel.sh (extracted from
# the litcal-api image by the Frontend repo's wrapper), which creates its own
# app named "LiturgicalCalendar Frontend" at http://localhost:$FRONTEND_PORT.
# A second provisioner here would use a DIFFERENT name, so the two would never
# converge — they would accumulate.
case "$TARGET" in
    production)
        LITCAL_FRONTEND_APP_NAME="LiturgicalCalendarFrontend"
        LITCAL_FRONTEND_URLS=("https://litcal.johnromanodorazio.com")
        LITCAL_FRONTEND_LABEL="Production"
        ;;
    staging)
        LITCAL_FRONTEND_APP_NAME="LiturgicalCalendarFrontend (Staging)"
        LITCAL_FRONTEND_URLS=("https://litcal-staging.johnromanodorazio.com")
        LITCAL_FRONTEND_LABEL="Staging"
        ;;
    *)
        LITCAL_FRONTEND_APP_NAME="LiturgicalCalendarFrontend"
        LITCAL_FRONTEND_URLS=()
        LITCAL_FRONTEND_LABEL="$TARGET"
        ;;
esac
```

Keep the existing `LITCAL_FRONTEND_APP_NAME` assignment at `:316` deleted or superseded — there must be exactly one definition. Keep `LITCAL_FRONTEND_CALLBACK_PATH` unchanged.

- [ ] **Step 3: Guard `do_provision_litcal_frontend`**

Immediately after its `log` line (`:589`), before any API call:

```bash
    no_origins_for_target "${#LITCAL_FRONTEND_URLS[@]}" "$TARGET" \
        "LitCal's local Zitadel is provisioned by the API repo, not this script:" \
        "  LiturgicalCalendarAPI/scripts/setup-zitadel.sh (run via the Frontend" \
        "  repo's scripts/setup-zitadel.sh wrapper). It creates its own app." \
        "Use --target staging or --target production here." && return 0
```

Also update its `log` line to name the label, matching Martyrology's style:
`log "Provisioning LiturgicalCalendar Frontend OIDC app ($LITCAL_FRONTEND_LABEL)"`.

- [ ] **Step 4: Replace the CDCF origin pair with a target-aware block**

At `:647`-`:656`, replace `CDCF_FRONTEND_URLS` and `CDCF_FRONTEND_NONPROD_URLS` with:

```bash
# One app per environment, selected by --target. CDCF already had the two-app
# split; this makes the target choose between them instead of creating both.
#
# http://localhost:3000 is deliberately ABSENT from every deployed target. It
# used to ride along in the non-prod app, which put a localhost client in the
# PRODUCTION Zitadel — contradicting CatholicOS/martyrology-api#26, which
# settled that local development runs against a local Zitadel instead. That
# local stack now exists (cdcf-website PR #286), so the origin moves to
# --target local rather than being deleted.
case "$TARGET" in
    production)
        CDCF_FRONTEND_APP_NAME="$CDCF_APP_NAME"
        CDCF_FRONTEND_URLS=("https://catholicdigitalcommons.org")
        CDCF_FRONTEND_DEV_MODE="false"
        CDCF_FRONTEND_LABEL="Production"
        ;;
    staging)
        CDCF_FRONTEND_APP_NAME="$CDCF_APP_NAME_NONPROD"
        CDCF_FRONTEND_URLS=("https://staging.catholicdigitalcommons.org")
        CDCF_FRONTEND_DEV_MODE="false"
        CDCF_FRONTEND_LABEL="Staging"
        ;;
    local)
        CDCF_FRONTEND_APP_NAME="$CDCF_APP_NAME"
        CDCF_FRONTEND_URLS=("http://localhost:3000")
        CDCF_FRONTEND_DEV_MODE="true"
        CDCF_FRONTEND_LABEL="Local"
        ;;
    *)
        CDCF_FRONTEND_APP_NAME="$CDCF_APP_NAME"
        CDCF_FRONTEND_URLS=()
        CDCF_FRONTEND_DEV_MODE="false"
        CDCF_FRONTEND_LABEL="$TARGET"
        ;;
esac
```

Note `staging` sets devMode=false: the non-prod app no longer carries an HTTP localhost origin, so it no longer needs devMode. Only `--target local` does.

- [ ] **Step 5: Make `do_provision_cdcf_website` provision one app**

Replace the two `_emit_cdcf_app` calls (`:725`, `:727`) with one, and add the guard after the project/roles setup:

```bash
    no_origins_for_target "${#CDCF_FRONTEND_URLS[@]}" "$TARGET" \
        "No CDCF Website origin is defined for this target." && return 0

    _emit_cdcf_app "$project_id" "$CDCF_FRONTEND_APP_NAME" \
        "$CDCF_FRONTEND_DEV_MODE" "$CDCF_FRONTEND_LABEL" \
        "${CDCF_FRONTEND_URLS[@]}"
```

Place the guard AFTER `create_project`/`create_roles` so org and project setup still happens on any target, and BEFORE the app emit.

- [ ] **Step 6: Refactor Martyrology onto the helper**

`do_provision_martyrology_frontend` (`:927`) already skips correctly with its own inline `if`. Replace that inline block with the helper so the behaviour has one implementation:

```bash
    no_origins_for_target "${#MARTYROLOGY_FRONTEND_URLS[@]}" "$TARGET" \
        "Martyrology has no staging deployment yet. Use --target local" \
        "(localhost, against a local Zitadel) or --target production." && return 0
```

Its `case "$TARGET"` block at `:799` already matches the required shape — leave it.

- [ ] **Step 7: Document the two-sweep consequence in `usage()`**

Add per-target lines for the three actions (precedent at `:99`), plus:

```
Targets and sweeps:
  A target provisions ONE app per property, not every app. --all --target
  production creates the production apps; --all --target staging creates the
  staging ones. A full refresh is therefore two sweeps:
      ./setup-zitadel.sh --target production --all
      ./setup-zitadel.sh --target staging    --all
  Actions with no origin for the given target skip with a warning and exit 0.

  ORDERING WARNING (LitCal): --target staging creates the new
  "LiturgicalCalendarFrontend (Staging)" app and emits a NEW client_id. Re-pin
  and deploy the staging frontend BEFORE running --target production, which is
  the step that drops the staging origin from the production app. Running them
  the other way round breaks staging sign-in in the gap.
```

- [ ] **Step 8: Syntax check and commit**

```bash
bash -n auth/setup-zitadel.sh
```

Expected: clean. Commit with a message naming the app split as the fix, not the guard.

---

### Task 2: Selftest and CI gate

**Files:**

- Create: `auth/setup-zitadel.selftest.sh`
- Modify: `.github/workflows/validate-models.yml` (paths + a step)

**Interfaces:**

- Consumes: Task 1's behaviour — nine `(action, target)` cells and the skip contract.
- Produces: nothing other code reads.

Mirror `auth/setup-openfga.selftest.sh` exactly in shape: a `python3` stub over the endpoints the script calls, a copy of the script in a sandbox (the script derives paths from its own location), and `expect EXIT SUBSTRING SCENARIO DESC -- ARGS...` asserting both an exit code and an output substring.

- [ ] **Step 1: Write the selftest**

Cases, at minimum one per matrix cell plus the contract:

- LitCal local → exit 0, output contains `LiturgicalCalendarAPI/scripts/setup-zitadel.sh`
- LitCal staging → exit 0, output contains `LiturgicalCalendarFrontend (Staging)` AND `litcal-staging.johnromanodorazio.com`
- LitCal production → exit 0, output contains `litcal.johnromanodorazio.com`
- **LitCal staging never sends the production origin** — assert the output does NOT contain `https://litcal.johnromanodorazio.com/auth/callback.php`. This is the specific regression the design exists to prevent; assert it explicitly rather than trusting the app-name case.
- CDCF local → exit 0, `http://localhost:3000`, devMode=true
- CDCF staging → exit 0, `staging.catholicdigitalcommons.org`, and NOT `localhost:3000`
- CDCF production → exit 0, `catholicdigitalcommons.org`, and NOT `staging.`
- Martyrology local / staging (skip) / production → exit 0 each, staging output containing `no staging deployment`
- `--all --target staging` → exit 0 overall, sweeping past the two skips
- Usage errors still exit 64 (no action; unknown target)

- [ ] **Step 2: Prove it fails before it passes**

Run the selftest against the PRE-Task-1 script (`git stash` Task 1, or a copy from `git show HEAD~1:auth/setup-zitadel.sh`) and confirm the target-aware cases FAIL. A selftest written after the implementation that has never been red is not evidence.

- [ ] **Step 3: Gate it**

In `.github/workflows/validate-models.yml`, add to BOTH `paths:` lists:

```yaml
      - 'auth/setup-zitadel.sh'
      - 'auth/setup-zitadel.selftest.sh'
```

and a step beside the `setup-openfga` one:

```yaml
      - name: Self-test setup-zitadel's target-aware provisioning
        run: ./auth/setup-zitadel.selftest.sh
```

- [ ] **Step 4: Run both selftests and commit**

```bash
./auth/setup-openfga.selftest.sh && ./auth/setup-zitadel.selftest.sh
```

Expected: both report all cases behaved as declared.

---

### Task 3: Docs — handoff note and spec correction

**Files:**

- Modify: `auth/handoffs/liturgicalcalendar.md`
- Modify: `docs/superpowers/specs/2026-08-17-target-aware-oidc-provisioning-design.md`

- [ ] **Step 1: Fix the spec's stale closing line**

§4.2 still ends with "CDCF and Martyrology need no migration." The revision that added §4.1 made that false for CDCF. Change it to "Martyrology needs no migration." — §4's opening sentence already says which two properties touch live state.

- [ ] **Step 2: Note the LitCal app split in the handoff**

`auth/handoffs/liturgicalcalendar.md` records one frontend client_id (`:21`, `:76`). Add, beside it, that a second app `LiturgicalCalendarFrontend (Staging)` now exists for the staging deployment, that the production client_id `373289176235245570` is unchanged, and that the staging client_id is emitted by `--provision-litcal-frontend --target staging` and must be recorded here after that run. Do NOT invent a staging client_id — it is not knowable until the run, exactly as `LiturgicalCalendar.lock.json`'s model ID was not.

- [ ] **Step 3: Commit**

---

## Self-Review

**Spec coverage:** §2.1 matrix → Task 1 Steps 2/4/6 + Task 2 Step 1. §2.2 LitCal local asymmetry → Task 1 Steps 2/3, asserted in Task 2. §2.3 two-sweep + `--all` → Task 1 Step 7. §2.4 CDCF localhost removal → Task 1 Step 4. §3 code shape → Task 1 Steps 1-6. §4.1/§4.2 migration → Task 1 Step 7's usage warning + Task 3 Step 2; the runs themselves are operator actions, deliberately not automated. §5 testing → Task 2. §6 acceptance → satisfied across all three.

**Not delivered by this plan, by design:** the migration runs themselves (§4.1 step 3, §4.2 steps 2-4). They mutate the production Zitadel and emit a client_id that must then be recorded; they belong to an operator, with a follow-up PR for the handoff value — the same shape as the OpenFGA lock file.

**Placeholder scan:** none. Every step carries the literal bash or YAML to apply.

**Type consistency:** `no_origins_for_target` takes `(COUNT, TARGET, GUIDANCE...)` and is called identically in Steps 3, 5 and 6. Variable families are consistent per property: `*_APP_NAME`, `*_URLS`, `*_DEV_MODE`, `*_LABEL`.
