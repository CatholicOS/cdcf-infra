# Target-aware OIDC provisioning for the URL-bearing actions — design

**Date:** 2026-08-17
**Repos touched:** `cdcf-infra`, `LiturgicalCalendarFrontend` (staging deploy only)
**Issue:** #20
**Depends on:** a local Zitadel stack in `cdcf-website` — built before this and **satisfied** as of 2026-08-17 (see §2.4)
**Status:** design, pending implementation plan

---

## 1. Why

Three provisioning actions in `auth/setup-zitadel.sh` register OIDC redirect and post-logout URIs. Issue #20 opened because none of them consulted `--target`, so `--target local` wrote production URLs into a local Zitadel.

That framing is now partly stale, and the corrections matter more than the original complaint.

**Martyrology was already fixed.** `:799-815` selects app name, origins and devMode by target, and `do_provision_martyrology_frontend:929-936` skips with a warning when the resolved set is empty. It is the in-file precedent this design generalizes, not a site to repair.

**The real hazard is `staging`, not `local`.** `create_oidc_web_app:485` sends the whole `redirectUris` array to `UpdateApplication`, so a run **replaces** the registered set rather than extending it. `staging` denotes the *production* Zitadel carrying the staging origin set (decided in #20's comment; the staging frontends already authenticate against the production instance). LitCal's single app holds production **and** staging origins together, so the obvious per-target split — pick the origin list by target, pass it to the existing helper — would strip the production callback on a `--target staging` run. That is a production outage, not the confusion #20's case 4 weighed.

Writing a production URL into a *local* Zitadel remains what case 4 concluded: confusing, not damaging.

## 2. Decision

**One app per (property, environment), with distinct names; `--target` selects which one is provisioned.** Where a property has no origin set for a target, the action skips with a warning and exits 0.

This is not a guard bolted onto the existing shape. The app split is itself the fix: once production and staging origins live in separately-named apps, replace semantics can no longer strip production, because no run ever touches both.

CDCF already implements this pattern (`CDCF Website` / `CDCF Website (Non-Prod)`), and `:795-797` states that a future Martyrology staging origin must follow it — "a shared name there would overwrite the production app's redirect URIs". LitCal is the sole holdout.

### 2.1 The policy matrix

| Action | `--target local` | `--target staging` | `--target production` |
| --- | --- | --- | --- |
| `--provision-litcal-frontend` | **skip + warn** | app `LiturgicalCalendarFrontend (Staging)` *(new)*, `litcal-staging.johnromanodorazio.com`, devMode=false | app `LiturgicalCalendarFrontend` *(existing)*, `litcal.johnromanodorazio.com`, devMode=false |
| `--provision-cdcf-website` | app `CDCF Website`, `http://localhost:3000`, devMode=true | app `CDCF Website (Non-Prod)`, `staging.catholicdigitalcommons.org` *(localhost removed — see §2.4)* | app `CDCF Website`, `catholicdigitalcommons.org`, devMode=false |
| `--provision-martyrology-frontend` | `http://localhost:3000`, devMode=true *(unchanged)* | **skip + warn** *(unchanged)* | `romanmartyrology.com` *(unchanged)* |

Callback paths are unchanged and remain per-property (`/auth/callback.php` for LitCal, `/api/auth/callback/zitadel` for CDCF and Martyrology).

### 2.2 Why LitCal's `local` registers nothing

LitCal's local Zitadel is provisioned by a **different script** — `LiturgicalCalendarAPI/scripts/setup-zitadel.sh`, extracted from the `litcal-api` image by the Frontend repo's wrapper. It creates its own app named `LiturgicalCalendar Frontend` (with a space) at `http://localhost:${FRONTEND_PORT}/auth/callback.php`.

Registering a LitCal localhost app from cdcf-infra would put a second provisioner on the same instance under a *different* app name, so the two would never converge — they would accumulate. The skip warning names the other script so the reader is not left thinking local LitCal auth is unprovisioned.

This is the one place where "apply consistently across all three" (issue acceptance) yields a deliberate asymmetry, and it is a fact about ownership, not an exception to the policy.

### 2.3 `--all` and the two-sweep consequence

A target now provisions one app per property, not every app. Today `--provision-cdcf-website` creates the production **and** non-prod apps in a single run; after this it creates whichever the target names.

So a full refresh is two sweeps:

```bash
./setup-zitadel.sh --target production --all
./setup-zitadel.sh --target staging    --all
```

This is the behaviour change most likely to surprise an operator and must be documented in `usage()`.

`--all` on any target also re-runs the non-URL actions (`--create-orgs`, `--rename-bootstrap-admin`, `--provision-litcal`, `--provision-martyrology`). They are idempotent and target-agnostic, so this is harmless. Per the issue's acceptance, **the API-type actions are not touched**: `create_oidc_api_app` registers no URIs, so the distinction that matters is URL-bearing vs not, never frontend vs backend.

### 2.4 CDCF's localhost client: removed, once its replacement exists

`CDCF_FRONTEND_NONPROD_URLS` registers `http://localhost:3000` in the **production** Zitadel. This contradicts `CatholicOS/martyrology-api#26`, which settled that local development happens against a separate local Zitadel rather than a localhost client in the production instance — which is why LitCal and Martyrology have none. It is drift predating that decision, and this design removes it.

Removal had a prerequisite: a local Zitadel in `cdcf-website`, which had none (no `zitadel` service in its compose; only `docs/zitadel-oidc-plan.md`). Dropping the localhost origin before that stack existed would not have relocated the capability, it would have deleted it, leaving CDCF developers with no local OIDC login at all.

**That stack was therefore built first, as its own piece of work with its own design** — a different repo and a different subsystem, with `martyrology-api`'s compose as the closest template.

**Status: satisfied.** It shipped on 2026-08-17 (`cdcf-website` PR #286: `zitadel` + `zitadel-db`, later `zitadel-login` + `zitadel-proxy` for Login V2), and its browser sign-in was operator-verified — the check that nothing in the flow reaches `auth.catholicdigitalcommons.org`. The requirement stands rather than lapses: §4.1's order still applies, and the localhost origin is removed only after developers are actually on that stack, which is what "verified, not assumed" meant.

**Consequence for live state:** CDCF's production app is untouched (it already carries only the production origin), but its **non-prod app loses `http://localhost:3000`** on the first `--target staging` run after this lands. That is a real change to the production Zitadel, sequenced in §4.

## 3. Code shape

Per-action data, shared behaviour. The data stays beside the comments explaining it (this file carries several lines of rationale per URL constant); the behaviour exists once.

**One new helper**, beside the existing helpers:

```bash
# no_origins_for_target COUNT TARGET GUIDANCE...
# True when the resolved origin set is empty, after warning. Callers read:
#   no_origins_for_target "${#X_URLS[@]}" "$TARGET" "…" && return 0
```

**Three property-local `case "$TARGET"` blocks** setting app name, origins, devMode and label. Martyrology's block already is this and is refactored onto the helper. `LITCAL_FRONTEND_URLS` and the `CDCF_FRONTEND_URLS` / `CDCF_FRONTEND_NONPROD_URLS` pair are replaced by equivalents.

**`do_provision_cdcf_website`** calls the existing `_emit_cdcf_app` once with the resolved tuple instead of twice with hardcoded ones. Its signature `(project_id, app_name, dev_mode, label, origins...)` already fits; no change to that helper.

**`usage()`** gains a per-target line for each of the three actions — precedent exists at `:99` — plus the two-sweep note from §2.3 and the ordering warning from §4.

## 4. Migration

Two properties touch live state: LitCal (the app split) and CDCF (losing its localhost origin). Martyrology needs no migration.

### 4.1 CDCF

Strictly ordered, because the removal is what makes local dev impossible if it lands early:

1. The `cdcf-website` local Zitadel stack exists and is working (§2.4's prerequisite).
2. CDCF website developers move onto it — verified, not assumed.
3. Only then `--provision-cdcf-website --target staging`, which replaces the non-prod app's URI set and thereby drops `http://localhost:3000`.

The production app is never touched by this sequence.

### 4.2 LitCal

**Production sign-in is never at risk**: the existing app remains the production app, keeping client_id `373289176235245570` and its own origin throughout. Only staging moves.

1. Land the code.
2. `--provision-litcal-frontend --target staging` — creates `LiturgicalCalendarFrontend (Staging)`, emits a new client_id.
3. Re-pin the **staging** LitCal frontend deployment's `ZITADEL_CLIENT_ID` to that value and deploy it.
4. Only then `--provision-litcal-frontend --target production` — this is the step that drops the staging origin from the production app.

**Running 4 before 3 breaks staging sign-in**, because staging still points at the production app's client_id while its origin has just been removed. That window is the entire risk in this design and belongs in both the spec and `usage()`.

`auth/handoffs/liturgicalcalendar.md` records a single frontend client_id (`:21`, `:76`) and gains the staging app alongside it.

Martyrology needs no migration. (CDCF's is §4.1 above — an earlier revision of this spec said CDCF needed none, which stopped being true when the localhost origin moved out of the production Zitadel.)

## 5. Testing

`auth/setup-zitadel.selftest.sh`, mirroring `auth/setup-openfga.selftest.sh`: a stub Zitadel, and per case an asserted exit code **and** an output substring, so a regression that fails for the wrong reason is not a pass.

Cases, at minimum:

- For each of the nine `(action, target)` cells in §2.1: the app name and the exact registered URI set, or the skip warning.
- That `--target staging` on LitCal never sends the production origin, and `--target production` never sends the staging one — the specific regression §1 identifies.
- The three skip paths exit 0, so `--all` sweeps past them.

Both `auth/setup-zitadel.sh` and the new selftest are added to `.github/workflows/validate-models.yml`'s path filters and a step, as `setup-openfga` already is.

The selftest is likely larger than the change itself. It is still the full version rather than a matrix-only check, decided deliberately: asserting the resolved variables alone would pin §2.1's origin lists going in, but stay blind to how they are serialized — a callback path appended to the post-logout URIs, an empty set emitted as `null` instead of `[]`, or the update branch sending the wrong payload. That update branch is exactly where the production-callback-stripping risk lives, so it is the last thing to leave untested. The `setup-openfga.selftest.sh` harness already merged makes the marginal cost small.

## 6. Acceptance (issue #20)

| Required | Where |
| --- | --- |
| Written decision, case 1 (`--all` on a local target) | §2.3 — skip + warn, one behaviour whether swept or named explicitly |
| Written decision, case 2 (CDCF's localhost client) | §2.4 — drift; removed, after its prerequisite stack is built first |
| Written decision, case 3 (API actions stay target-agnostic) | §2.3 — untouched; URL-bearing vs not is the distinction |
| Written decision, case 4 (is a prod URL in a local Zitadel harmful?) | §1 — confusion for `local`; the damaging direction is `staging`, and §2 removes it structurally |
| Applies consistently across all three URL-bearing actions | §2.1, with §2.2 recording LitCal's `local` asymmetry and why it is about ownership |
| `--all` behaviour per target documented in `usage()` | §2.3, §3 |
| No change to the API-type provisioning actions | §2.3 |

## 7. Out of scope

- Building the `cdcf-website` local Zitadel stack. It is a **dependency** of this spec (§2.4), not part of it: different repo, different subsystem, its own design.
- A staging origin for Martyrology — none exists; `:795-797` already records that it must land as a distinctly-named app.
- Reconciling LitCal's two local provisioners (§2.2). Noted, not fixed.
