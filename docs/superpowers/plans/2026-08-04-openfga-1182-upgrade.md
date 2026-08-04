# OpenFGA 1.15.1 → 1.18.2 Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every OpenFGA deployment — the production umbrella instance and three local dev stacks — to `openfga/openfga:v1.18.2`, having first verified the image assumptions the composes depend on.

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

- [ ] **Step 1: Pull the image**

```bash
docker pull openfga/openfga:v1.18.2
```

- [ ] **Step 2: (a) Healthcheck binary**

Both `cdcf-infra/auth/docker-compose.prod.yml` and `martyrology-api/docker-compose.yml` healthcheck with `/usr/local/bin/grpc_health_probe`. Confirm it is still there:

```bash
docker run --rm --entrypoint ls openfga/openfga:v1.18.2 -l /usr/local/bin/grpc_health_probe
```

Expected: the file listed. **If it is missing**, stop and revise every affected healthcheck to `["CMD", "/usr/local/bin/openfga", "health"]` or an HTTP probe against `/healthz` before continuing — and record the change in this plan.

- [ ] **Step 3: (c) Preshared auth still honoured**

```bash
docker run --rm -d --name fga-1182 -p 18081:8080 \
  -e OPENFGA_AUTHN_METHOD=preshared \
  -e OPENFGA_AUTHN_PRESHARED_KEYS=test-key \
  openfga/openfga:v1.18.2 run
sleep 5
echo -n "no token: "; curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18081/stores
echo -n "with token: "; curl -s -o /dev/null -w '%{http_code}\n' -H 'Authorization: Bearer test-key' http://127.0.0.1:18081/stores
```

Expected: `401` without the token, `200` with it.

- [ ] **Step 4: (b) Playground + preshared behaviour**

`martyrology-api/docker-compose.yml:141-145` documents that v1.15.1 panics at startup when the Playground is enabled alongside preshared auth. Re-test at 1.18.2:

```bash
docker rm -f fga-1182 2>/dev/null
docker run --rm --name fga-pg -p 18082:8080 \
  -e OPENFGA_AUTHN_METHOD=preshared \
  -e OPENFGA_AUTHN_PRESHARED_KEYS=test-key \
  -e OPENFGA_PLAYGROUND_ENABLED=true \
  openfga/openfga:v1.18.2 run 2>&1 | head -20
```

Expected (if unchanged): a startup error mentioning that the playground only supports authn method 'none'. Record which it is — Task 3 updates martyrology's comment only if the behaviour changed.

- [ ] **Step 5: Confirm the migrate command no-ops against an up-to-date schema**

```bash
docker network create fga-upgrade-test 2>/dev/null || true
docker run --rm -d --name fga-pg-db --network fga-upgrade-test \
  -e POSTGRES_PASSWORD=pw -e POSTGRES_USER=openfga -e POSTGRES_DB=openfga postgres:16
sleep 8
docker run --rm --network fga-upgrade-test openfga/openfga:v1.15.1 migrate \
  --datastore-engine postgres --datastore-uri 'postgres://openfga:pw@fga-pg-db:5432/openfga?sslmode=disable'
docker run --rm --network fga-upgrade-test openfga/openfga:v1.18.2 migrate \
  --datastore-engine postgres --datastore-uri 'postgres://openfga:pw@fga-pg-db:5432/openfga?sslmode=disable'
```

Expected: the second run reports the database is already at the target version and applies nothing. This is the empirical confirmation of the "migration-free" claim that the rest of the plan rests on.

- [ ] **Step 6: Clean up**

```bash
docker rm -f fga-pg-db fga-1182 fga-pg 2>/dev/null; docker network rm fga-upgrade-test 2>/dev/null; true
```

- [ ] **Step 7: Record findings**

Append a short findings block to this plan file under Task 1 (binary present yes/no, playground behaviour, migrate no-op confirmed) and commit:

```bash
git add docs/superpowers/plans/2026-08-04-openfga-1182-upgrade.md
git commit -m "Record OpenFGA 1.18.2 image verification findings"
```

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
docker compose exec api pytest -q 2>/dev/null || pytest -q
```

Expected: pass. If the suite needs the stack's env, follow this repo's README for the canonical invocation rather than inventing one.

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
docker compose logs openfga-migrate | tail -20
```

Expected: migration runs, exits 0.

- [ ] **Step 3: Bring the rest up**

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
docker compose -f docker-compose.prod.yml logs --tail=30 openfga-migrate
```

Expected: migrate exits 0 having applied nothing.

```bash
docker compose -f docker-compose.prod.yml up -d openfga
docker compose -f docker-compose.prod.yml ps
```

Expected: `cdcf-auth-openfga-1` running `openfga/openfga:v1.18.2` and healthy. Zitadel containers are untouched.

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
```

Expected: both model IDs identical to Step 1, and the Check returns `{"allowed": true}` — the superuser inheritance path, which exercises model evaluation end to end rather than just liveness.

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
