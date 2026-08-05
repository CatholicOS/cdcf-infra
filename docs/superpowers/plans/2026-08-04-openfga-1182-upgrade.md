# OpenFGA 1.15.1 → 1.18.2 Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every OpenFGA deployment — the production umbrella instance and three local dev stacks — to `openfga/openfga:v1.18.2`, having first verified the image assumptions the composes depend on. Then (Tasks 6-8, independent of the upgrade) enforce the model contract between cdcf-infra and its consumers in cdcf-infra's own CI, so a model change that breaks a consumer fails in the PR that causes it rather than downstream.

**Architecture:** Image pin bumps only. No schema migration is involved on Postgres, so the `openfga-migrate` one-shot no-ops and rollback is a pin revert. Local stacks move first so any surprise surfaces off production; production moves last and is verified with health, model-listing and Check probes.

**Tech Stack:** Docker / Docker Compose, Postgres, `curl`, `jq`, `gh`.

## Global Constraints

- Source design: `docs/superpowers/specs/2026-08-04-openfga-model-ownership-and-upgrade-design.md` §5.
- Target version is exactly `openfga/openfga:v1.18.2` everywhere. Both services in each compose file (`openfga-migrate` and `openfga`) must move together — a mismatched pair runs migrations from one version against a server of another.
- **The v1.18.0 MySQL warning does not apply here.** It concerns MySQL schema migration `008_collate_identifiers.sql` (CVE-2026-55170, CVE-2026-55689). Every deployment in scope sets `OPENFGA_DATASTORE_ENGINE: postgres`, and the Postgres migration set is identical (001–006) at v1.15.1 and v1.18.2. If any deployment is later moved to MySQL, this plan's reasoning does not carry over.
- Production is `auth/docker-compose.prod.yml` on the VPS at `/opt/cdcf-auth`. `sync-to-vps.yml` fast-forwards that checkout on merge to `main` but never runs `docker compose up` — bringing the stack up is an operator step.
- LitCal PRs target `development`.
- Do not change any other pinned image (notably `ghcr.io/zitadel/zitadel:v4.15.0`) in these PRs.

## File Structure

| File | Change |
| --- | --- |
| `cdcf-infra/auth/docker-compose.prod.yml:155,164` | `v1.15.1` → `v1.18.2` (both services) |
| `cdcf-infra/docs/SYSADMIN.md` | Component inventory rows for OpenFGA + migrate |
| `martyrology-api/docker-compose.yml:117,130` | `v1.15.1` → `v1.18.2` |
| `martyrology-api/docker-compose.yml:141-145` | Playground comment, if Task 1 finds it obsolete |
| `LiturgicalCalendarAPI/docker-compose.yml:235,248` | `v1.8.12` → `v1.18.2` |
| `LiturgicalCalendarFrontend/docker-compose.yml:203,216` | `v1.8.12` → `v1.18.2` |

---

### Task 1: Verify the 1.18.2 image assumptions

**Files:** none — this task produces findings the later tasks depend on.

**Interfaces:**
- Produces three answers: (a) does `/usr/local/bin/grpc_health_probe` exist in the image, (b) does OpenFGA still refuse to start with the Playground enabled alongside preshared auth, (c) are `OPENFGA_AUTHN_METHOD` / `OPENFGA_AUTHN_PRESHARED_KEYS` still honoured. Tasks 2-5 assume (a) and (c) hold; Task 3 acts on (b).

- [x] **Step 1: Pull the image**

```bash
docker pull openfga/openfga:v1.18.2
```

- [x] **Step 2: (a) Healthcheck binary**

Both `cdcf-infra/auth/docker-compose.prod.yml` and `martyrology-api/docker-compose.yml` healthcheck with `/usr/local/bin/grpc_health_probe`. Confirm it is still there:

```bash
docker run --rm --entrypoint ls openfga/openfga:v1.18.2 -l /usr/local/bin/grpc_health_probe
```

Expected: the file listed. **If it is missing**, stop and revise every affected healthcheck to `["CMD", "/usr/local/bin/openfga", "health"]` or an HTTP probe against `/healthz` before continuing — and record the change in this plan.

- [x] **Step 3: (c) Preshared auth still honoured**

```bash
docker run --rm -d --name fga-1182 -p 127.0.0.1:18081:8080 \
  -e OPENFGA_AUTHN_METHOD=preshared \
  -e OPENFGA_AUTHN_PRESHARED_KEYS=test-key \
  openfga/openfga:v1.18.2 run
sleep 5
echo -n "no token: "; curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18081/stores
echo -n "with token: "; curl -s -o /dev/null -w '%{http_code}\n' -H 'Authorization: Bearer test-key' http://127.0.0.1:18081/stores
```

Expected: `401` without the token, `200` with it.

- [x] **Step 4: (b) Playground + preshared behaviour**

`martyrology-api/docker-compose.yml:141-145` documents that v1.15.1 panics at startup when the Playground is enabled alongside preshared auth. Re-test at 1.18.2:

```bash
docker rm -f fga-1182 fga-pg 2>/dev/null
docker run -d --name fga-pg -p 127.0.0.1:18082:8080 \
  -e OPENFGA_AUTHN_METHOD=preshared \
  -e OPENFGA_AUTHN_PRESHARED_KEYS=test-key \
  -e OPENFGA_PLAYGROUND_ENABLED=true \
  openfga/openfga:v1.18.2 run
sleep 5
docker logs fga-pg 2>&1 | head -20
docker rm -f fga-pg 2>/dev/null
```

Detached, without `--rm`, so this terminates either way and the crash output
survives long enough to inspect: if the server panics on startup (the
expected 1.15.1 behaviour) the container sits exited, and `docker logs` still
reads its output; if it starts successfully instead (behaviour changed), the
`sleep 5` bounds how long it runs before `docker logs` reads it. The trailing
`docker rm -f` removes the container either way.

Expected (if unchanged): a startup error mentioning that the playground only supports authn method 'none'. Record which it is — Task 3 updates martyrology's comment only if the behaviour changed.

- [x] **Step 5: Confirm the migrate command no-ops against an up-to-date schema**

```bash
set -euo pipefail
docker network create fga-upgrade-test 2>/dev/null || true
docker run --rm -d --name fga-pg-db --network fga-upgrade-test \
  -e POSTGRES_PASSWORD=pw -e POSTGRES_USER=openfga -e POSTGRES_DB=openfga postgres:16
for i in $(seq 1 30); do
  docker exec fga-pg-db pg_isready -U openfga -d openfga -h localhost && break
  if [ "$i" -eq 30 ]; then
    echo "fga-pg-db never became ready" >&2
    exit 1
  fi
  sleep 1
done
docker run --rm --network fga-upgrade-test openfga/openfga:v1.15.1 migrate \
  --datastore-engine postgres --datastore-uri 'postgres://openfga:pw@fga-pg-db:5432/openfga?sslmode=disable'
docker run --rm --network fga-upgrade-test openfga/openfga:v1.18.2 migrate \
  --datastore-engine postgres --datastore-uri 'postgres://openfga:pw@fga-pg-db:5432/openfga?sslmode=disable'
```

`set -euo pipefail` makes the block abort on the first failing command, so a
failed v1.15.1 migrate can no longer be masked by a v1.18.2 migrate that
"succeeds" by migrating an untouched database from scratch. The loop polls
`pg_isready` against the `openfga` role/database (bounded to 30 attempts)
instead of a fixed `sleep`, so the migrate commands only run once Postgres is
actually accepting connections.

Expected: the second run reports the database is already at the target version and applies nothing. This is the empirical confirmation of the "migration-free" claim that the rest of the plan rests on.

- [x] **Step 6: Clean up**

```bash
docker rm -f fga-pg-db fga-1182 fga-pg 2>/dev/null; docker network rm fga-upgrade-test 2>/dev/null; true
```

- [x] **Step 7: Record findings**

Append a short findings block to this plan file under Task 1 (binary present yes/no, playground behaviour, migrate no-op confirmed) and commit:

```bash
git add docs/superpowers/plans/2026-08-04-openfga-1182-upgrade.md
git commit -m "Record OpenFGA 1.18.2 image verification findings"
```

**Findings (v1.18.2, verified against isolated local-only containers, no production access):**
- (a) Healthcheck binary: **present** — `/usr/local/bin/grpc_health_probe` exists in the image (confirmed via `docker cp`, 14 MB, mode 0555, and by invoking it directly, which returned its usual `-addr not specified` usage error rather than "not found"). No compose healthchecks need rewriting.
- (b) Playground + preshared auth: **unchanged** — still panics at startup with `panic: the playground only supports authn method 'none'`, identical to the documented v1.15.1 behaviour. `martyrology-api/docker-compose.yml:141-145`'s comment stays accurate; Task 3 need not change it.
- (c) Preshared auth: **still honoured** — `/stores` returned `401` with no token and `200` with `Authorization: Bearer test-key`.
- Migrate no-op: **confirmed empirically** — a fresh Postgres 16 database was migrated with `openfga/openfga:v1.15.1 migrate` (applied goose versions 0–6), then `openfga/openfga:v1.18.2 migrate` was run against that same database; the `goose_db_version` table shows no rows added by the second run (all 7 rows timestamped from the v1.15.1 run only). The "no Postgres migration between 1.15.1 and 1.18.2" claim holds.
- MySQL warning: not applicable — no MySQL datastore was touched or exercised in this task, consistent with every deployment in scope using Postgres.

Full command transcripts: `.superpowers/sdd/2026-08-04-openfga-1182-upgrade/task-1-report.md`.

---

### Task 2: Bump `martyrology-api` local stack

**Files:**
- Modify: `/home/johnrdorazio/development/CatholicOS_org/martyrology-api/docker-compose.yml:117,130` (and `:141-145` only if Task 1 Step 4 found the playground behaviour changed)

**Interfaces:**
- Consumes: Task 1's findings (a) and (c).

- [ ] **Step 1: Branch**

```bash
cd /home/johnrdorazio/development/CatholicOS_org/martyrology-api
git checkout main && git pull --ff-only
git checkout -b chore/openfga-1.18.2
```

- [ ] **Step 2: Bump both pins**

```bash
sed -i 's|openfga/openfga:v1\.15\.1|openfga/openfga:v1.18.2|g' docker-compose.yml
grep -n "openfga/openfga:" docker-compose.yml
```

Expected: two lines, both `v1.18.2`.

- [ ] **Step 3: Rebuild the stack from scratch**

```bash
docker compose down -v
docker compose up -d
docker compose ps
```

Expected: `openfga-migrate` exits 0, `openfga` reaches healthy (the healthcheck is the real test of Task 1's finding (a)).

- [ ] **Step 4: Verify the seeded store still works**

```bash
docker compose up authz-seed
docker compose logs authz-seed | tail -20
```

Expected: store created, model uploaded, 11 structural tuples written.

- [ ] **Step 5: Run the API's own test suite**

```bash
if [ -n "$(docker compose ps -q api)" ]; then
  docker compose exec api pytest -q
else
  echo "api container not running; falling back to host pytest" >&2
  pytest -q
fi
```

Expected: pass. The fallback triggers only when the `api` container isn't
available — a real test failure inside the container must propagate, not be
masked by a host-side rerun. If the suite needs the stack's env, follow this
repo's README for the canonical invocation rather than inventing one.

- [ ] **Step 6: Commit and PR**

```bash
git add docker-compose.yml
git commit -m "Bump OpenFGA to v1.18.2

Migration-free on Postgres: the Postgres migration set is identical (001-006)
at v1.15.1 and v1.18.2, and the v1.18.0 lock warning applies only to MySQL
(schema migration 008, CVE-2026-55170 / CVE-2026-55689)."
git push -u origin chore/openfga-1.18.2
gh pr create --base main --title "Bump OpenFGA to v1.18.2" --body "Local dev stack only. Migration-free on Postgres; the v1.18.0 MySQL warning does not apply. Verified: migrate no-ops against an up-to-date schema, healthcheck binary still present, preshared auth unchanged."
```

---

### Task 3: Bump the LitCal local stacks

**Files:**
- Modify: `LiturgicalCalendarAPI/docker-compose.yml:235,248`
- Modify: `LiturgicalCalendarFrontend/docker-compose.yml:203,216`

**Interfaces:**
- Consumes: Task 1's findings. Independent of the ownership plan — but if that plan's Task 6 has landed, the API stack also has an `authz-seed` service, which this task exercises.

- [ ] **Step 1: API repo — branch from `development` and bump**

```bash
cd /home/johnrdorazio/development/LiturgicalCalendar/LiturgicalCalendarAPI
git checkout development && git pull --ff-only
git checkout -b chore/openfga-1.18.2
sed -i 's|openfga/openfga:v1\.8\.12|openfga/openfga:v1.18.2|g' docker-compose.yml
grep -n "openfga/openfga:" docker-compose.yml
```

Expected: two lines, both `v1.18.2`.

- [ ] **Step 2: Rebuild and confirm the migration applies cleanly**

This stack is coming from v1.8.12, so it genuinely applies `006_add_collate_index` — on a throwaway dev database:

```bash
docker compose down -v
docker compose up -d db openfga-migrate
# -a: a fast one-shot may already have exited before this line runs, and
# `docker compose ps -q` without -a only lists running containers — it would
# return empty here and `docker wait ""` would fail.
MIGRATE_EXIT=$(docker wait "$(docker compose ps -a -q openfga-migrate)")
docker compose logs openfga-migrate | tail -20
[ "$MIGRATE_EXIT" = "0" ] || { echo "openfga-migrate exited $MIGRATE_EXIT" >&2; exit 1; }
```

Expected: migration runs, exits 0 — asserted above, not just eyeballed in the logs. Do not proceed to Step 3 unless the assertion passed.

- [ ] **Step 3: Bring the rest up, now that migration is confirmed clean**

```bash
docker compose up -d
docker compose ps
```

Expected: `openfga` healthy. Note this compose defaults `OPENFGA_AUTHN_METHOD` to `none`, so no token is needed locally:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8083/healthz
```

Expected: `200`.

- [ ] **Step 4: Commit and PR against `development`**

```bash
git add docker-compose.yml
git commit -m "Bump OpenFGA to v1.18.2

Local dev stack. From v1.8.12 this applies Postgres migration 006 to the dev
database; the v1.18.0 warning is MySQL-only and does not apply here."
git push -u origin chore/openfga-1.18.2
gh pr create --base development --title "Bump OpenFGA to v1.18.2" --body "Local dev stack only. Applies Postgres migration 006 on first up; the v1.18.0 lock warning is MySQL-specific and does not apply to this Postgres stack."
```

- [ ] **Step 5: Repeat for the Frontend repo**

```bash
cd /home/johnrdorazio/development/LiturgicalCalendar/LiturgicalCalendarFrontend
git checkout development && git pull --ff-only
git checkout -b chore/openfga-1.18.2
sed -i 's|openfga/openfga:v1\.8\.12|openfga/openfga:v1.18.2|g' docker-compose.yml
grep -n "openfga/openfga:" docker-compose.yml
docker compose down -v && docker compose up -d && docker compose ps
git add docker-compose.yml
git commit -m "Bump OpenFGA to v1.18.2

Local dev stack, matching the API repo's pin."
git push -u origin chore/openfga-1.18.2
gh pr create --base development --title "Bump OpenFGA to v1.18.2" --body "Local dev stack only; keeps this repo's pin in step with LiturgicalCalendarAPI."
```

---

### Task 4: Bump the production compose in cdcf-infra

**Files:**
- Modify: `auth/docker-compose.prod.yml:155,164`
- Modify: `docs/SYSADMIN.md` component inventory (OpenFGA and OpenFGA-migrate rows)

**Interfaces:**
- Consumes: Task 1's findings; Tasks 2-3 having run clean on local stacks.
- Produces: the merged `main` that `sync-to-vps.yml` fast-forwards onto the VPS. Task 5 restarts the stack.

- [ ] **Step 1: Branch and bump**

```bash
cd /home/johnrdorazio/development/CatholicOS_org/cdcf-infra
git checkout main && git pull --ff-only
git checkout -b chore/openfga-1.18.2
sed -i 's|openfga/openfga:v1\.15\.1|openfga/openfga:v1.18.2|g' auth/docker-compose.prod.yml
grep -n "openfga/openfga:" auth/docker-compose.prod.yml
```

Expected: two lines, both `v1.18.2`. Confirm nothing else moved:

```bash
git diff --stat
grep -n "zitadel:v" auth/docker-compose.prod.yml
```

Expected: one file changed, two insertions/deletions; Zitadel still `v4.15.0`.

- [ ] **Step 2: Update the component inventory**

In `docs/SYSADMIN.md`, change both OpenFGA rows from `openfga/openfga:v1.15.1` to `openfga/openfga:v1.18.2`.

- [ ] **Step 3: Commit, PR, merge**

```bash
git add auth/docker-compose.prod.yml docs/SYSADMIN.md
git commit -m "Bump production OpenFGA to v1.18.2

Migration-free on Postgres: assets 001-006 are identical at v1.15.1 and
v1.18.2, confirmed empirically by running v1.18.2 migrate against a
v1.15.1-migrated database (no-op). The v1.18.0 operational warning covers
MySQL schema migration 008 only. Rollback is a pin revert with no schema to
undo."
git push -u origin chore/openfga-1.18.2
gh pr create --base main --title "Bump production OpenFGA to v1.18.2" --body "Image pin only; Zitadel untouched. Migration-free on Postgres (assets 001-006 identical at both tags, verified by a no-op migrate run). The v1.18.0 MySQL lock warning does not apply. Merging only syncs the file to the VPS — an operator still has to bring the stack up (Task 5 of the plan)."
gh pr merge --merge --delete-branch
```

- [ ] **Step 4: Confirm the VPS received the file**

```bash
ssh ubuntu@catholicdigitalcommons.org 'git -C /opt/cdcf-auth log --oneline -1; grep -n "openfga/openfga:" /opt/cdcf-auth/auth/docker-compose.prod.yml'
```

Expected: the merge commit, and both lines showing `v1.18.2`. The running containers are still 1.15.1 at this point — that is expected.

---

### Task 5: Operator — restart production and verify

> **SUPERSEDED — not required. Production was already running `v1.18.2` before this plan was written.**
>
> The operator upgraded it on **2026-08-04 10:53Z** by pulling the image in the Plesk Docker interface and recreating the container. Verified 2026-08-05 from the container rather than from a file: `Config.Image=openfga/openfga:v1.18.2`, and the server's own startup log reports `build.version: v1.18.2` (`build.commit: 560d5d3d`).
>
> This plan was written on the premise that production ran `v1.15.1`, which came from `auth/docker-compose.prod.yml` — a file that had drifted from reality, because Plesk's Docker extension does not write back to git. PR #28 was therefore a **correction of the compose file**, not an upgrade of the service, despite how it was titled and described.
>
> Task 1's verification keeps its value regardless: it established empirically that `v1.15.1 → v1.18.2` applies no Postgres migration, which is what makes the already-performed upgrade safe rather than lucky. The steps below are retained as the runbook for the *next* version change, where the premise will need re-checking first.
>
> **Lesson recorded in `docs/SYSADMIN.md` §10.3:** verify the running container, not the compose pin, before planning work around a version.

**Files:** none (operator action on the VPS).

- [ ] **Step 1: Record the pre-upgrade state**

```bash
ssh ubuntu@catholicdigitalcommons.org 'bash -s' <<'EOS'
set -euo pipefail
cd /opt/cdcf-auth/auth
KEY=$(grep -m1 '^OPENFGA_PRESHARED_KEY=' .env.production | cut -d= -f2- | tr -d '"')
docker compose -f docker-compose.prod.yml ps --format '{{.Name}}\t{{.Image}}\t{{.Status}}'
for s in 01KRSCF4GVX0X4ZNXXJQEC4XXJ 01KZ1M9NJR1JHTMTV091X5DMYZ; do
  echo -n "$s latest model: "
  curl -sS "http://127.0.0.1:8081/stores/$s/authorization-models?page_size=1" -H "Authorization: Bearer $KEY" | jq -r '.authorization_models[0].id'
done
EOS
```

Keep this output — it is the comparison baseline for Step 4 and the rollback trigger.

- [ ] **Step 2: Pull and recreate only the OpenFGA services**

```bash
ssh ubuntu@catholicdigitalcommons.org
cd /opt/cdcf-auth/auth
docker compose -f docker-compose.prod.yml pull openfga openfga-migrate
docker compose -f docker-compose.prod.yml up -d openfga-migrate
# -a: a fast one-shot may already have exited before this line runs, and
# `docker compose ps -q` without -a only lists running containers — it would
# return empty here and `docker wait ""` would fail.
MIGRATE_EXIT=$(docker wait "$(docker compose -f docker-compose.prod.yml ps -a -q openfga-migrate)")
docker compose -f docker-compose.prod.yml logs --tail=30 openfga-migrate | tee /tmp/openfga-migrate.log
[ "$MIGRATE_EXIT" = "0" ] || { echo "openfga-migrate exited $MIGRATE_EXIT" >&2; exit 1; }
# Exit 0 only proves `migrate` ran without error, not that it left the store
# untouched — for an upgrade against a live store that's the weaker claim.
# `migrate` logs the pre-migration schema version as `"current version": N`
# before it applies anything (verified against the v1.15.1 image: a fresh run
# logs `"current version": 0`, a repeat run against an already-migrated
# database logs `"current version": 6` — both then print the same
# "running all migrations" / "migration done" lines, so those two lines are
# NOT a usable no-op signal on their own). The Postgres migration set is fixed
# at 001-006 (see Global Constraints), so a pre-migration version of 6 proves
# there was nothing left to apply.
grep -q '"current version": 6' /tmp/openfga-migrate.log || { echo "openfga-migrate started from a schema version other than 6 — it may have applied changes; investigate before continuing" >&2; exit 1; }
```

Expected: migrate exits 0 having applied nothing — asserted above before continuing.

```bash
docker compose -f docker-compose.prod.yml up -d openfga
docker compose -f docker-compose.prod.yml ps
```

Expected: `cdcf-auth-openfga-1` running `openfga/openfga:v1.18.2` and healthy. Only run this once the assertion above passed. Zitadel containers are untouched.

- [ ] **Step 3: Health probes**

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://authz.catholicdigitalcommons.org/healthz
curl -s -o /dev/null -w '%{http_code}\n' https://auth.catholicdigitalcommons.org/debug/healthz
```

Expected: `200` for the OpenFGA endpoint; the Zitadel probe is there to confirm nothing else was disturbed.

- [ ] **Step 4: Data probes — models and a real Check**

```bash
cd /opt/cdcf-auth/auth
KEY=$(grep -m1 '^OPENFGA_PRESHARED_KEY=' .env.production | cut -d= -f2- | tr -d '"')
for s in 01KRSCF4GVX0X4ZNXXJQEC4XXJ 01KZ1M9NJR1JHTMTV091X5DMYZ; do
  echo -n "$s latest model: "
  curl -sS "http://127.0.0.1:8081/stores/$s/authorization-models?page_size=1" -H "Authorization: Bearer $KEY" | jq -r '.authorization_models[0].id'
done
curl -sS -X POST "http://127.0.0.1:8081/stores/01KZ1M9NJR1JHTMTV091X5DMYZ/check" \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"authorization_model_id":"01KZ3VZC7RAAX7TEMMVAYEBPW8","tuple_key":{"user":"user:384646678734438403","relation":"can_read_texts","object":"edition:martyrologium_romanum_2004"}}' | jq .
curl -sS -X POST "http://127.0.0.1:8081/stores/01KRSCF4GVX0X4ZNXXJQEC4XXJ/check" \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"authorization_model_id":"<LiturgicalCalendar model ID from the loop above>","tuple_key":{"user":"<known admin/editor user:ID>","relation":"viewer","object":"general_roman_calendar:general_roman_calendar"}}' | jq .
```

Expected: both model IDs identical to Step 1, and both Checks return
`{"allowed": true}` — the Martyrology probe exercises the superuser
inheritance path, the LiturgicalCalendar probe a known `viewer` grant on
`general_roman_calendar`, so together they exercise model evaluation end to
end in both stores rather than just liveness. Fill in the LiturgicalCalendar
`user` from a known grant (e.g. via the Zitadel console → `LiturgicalCalendar`
Org → Users, cross-referenced with `auth/handoffs/liturgicalcalendar.md`'s
role list) before running this probe for the first time, then reuse the same
tuple on future upgrades.

- [ ] **Step 5: Rollback procedure (only if a probe fails)**

```bash
ssh ubuntu@catholicdigitalcommons.org
cd /opt/cdcf-auth/auth
sed -i 's|openfga/openfga:v1\.18\.2|openfga/openfga:v1.15.1|g' docker-compose.prod.yml
docker compose -f docker-compose.prod.yml up -d openfga
```

There is no schema change to undo, so this is complete on its own. Then revert the pin in the repo (`git revert` the Task 4 merge) so the VPS checkout and `main` do not diverge — the local edit above will otherwise be clobbered by the next CI pull.

- [ ] **Step 6: Record the outcome**

Add a line to `docs/SYSADMIN.md` §5.4 noting the production OpenFGA version and the date it was verified, then commit and push.

---

# Phase 2 — Model contract enforcement (Tasks 6-8)

Independent of the upgrade above: these tasks share no state with Tasks 1-5 and ship as their own PRs. Run them in either order relative to the version bumps.

**Why this exists.** Centralizing model ownership (PR #26) moved the LiturgicalCalendar model into cdcf-infra, which turned `LiturgicalCalendarAPI`'s `phpunit_tests/Services/OpenFgaModelTest.php` into a consumer-driven contract test: it asserts the types and relations LitCal's authorization code depends on, against a model another repo now provisions. That contract is currently enforced **only on the consumer side, after the fact** — a model change in cdcf-infra can merge, deploy, and only surface as a LitCal failure later. And it is enforced by an integration test that skips when no store is configured, so CI may report green while verifying nothing.

These tasks add the provider-side half: cdcf-infra validates every model in `auth/models/` against its consumers' declared expectations before a model change can merge.

**Design decisions, and why.**

- **The consumer owns its expectations file.** It lives in the consumer's repo next to the code whose assumptions it encodes, and cdcf-infra fetches it. The alternative — cdcf-infra hosting a copy per consumer — recreates exactly the two-copies-no-authority problem that caused the drift PR #26 fixed.
- **One file, both sides.** The consumer's test asserts against the same file cdcf-infra validates against, so the contract has a single source of truth rather than parallel hardcoded lists that drift.
- **A fetch failure fails the check.** An unreachable expectations file means the contract is unverified, which is not the same as satisfied.

## Global Constraints (Phase 2)

- Expectations files are consumer-authored and consumer-hosted; cdcf-infra reads them and never writes them.
- The validator must run with `jq` and `curl` only — cdcf-infra has no test framework and this is not the moment to introduce one.
- A model that violates any consumer's expectations fails the check. No warn-only mode.

## File Structure (Phase 2)

| File | Responsibility | Change |
| --- | --- | --- |
| `auth/models/consumers.json` | Registry: which consumers depend on which store, and where their expectations live | Created |
| `auth/validate-expectations.sh` | Validates each model against every consumer's expectations | Created |
| `auth/models/testdata/` | Fixtures proving the validator catches violations | Created |
| `.github/workflows/validate-models.yml` | Runs the validator on PRs touching models | Created |
| **LitCal repo** `authz/openfga-expectations.json` | LitCal's declared expectations | Created |
| **LitCal repo** `phpunit_tests/Services/OpenFgaModelTest.php` | Consumer-side contract test | Reads the expectations file instead of hardcoding invariants |

---

### Task 6: Expectations format, registry, and validator

**Files:**
- Create: `auth/models/consumers.json`
- Create: `auth/validate-expectations.sh`
- Create: `auth/models/testdata/expectations-valid.json`, `auth/models/testdata/expectations-violating.json`

**Interfaces:**
- Produces: `./auth/validate-expectations.sh [--expectations-file PATH --store NAME]` — with no arguments, reads `auth/models/consumers.json`, fetches each consumer's expectations, validates `auth/models/<store>.json`, exits 0 when all pass and non-zero on the first violation with a per-rule message. The flags let a caller validate a local file without network, which Task 6's own tests use.

The expectations schema, which Task 8's consumer file must match:

```json
{
  "consumer": "LiturgicalCalendarAPI",
  "store": "LiturgicalCalendar",
  "required_types": ["wider_region", "national_calendar"],
  "required_relations": { "wider_region": ["admin", "editor", "viewer", "member_nation"] },
  "forbidden_types": ["test_definition"],
  "forbidden_relations": { "*": ["deleter"] },
  "relation_includes": { "*": { "editor": ["admin"], "viewer": ["admin", "editor"] } }
}
```

`"*"` as a type key means "every type in the model". `relation_includes` asserts that the named relation's rewrite contains a `computedUserset` on each listed relation — that is how LitCal's `editor`/`viewer`-are-unions-of-`admin` invariant is expressed declaratively.

- [ ] **Step 1: Write the violating fixture first**

Create `auth/models/testdata/expectations-violating.json` declaring expectations the **current** `auth/models/LiturgicalCalendar.json` cannot satisfy — require a type it lacks, forbid a relation it has (`viewer`), and assert a `relation_includes` it does not honour. This is the failing case the validator must catch; write it before the validator exists.

- [ ] **Step 2: Write `expectations-valid.json`**

Same shape, but asserting what the LitCal model genuinely provides today: the eight deployed types, `admin`/`editor`/`viewer` on each, `member_nation` on `wider_region`, `test_definition` forbidden, `deleter` forbidden everywhere, and the union rewrites.

- [ ] **Step 3: Implement the validator**

`auth/validate-expectations.sh`, following `setup-openfga.sh`'s conventions — `set -euo pipefail`, `log`/`ok`/`warn`/`err` to stderr, documented exit codes. Structure:

```bash
validate_one() {           # $1 = expectations JSON, $2 = model file
    local exp="$1" model="$2" failures=0
    # required_types / forbidden_types
    # required_relations / forbidden_relations, honouring the "*" wildcard
    # relation_includes: relation rewrite must contain computedUserset on each named relation
    # every failure printed with consumer, rule and specifics; return 1 if any
}
```

Report **every** violation, not just the first — an operator fixing a model wants the full list, and a validator that stops at the first failure turns one fix cycle into five.

- [ ] **Step 4: Prove it fails on the violating fixture**

```bash
./auth/validate-expectations.sh --expectations-file auth/models/testdata/expectations-violating.json --store LiturgicalCalendar; echo "exit=$?"
```

Expected: non-zero, with a separate line per violated rule naming the type/relation.

- [ ] **Step 5: Prove it passes on the valid fixture**

```bash
./auth/validate-expectations.sh --expectations-file auth/models/testdata/expectations-valid.json --store LiturgicalCalendar; echo "exit=$?"
```

Expected: `exit=0`.

- [x] **Step 6: Create the registry**

`auth/models/consumers.json`:

```json
[
  {
    "consumer": "LiturgicalCalendarAPI",
    "store": "LiturgicalCalendar",
    "expectations_url": "https://raw.githubusercontent.com/Liturgical-Calendar/LiturgicalCalendarAPI/development/authz/openfga-expectations.json"
  }
]
```

**Shipped empty (`[]`) instead, on purpose.** This step and Task 8 have an
ordering dependency the plan stated backwards: the entry above cannot land
before the file it points at exists on `development`, or every
model-touching PR fails on a fetch error (exit 2) and `main` goes red.
PR #29 therefore shipped the registry empty — a state the validator reports
as a genuine pass — and the entry landed only after
Liturgical-Calendar/LiturgicalCalendarAPI#757 merged at 2026-08-05T22:24Z.
See `auth/models/consumers.README.md`.

Martyrology is deliberately absent until `martyrology-api` declares expectations — an empty contract is honest; a fabricated one is not.

- [ ] **Step 7: Prove a fetch failure fails the run**

Point a copy of the registry at a URL that 404s and show the validator exits non-zero with a message distinguishing "could not fetch" from "violated" — an unverified contract must never read as a satisfied one.

- [ ] **Step 8: Commit**

```bash
git add auth/validate-expectations.sh auth/models/consumers.json auth/models/testdata/
git commit -m "Validate models against consumer-declared expectations

Centralizing model ownership made consumers depend on a model another repo
provisions, with the contract enforced only downstream. This validates each
model in auth/models/ against the expectations its consumers publish, so a
breaking change fails here rather than in a consumer's test run later."
```

---

### Task 7: Run the validator in CI

**Files:**
- Create: `.github/workflows/validate-models.yml`

**Interfaces:**
- Consumes: `auth/validate-expectations.sh` from Task 6.

- [ ] **Step 1: Write the workflow**

Triggers on `pull_request` touching `auth/models/**` and `auth/validate-expectations.sh`, plus `workflow_dispatch`. Ubuntu runner, `jq` and `curl` are preinstalled; run `./auth/validate-expectations.sh`. No secrets — every expectations URL is public. Note that this repo's only existing workflow is `sync-to-vps.yml`; match its conventions for naming and concurrency.

- [ ] **Step 2: Prove the workflow fails on a violating model**

On a scratch branch, edit `auth/models/LiturgicalCalendar.json` to drop `member_nation` from `wider_region`, push, and confirm the check fails with the expected message. **Delete the scratch branch afterwards** — it must never be merged.

- [ ] **Step 3: Prove it passes on `main`'s model**

`workflow_dispatch` on the unmodified branch; expect success.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/validate-models.yml
git commit -m "Fail model PRs that break a consumer's declared expectations"
```

---

### Task 8: Consumer side — LitCal declares its expectations

**Files (in `LiturgicalCalendarAPI`, branch off `development`):**
- Create: `authz/openfga-expectations.json`
- Modify: `phpunit_tests/Services/OpenFgaModelTest.php`

**Interfaces:**
- Consumes: the schema from Task 6. ~~The file this task creates is what `auth/models/consumers.json` already points at, so Task 6's registry entry goes live when this merges.~~ Inverted in practice — see Task 6 Step 6: the registry shipped empty, and registering this consumer was a follow-up PR in cdcf-infra *after* this one merged, not something that went live automatically.

- [x] **Step 1: Write the expectations file**

Encode exactly the invariants the test asserts today — no `deleter` anywhere, no `test_definition`, `editor`/`viewer` unions including `admin`, `member_nation` on `wider_region`, and the eight deployed types. Do not add aspirational expectations: this file is a contract another repo's CI enforces, so every line is a constraint someone else must keep satisfying.

- [x] **Step 2: Repoint the test at the file**

`OpenFgaModelTest` keeps fetching the model from the seeded store, but derives its assertions from `authz/openfga-expectations.json` rather than hardcoding them, so the consumer test and the provider check cannot disagree. Keep the `markTestSkipped` behaviour when no store is configured.

- [x] **Step 3: Prove both directions**

Run the suite against the seeded store and show the test executing and passing. Then temporarily add a bogus `required_types` entry to the expectations file, re-run, and show the test **failing** — a contract test that cannot fail is decoration. Restore the file.

- [x] **Step 4: Commit and open the PR against `development`**

Do not merge. The PR body should state that `cdcf-infra`'s CI reads this file, so changes to it change what that repo is allowed to ship.

---

# Phase 3 — Deployment drift detection (Tasks 9-10)

Independent of Phases 1 and 2; ships as its own PR.

**Why this exists.** On 2026-08-04 the operator upgraded production OpenFGA from `v1.15.1` to `v1.18.2` through the Plesk Docker interface. Plesk does not write back to git, so `auth/docker-compose.prod.yml` still said `v1.15.1` a day later — and this plan's Phases 1 and 2 were written from that stale pin, describing an upgrade of a service that had already been upgraded. Nobody noticed until a container was inspected directly.

Nothing in this repo compares **recorded intent** against **deployed reality**. That is the same gap the model lock files close for authorization models: record what should be deployed, then check that what is deployed matches. This phase generalises it to the rest of the stack.

The check is deliberately **read-only and run on the VPS**. It cannot live in CI, which has no route to the host and should not be given one.

## Global Constraints (Phase 3)

- The script reads. It never restarts a container, pulls an image, edits a file, or calls a write endpoint. A drift checker that repairs drift is a deployment tool wearing a disguise, and it removes the human judgement that is the point of noticing.
- `jq`, `curl`, `docker` and `bash` only — the same floor the other scripts in `auth/` assume.
- Drift exits non-zero. There is no warn-only mode, for the same reason the expectations validator has none.
- The image **tag** alone is not proof: a tag can be re-pointed while a container keeps running an older layer. Where a service reports its own version, that reading wins.

## File Structure (Phase 3)

| File | Responsibility | Change |
| --- | --- | --- |
| `auth/verify-deployment.sh` | Compares compose pins and lock files against what is actually running | Created |
| `docs/SYSADMIN.md` §7 | Day-2 operations — when to run it, and what a failure means | Modified |

---

### Task 9: The drift check

**Files:**
- Create: `auth/verify-deployment.sh`

**Interfaces:**
- Produces: `./auth/verify-deployment.sh [--quiet]`, run from `/opt/cdcf-auth/auth` on the VPS. Exits 0 when everything matches, non-zero on the first category of drift found, and prints a table of intended-versus-actual either way. Follows `setup-openfga.sh`'s conventions: `set -euo pipefail`, `log`/`ok`/`warn`/`err` to stderr, documented exit codes.

Two checks, because two things drift for different reasons:

**A. Image pins versus running containers.** For every service in `auth/docker-compose.prod.yml` that pins an image, compare the pin against that container's `.Config.Image`. Then, where the service reports its own build, compare that too — OpenFGA logs `build.version` at startup; Zitadel exposes its version similarly. Report the pin, the container's configured image, and the self-reported version side by side. A mismatch between pin and container is the Plesk case; a mismatch between container image and self-reported version means a re-pointed tag.

**B. Model locks versus live stores.** For each `auth/models/*.lock.json`, read the store's latest authorization model from the OpenFGA API and compare it with the recorded `model_id`. This is the check that was performed by hand in plan A's Task 7; this makes it repeatable.

- [ ] **Step 1: Write the failing case first**

Before the script exists, establish what drift looks like: take a copy of `docker-compose.prod.yml` with one pin altered, and note the exact comparison that must fail. You will use it in Step 4.

- [ ] **Step 2: Implement check A**

Parse the compose file with `docker compose config --format json` rather than grepping YAML — the file uses env interpolation, and a grep-based parser will disagree with what Docker actually resolves. Missing env vars are expected when running outside the deployed directory; handle that explicitly rather than letting it look like drift.

- [ ] **Step 3: Implement check B**

Reuse the lock-file schema from `auth/models/<Store>.lock.json` (`store_name`, `store_id`, `model_id`). A lock whose `store_id` does not exist in the target instance is drift worth reporting, not an error to swallow.

- [ ] **Step 4: Prove it detects drift**

Run against the altered compose copy from Step 1 and show a non-zero exit naming the service, the pin and the running image. Then alter a lock file's `model_id` in a scratch copy and show check B failing the same way. A drift checker that has never failed is indistinguishable from one that cannot.

- [ ] **Step 5: Prove it passes on the real deployment**

Run it read-only on the VPS from `/opt/cdcf-auth/auth`. Expected today: check A clean (compose and containers both `v1.18.2` since PR #28), check B clean (both locks matching, as verified on 2026-08-05). Quote the real output.

- [ ] **Step 6: Commit**

```bash
git add auth/verify-deployment.sh
git commit -m "Detect drift between recorded intent and what is deployed

The Plesk Docker extension can recreate a container with a different image
without touching git, which left docker-compose.prod.yml describing a
version that had not been running for a day. Nothing compared the two.
This reads both, plus the model lock files against their live stores, and
fails when they disagree."
```

---

### Task 10: Wire it into day-2 operations

**Files:**
- Modify: `docs/SYSADMIN.md` §7

**Interfaces:**
- Consumes: `auth/verify-deployment.sh` from Task 9.

- [ ] **Step 1: Document when to run it**

Add it to §7 as a day-2 check, with three specific triggers rather than a vague "periodically": before planning any version change (the failure this phase exists to prevent), after any Plesk-side container operation, and as part of the restoration drill in §7.2, where "the stack came back" should mean "came back as recorded".

- [ ] **Step 2: State what a failure means**

Drift is not automatically a problem — the Plesk upgrade was deliberate and correct. What is wrong is the *record*. Say so: on drift, decide which side is right, then either correct the compose file (as PR #28 did) or restore the intended image, and note that the script deliberately will not choose for you.

- [ ] **Step 3: Optional cron, with its trade-off stated**

If it runs on a schedule, its output belongs in the provisioning log alongside the backup job. Note the trade-off honestly: a cron that reports drift nobody reads is worse than no cron, because it converts a loud surprise into a quiet one. Recommend the manual triggers first, and cron only once someone owns the output.

- [ ] **Step 4: Commit**

```bash
git add docs/SYSADMIN.md
git commit -m "Document the deployment drift check in day-2 operations"
```
