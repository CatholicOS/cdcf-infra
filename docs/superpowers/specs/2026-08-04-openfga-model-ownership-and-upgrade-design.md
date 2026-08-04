# OpenFGA model ownership + 1.15.1 → 1.18.2 upgrade — design

**Date:** 2026-08-04
**Repos touched:** `cdcf-infra`, `LiturgicalCalendarAPI`, `LiturgicalCalendarFrontend`, `martyrology-api`
**Status:** design, pending implementation plan

---

## 1. Why

The LiturgicalCalendar authorization model exists in two repos with no rule about which one wins, and they have diverged:

| Copy | State |
| --- | --- |
| `LiturgicalCalendarAPI/scripts/openfga-model.json` | Matches the deployed model exactly (verified 2026-08-04 under `upload_model_if_changed`'s own normalization). |
| `cdcf-infra/auth/models/LiturgicalCalendar.json` | Frozen at the 2026-05-16 version (`dd343e5`); two revisions behind. |

The deployed store `01KRSCF4GVX0X4ZNXXJQEC4XXJ` holds three models: `01KRSCF4K9W2EWZ1X2PP1QVH3B` (2026-05-16, what cdcf-infra still describes), `01KW40P7AM87W4Y864D2RZDR0B` (2026-06-27T07:46Z), and the current `01KW4FW2ZCT1E693PY8D9TJEFM` (2026-06-27T12:11Z). The LitCal team evolved it in their repo — `2060b19a` (calendar-scoped test types), `76033bfb` (admin-superset, `member_nation` TTU, drop `deleter`), `ea6fdd6c` (drop `test_definition`) — and uploaded from there.

**The live hazard:** `upload_model_if_changed` (`auth/setup-openfga.sh:204`) uploads a new model version whenever the file differs from the store's latest. They differ. So `./setup-openfga.sh --target production --create-litcal-store` — a command the handbook presented as routine and idempotent — would push the May model on top as the new latest, silently reverting `general_roman_calendar`, three `*_test` types and `member_nation`, and resurrecting `test_definition`/`deleter`. Pinned consumers survive; anything resolving "latest" regresses.

Martyrology, meanwhile, does the opposite: cdcf-infra owns `auth/models/Martyrology.json` and `Martyrology.tuples.json`, and `martyrology-api`'s local stack consumes them by cloning this repo (`martyrology-api/docker-compose.yml:172-197`).

Two patterns, opposite directions, one shared instance. This design picks one.

## 2. Decision

**cdcf-infra owns every authorization model on the shared OpenFGA instance.**

For each store it owns: the model (`auth/models/<Store>.json`), the structural tuples (`auth/models/<Store>.tuples.json`), store creation, and the `--create-{project}-store` shorthand. Project repos hold no model file.

Rejected alternatives:

- **Project repos own models.** Defensible if models are read as domain artifacts, but it fragments disaster recovery across four repos, and dismantles working machinery (martyrology's `authz-seed`, the centralized tuples file) to do it.
- **Snapshot + drift check.** Keeps two copies and adds a check to police them — the "do both" this decision exists to avoid.

Consumers reach models two ways, both already proven:

1. **Production** — an operator runs `setup-openfga.sh` on the VPS.
2. **Local dev** — an `authz-seed` container clones cdcf-infra and runs the store action against the local OpenFGA.

## 3. LitCal migration

**3.1 — cdcf-infra PR (must land first).**

1. Copy `LiturgicalCalendarAPI/scripts/openfga-model.json` → `auth/models/LiturgicalCalendar.json`. The file already matches production, so the next `--create-litcal-store` reports *"Model unchanged — no upload needed"* rather than uploading.
2. Add the lock-file guard (§4) and generate `auth/models/LiturgicalCalendar.lock.json` + `auth/models/Martyrology.lock.json` recording the currently deployed model IDs.
3. Remove the "do not re-run `--create-litcal-store`" warning added to `docs/SYSADMIN.md` §4.8 and `auth/handoffs/liturgicalcalendar.md` on 2026-08-04 — the hazard is gone once the file is synced and the guard is in place.

**3.2 — LitCal PR (after 3.1 is on cdcf-infra's `main`).**

Target the `development` branch, not `main` — that is the default branch across the Liturgical-Calendar GitHub org (`docs/SYSADMIN.md` §10.3). Applies to both LitCal repos if the frontend needs a companion change.

1. Delete `scripts/openfga-model.json` from `LiturgicalCalendarAPI`.
2. Add an `authz-seed` service to the local compose, ported from `martyrology-api/docker-compose.yml:172-197`: alpine, `git clone --depth 1 --branch "$CDCF_INFRA_REF"`, write a throwaway `.env.local`, run `./setup-openfga.sh --target local --create-litcal-store`.
3. Repoint anything that read the deleted file — the implementation plan must grep both LitCal repos for `openfga-model.json` references (compose services, CI steps, test fixtures, docs) rather than assuming the local stack is the only consumer.
4. Stop uploading models from LitCal's deploy path.

The resulting model-change process: PR to cdcf-infra → operator runs `--create-litcal-store` → new model ID → LitCal re-pins `OPENFGA_MODEL_ID`. The re-pin step already existed, so this adds one PR, not one process.

`LiturgicalCalendarFrontend` holds no model and needs no ownership change — it appears in this design only for the version bump (§5).

## 4. Guardrail: per-store lock file

The invariant centralization creates is *cdcf-infra is the only writer of models to the shared instance*. The guard detects violations of exactly that.

**`auth/models/<Store>.lock.json`**, committed:

```json
{
  "store_name": "LiturgicalCalendar",
  "store_id": "01KRSCF4GVX0X4ZNXXJQEC4XXJ",
  "model_id": "01KW4FW2ZCT1E693PY8D9TJEFM"
}
```

Three fields, deliberately. No commit hash or timestamp: the lock file is committed, so `git log auth/models/<Store>.lock.json` already gives the provenance chain and does it more reliably than the script could — on the VPS the worktree may sit at a different commit than the one that authored the model, or be dirty. Recording state needed to detect drift, and nothing about the file itself, is what keeps lockfiles honest.

`upload_model_if_changed` checks it before doing anything:

| Store's latest model ID | Lock | Behaviour |
| --- | --- | --- |
| matches lock | present | Today's behaviour: compare file to store, upload if changed, rewrite lock. |
| ≠ lock | present | **Refuse and report**, printing both IDs. `--force-model-upload` overrides. |
| — | absent, file matches store | Adopt: write the lock, continue. |
| — | absent, file differs | Refuse; require `--force-model-upload`. |

Against the 2026-08-04 incident this fires correctly: lock `01KRSCF4K9…` vs store `01KW4FW2ZC…` → refuse instead of regress.

Model upload stays inside `--create-store` rather than moving to a separate action: splitting adds a step to every workflow to defend a case the lock already catches, and an explicit `--upload-model` run with a stale file regresses the store just the same.

Side benefit: the lock is a committed, greppable record of each store's current model ID, so handoff docs can reference it instead of hardcoding IDs that rot — the exact failure fixed by hand in `9fb397e` and `a43109e`.

## 5. OpenFGA 1.15.1 → 1.18.2

**Postgres is unaffected by the v1.18.0 migration warning.** That warning covers MySQL schema migration `008_collate_identifiers.sql`, a case-sensitivity fix for MySQL identifier comparison (CVE-2026-55170, CVE-2026-55689). Postgres and SQLite were already case-sensitive. Every deployment here sets `OPENFGA_DATASTORE_ENGINE: postgres`.

Postgres migration assets by tag:

| Tag | Postgres migrations |
| --- | --- |
| v1.8.12 | 001–005 |
| v1.15.1 | 001–006 |
| v1.18.2 | 001–006 |

So 1.15.1 → 1.18.2 applies **no** schema migration; the `openfga-migrate` one-shot no-ops. Rollback is a pin revert with no schema to undo — the property that makes this low-risk.

| Target | From | Environment |
| --- | --- | --- |
| `cdcf-infra/auth/docker-compose.prod.yml` (both services) | 1.15.1 | Production |
| `martyrology-api/docker-compose.yml` (both services) | 1.15.1 | Local dev |
| `LiturgicalCalendarAPI/docker-compose.yml` (both services) | 1.8.12 | Local dev |
| `LiturgicalCalendarFrontend/docker-compose.yml` (both services) | 1.8.12 | Local dev |

The 1.8.12 → 1.18.2 jump picks up `006_add_collate_index`, applied to throwaway dev databases.

**Verify before the production pin changes** (each is an assumption today, not a fact):

1. `/usr/local/bin/grpc_health_probe` still ships in the 1.18.2 image — both our compose and martyrology's healthchecks depend on it.
2. Whether the playground-plus-preshared startup panic documented at `martyrology-api/docker-compose.yml:141-145` still applies at 1.18.2.
3. `OPENFGA_AUTHN_METHOD` / `OPENFGA_AUTHN_PRESHARED_KEYS` semantics unchanged across the range.

**Post-upgrade verification on production:** `/healthz` on both subdomains; `ListAuthorizationModels` on both stores returns the same latest IDs as before the bump; one `Check` against each store returns the expected decision.

## 6. Deployment mechanics

`.github/workflows/sync-to-vps.yml` runs `git -C /opt/cdcf-auth pull --ff-only origin main` on merge to `main`. It is **pull-only by design** — no `docker compose up`, no provisioning runs. Therefore:

- Compose changes (the image pin bump) reach the VPS by merge, then need an operator to bring the stack up.
- `setup-openfga.sh` runs stay manual on the VPS.

## 7. Sequencing

1. cdcf-infra PR — model sync, lock files + guard, warning removal (§3.1, §4).
2. LitCal PR — delete model, add `authz-seed` (§3.2). Requires 1 on `main`, since the seed clones this repo.
3. Version bumps — local composes first, production last, after the §5 image checks.

Steps 1–2 (ownership) and step 3 (upgrade) are independent and may become two implementation plans; the only ordering constraint that matters is 1 before 2.

## 8. Out of scope

- Zitadel version (`v4.15.0`) and any Zitadel-side provisioning.
- Re-homing Martyrology's model or tuples (already centralized).
- The unresolved `unassigned_en_translatio` governance question (`auth/handoffs/martyrology.md`).
- Promoting generated IDs to GitHub Actions secrets (`docs/SYSADMIN.md` §8).

## 9. Risks

| Risk | Mitigation |
| --- | --- |
| LitCal model changes now need a cdcf-infra PR, adding friction to the fastest-moving model. | Accepted deliberately; the coordinated `OPENFGA_MODEL_ID` re-pin already made this a two-repo operation. |
| A `--force-model-upload` escape hatch can still regress a store. | It is explicit and logged; the failure mode being removed is the *silent* one. |
| Local dev depends on cloning cdcf-infra. | Already true for martyrology-api and working; `CDCF_INFRA_REF` allows pinning a branch. |
| 1.18.2 image or flag differences break the stack. | The three §5 checks precede the production bump; rollback is a pin revert with no schema change. |
