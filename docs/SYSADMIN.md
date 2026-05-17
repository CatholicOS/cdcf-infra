# Catholic OS Umbrella — System Admin Handbook

End-to-end runbook for the shared Zitadel + OpenFGA infrastructure that serves the Catholic OS umbrella properties (cdcf-website, LiturgicalCalendar, BibleGet, OntoKit). Audience: anyone who needs to stand up, operate, debug, or hand off the umbrella auth stack.

This handbook lives in [`CatholicOS/cdcf-infra`](https://github.com/CatholicOS/cdcf-infra) and is the authoritative process document. Source-of-truth for individual concerns (compose definitions, env templates, setup scripts) lives in this same repo — this document orchestrates across them and adds the "why" that the code itself doesn't.

---

## 1. Overview

### What it is

A **single Zitadel instance** + **single OpenFGA instance** that all four Catholic OS umbrella properties consume as their identity provider and (where needed) relationship-based authorization layer.

| Service | Public URL | Purpose |
|---|---|---|
| Zitadel (backend + admin console) | `https://auth.catholicdigitalcommons.org` | OIDC issuer, IAM admin UI |
| Zitadel v2 login UI | `https://auth.catholicdigitalcommons.org/ui/v2/login` | The hosted login form the admin console redirects to. Each property's own user-facing login UI is built into that property's frontend (calling Zitadel APIs directly) — this UI is for admin console access. |
| OpenFGA HTTP API | `https://authz.catholicdigitalcommons.org` | Relationship-based authz checks + tuple writes |

### Architecture diagram (logical)

```
                            Plesk nginx (TLS termination, ACME)
                                  │
                  ┌───────────────┼───────────────┐
                  │               │               │
                  ▼               ▼               ▼
       auth.cdcf.org/*    auth.cdcf.org/ui/v2/login/*   authz.cdcf.org/*
                  │               │                       │
                  └───────┐       └────────┐              │
                          ▼                ▼              ▼
                  zitadel-proxy (internal nginx)    cdcf-auth-openfga-1
                          │                              │
              ┌───────────┴────────────┐                 │
              ▼                        ▼                 │
       cdcf-auth-zitadel-1   cdcf-auth-zitadel-login-1   │
              │                                          │
              └──────────────────┬───────────────────────┘
                                 ▼
                  Host PostgreSQL 14+ (databases: zitadel, openfga)
```

(`cdcf` shortened for diagram width — the actual hostname is `catholicdigitalcommons.org`.)

### Why this architecture

Discussion: <https://github.com/CatholicOS/cdcf-website/discussions/98>. Summary: one Zitadel instance with one Zitadel **Org** per property gives shared infra (one runtime to upgrade, one DB to back up) with per-property admin/user isolation. Multi-instance was rejected — it's positioned for SaaS reseller scenarios, not for sibling properties of one umbrella.

### Component inventory

| Component | Image / version | Where defined |
|---|---|---|
| Zitadel backend | `ghcr.io/zitadel/zitadel:v4.15.0` | `auth/docker-compose.prod.yml` |
| Zitadel v2 login UI | `ghcr.io/zitadel/zitadel-login:v4.15.0` | same |
| Internal nginx proxy | `nginx:alpine` (config in `auth/nginx/zitadel.conf`) | same |
| OpenFGA | `openfga/openfga:v1.15.1` | same |
| OpenFGA migrate (one-shot) | `openfga/openfga:v1.15.1` | same |
| Authz model (LitCal) | `auth/models/LiturgicalCalendar.json` | lifted verbatim from `LiturgicalCalendarAPI/scripts/openfga-model.json` |
| Setup script — Zitadel | `auth/setup-zitadel.sh` | this repo |
| Setup script — OpenFGA | `auth/setup-openfga.sh` | this repo |
| Backup script | `auth/backup/pg-dump.sh` | this repo |

Database for both Zitadel and OpenFGA is the **host's native PostgreSQL** (no containerized DB) — see [`auth/README.md`](../auth/README.md#prerequisites) for the full rationale and required setup.

---

## 2. Roles & responsibilities

| Role | Responsibilities |
|---|---|
| 👤 **System Admin** | First-time provisioning, secrets generation, Plesk UI work (subdomains, certs, Docker Proxy Rules, mailbox creation), Postgres role/db creation + `pg_hba.conf` edits + restart, env file editing on the VPS, day-2 ops (backups verification, upgrades, restoration drills). |
| 📜 **CLI scripts** in this repo | All Zitadel/OpenFGA API-driven provisioning: Org creation, Project/app/role provisioning, OpenFGA store creation + model upload, bootstrap-admin rename, IAM admin discovery. All idempotent — safe to re-run. |
| 🤖 **CI** (GitHub Actions, etc.) | Currently NONE in the umbrella infra repo. See §8 for the discussion of what could be CI-driven and the tradeoffs. Per-consumer property repos (LitCal API/Frontend, etc.) have their own CI pipelines that consume the umbrella's published values via env vars. |
| 👥 **Per-property maintainers** | Wire their own repos to the umbrella values via env vars; deploy their property's own stack pointing at the shared infra. Receive a handoff doc (see [`auth/handoffs/`](../auth/handoffs/)) with the non-secret IDs they need. |

Throughout the handbook each step is tagged with the icon for who/what performs it.

---

## 3. Prerequisites checklist

Before starting Phase 1, the system admin must have:

- [ ] 👤 Root or sudo access to the Plesk VPS hosting `catholicdigitalcommons.org`
- [ ] 👤 DNS control for the umbrella domain (to add `auth.*` and `authz.*` subdomains)
- [ ] 👤 Plesk admin UI access (to add subdomains, request Let's Encrypt, configure Docker Proxy Rules)
- [ ] 👤 Plesk **Docker extension** installed and functional
- [ ] 👤 Host **PostgreSQL 14+** running and reachable from `localhost` (verify with `psql --version` + `sudo -u postgres psql -tAc 'SELECT version();'`)
- [ ] 👤 Plesk mail service enabled for `catholicdigitalcommons.org` (Mailboxes can be created via Plesk UI or `plesk bin mail`)
- [ ] 👤 OpenDKIM signing already configured for `catholicdigitalcommons.org` (selector `mail`, key in `/etc/opendkim/keys/...`) — typically set up at the same time as the mail service
- [ ] 👤 SPF + DMARC TXT records published for `catholicdigitalcommons.org`
- [ ] 👤 A password manager / secrets vault for the small set of bootstrap secrets (`ZITADEL_MASTERKEY`, DB role passwords, the SMTP relay password, the OpenFGA preshared key) — **these never live in this repo**

---

## 4. Phase 1 — First-time umbrella provisioning

End state of this phase: `auth.catholicdigitalcommons.org` and `authz.catholicdigitalcommons.org` are live, the four umbrella Orgs exist in Zitadel, the IAM admin can sign in to the console, and SMTP is wired so Zitadel can send notifications.

### 4.1 DNS + Plesk subdomains [👤 Manual]

1. Add A/AAAA records for `auth.catholicdigitalcommons.org` and `authz.catholicdigitalcommons.org` pointing at the VPS public IP.
2. In Plesk, create both subdomains under the `catholicdigitalcommons.org` subscription. Enable Let's Encrypt (or whatever issuer Plesk uses by default).
3. Verify cert serves: `curl -I https://auth.catholicdigitalcommons.org` returns valid TLS.

### 4.2 Host Postgres prep [👤 Manual]

Run as the Postgres superuser. Strong passwords here are stored later in `.env.production` — generate them now and stash in your password manager:

```sql
CREATE ROLE zitadel WITH LOGIN PASSWORD '<gen-32-alphanum>';
ALTER ROLE zitadel CREATEDB;          -- Zitadel's start-from-init probes CREATEDB
                                       -- even when the DB already exists
CREATE DATABASE zitadel OWNER zitadel;

CREATE ROLE openfga WITH LOGIN PASSWORD '<gen-32-alphanum>';
CREATE DATABASE openfga OWNER openfga;
```

Edit `/etc/postgresql/<version>/main/pg_hba.conf` and append:

```
# Allow docker-bridge connections (cdcf-auth stack)
host  zitadel   zitadel  172.16.0.0/12  scram-sha-256
host  openfga   openfga  172.16.0.0/12  scram-sha-256
# Zitadel start-from-init connects to the postgres system DB first to verify
# its target DB exists; the zitadel role has no privileges in postgres DB
# by default, so this is a connect-only allow.
host  postgres  zitadel  172.16.0.0/12  scram-sha-256
```

Edit `/etc/postgresql/<version>/main/postgresql.conf`:

```
listen_addresses = '*'   # was 'localhost' — docker bridge needs *
```

Apply:

```bash
sudo systemctl reload postgresql    # picks up pg_hba changes (zero impact)
sudo systemctl restart postgresql   # picks up listen_addresses (~2-5s outage
                                    # affecting every DB on this Postgres —
                                    # schedule for low-traffic window)
```

The restart affects every Postgres client on the host. Plan it.

### 4.3 Clone cdcf-infra to canonical path [👤 Manual]

```bash
sudo git clone https://github.com/CatholicOS/cdcf-infra.git /opt/cdcf-auth
sudo chown -R ubuntu:ubuntu /opt/cdcf-auth
sudo mkdir -p /opt/cdcf-auth/runtime/zitadel-data
sudo chmod 0777 /opt/cdcf-auth/runtime/zitadel-data    # scratch-image PAT constraint
```

### 4.4 Fill `.env.production` [👤 Manual]

```bash
cd /opt/cdcf-auth/auth
cp .env.production.example .env.production
chmod 0600 .env.production
# Edit and fill — generators in the file's comments
```

Required values to generate:

| Variable | How to generate | Notes |
|---|---|---|
| `ZITADEL_MASTERKEY` | `openssl rand -base64 64 \| tr -d '/+=' \| head -c 32` (exactly 32 chars) | **Generated once. NEVER rotated** — encrypts secrets in the DB; loss = unrecoverable. Back up out-of-band. |
| `ZITADEL_DB_PASSWORD` | Same generator | Must match the password you set on the `zitadel` Postgres role in §4.2 |
| `OPENFGA_DB_PASSWORD` | Same generator | Must match the `openfga` role's password |
| `ZITADEL_ADMIN_PASSWORD` | `echo "$(openssl rand -base64 64 \| tr -d '/+=' \| head -c 16)Aa1!"` | Must satisfy Zitadel's complexity policy (upper + lower + digit + symbol). The `Aa1!` suffix guarantees all four classes. Force-changed on first login. |
| `ZITADEL_ADMIN_EMAIL` | Your email | The IAM admin's email — also becomes their login name (instance uses `UserLoginMustBeDomain=false` + `UserEmailAsUsername=true`). |
| `OPENFGA_PRESHARED_KEY` | `openssl rand -base64 48` | Bearer token consumed by every property that calls OpenFGA. |

SMTP values are filled later in §6.

### 4.5 Bring up the stack [👤 Manual]

```bash
cd /opt/cdcf-auth/auth
sudo docker compose --env-file .env.production -f docker-compose.prod.yml up -d
```

Wait ~30s. Then verify:

```bash
curl -s http://127.0.0.1:8080/debug/ready    # → 200 (Zitadel via internal nginx)
curl -s http://127.0.0.1:8081/healthz        # → 200 (OpenFGA)
ls /opt/cdcf-auth/runtime/zitadel-data/      # → automation-user.pat + login-client.pat
```

Both PATs land on first boot via the `FIRSTINSTANCE_*PATPATH` env vars in compose — if they're not there, see Troubleshooting §9.1.

### 4.6 Plesk Docker Proxy Rules [👤 Manual]

In Plesk → Tools & Settings → Docker → Proxy Rules → "Add Proxy Rule", create two entries:

| Domain | Container | Container port |
|---|---|---|
| `auth.catholicdigitalcommons.org` | `cdcf-auth-zitadel-proxy-1` | 80 |
| `authz.catholicdigitalcommons.org` | `cdcf-auth-openfga-1` | 8080 |

The auth-side rule **must point at the internal nginx proxy** (`cdcf-auth-zitadel-proxy-1`), not directly at `cdcf-auth-zitadel-1`. The internal nginx is what routes `/ui/v2/login*` to the login UI container vs everything else to the backend — Plesk's Docker Proxy Rules are per-subdomain, not per-path.

Verify:

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://auth.catholicdigitalcommons.org/debug/ready    # → 200
curl -s -o /dev/null -w "%{http_code}\n" https://authz.catholicdigitalcommons.org/healthz        # → 200
```

### 4.7 Rename bootstrap admin + create the four Orgs [📜 CLI script]

```bash
cd /opt/cdcf-auth/auth
./setup-zitadel.sh --target production --all
```

`--all` runs three actions in order:

1. **`--rename-bootstrap-admin`** — Zitadel created the IAM admin with the legacy `<username>@<orgdomain>` suffix because the `DEFAULTINSTANCE_DOMAINPOLICY` env vars don't apply retroactively to users created inside the same `03_default_instance` migration. The script renames the admin to `${ZITADEL_ADMIN_EMAIL}` via `PUT /management/v1/users/{id}/username`. Idempotent.
2. **`--create-orgs`** — creates the four umbrella Orgs: CDCF, LiturgicalCalendar, BibleGet, OntoKit. Idempotent (skips ones that already exist).
3. **`--provision-litcal`** — creates the LiturgicalCalendarAPI Project + 4 roles + API OIDC app under the LiturgicalCalendar Org. Idempotent. Prints handoff values at end.

After successful run, you can sign in to the admin console at `https://auth.catholicdigitalcommons.org/ui/console/` using `ZITADEL_ADMIN_EMAIL` and `ZITADEL_ADMIN_PASSWORD`. First login forces a password change.

### 4.8 OpenFGA store + model for LiturgicalCalendar [📜 CLI script]

```bash
./setup-openfga.sh --target production --create-litcal-store
```

Creates the `LiturgicalCalendar` OpenFGA store (idempotent) and uploads `auth/models/LiturgicalCalendar.json` as the authorization model (idempotent — re-uploads only if the file diverges from what's already in the store). Prints the store ID + model ID.

### 4.9 Write the LitCal handoff doc [👤 Manual]

Capture the IDs printed by §4.7 and §4.8 into [`auth/handoffs/liturgicalcalendar.md`](../auth/handoffs/liturgicalcalendar.md). The template + secret-handling conventions are in [`auth/handoffs/README.md`](../auth/handoffs/README.md). PR + merge the populated handoff into `main`.

---

## 5. Phase 2 — Per-property wiring (LitCal as the canonical example)

End state: a consumer property is live, authenticating users via the shared Zitadel and authorizing via shared OpenFGA. Each subsequent property follows the same pattern.

LitCal has two consuming repos: `LiturgicalCalendarAPI` (backend) and `LiturgicalCalendarFrontend`.

### 5.1 Frontend OIDC app [📜 CLI script]

```bash
./setup-zitadel.sh --target production --provision-litcal-frontend
```

Creates a Web/PKCE OIDC app (`auth_method_type=NONE`) named `LiturgicalCalendarFrontend` under the existing LiturgicalCalendarAPI Project, with prod + staging callback URIs (`https://litcal{,-staging}.johnromanodorazio.com/auth/callback.php`) and post-logout URIs registered.

The Frontend app's `client_id` is DISTINCT from the API Backend's. See §9.7 for the cross-wire bug class.

### 5.2 Hand off the values [👤 Manual]

Open an issue in the consumer repo with the handoff doc inline. Example: <https://github.com/Liturgical-Calendar/LiturgicalCalendarAPI/issues/597>. Deliver the secrets (`OPENFGA_PRESHARED_KEY`, any service-user PATs) out-of-band — encrypted message, password-manager share, never in the issue.

### 5.3 Consumer-side env (their responsibility, document for them) [👥 Property maintainer]

LitCal example, split across the two repos:

**LiturgicalCalendarAPI** `.env.production` / `.env.staging`:
```
ZITADEL_ISSUER=https://auth.catholicdigitalcommons.org
ZITADEL_PROJECT_ID=<from handoff>
ZITADEL_CLIENT_ID=<API Backend client_id from handoff>
# ZITADEL_MACHINE_TOKEN=<optional, if making outbound Management API calls>

OPENFGA_API_URL=https://authz.catholicdigitalcommons.org
OPENFGA_STORE_ID=<from handoff>
OPENFGA_MODEL_ID=<from handoff>
OPENFGA_PRESHARED_KEY=<out-of-band>
```

**LiturgicalCalendarFrontend** `.env.production` / `.env.staging`:
```
ZITADEL_ISSUER=https://auth.catholicdigitalcommons.org
ZITADEL_CLIENT_ID=<Frontend client_id from handoff — DIFFERENT from the API one>
FRONTEND_URL=https://litcal{,-staging}.johnromanodorazio.com
```

The Frontend gets NO `OPENFGA_*` vars and NO `ZITADEL_MACHINE_TOKEN` — it doesn't talk to OpenFGA directly and only ever holds user tokens.

---

## 6. SMTP configuration

End state: Zitadel can send emails (init codes, password reset, email verification) via Plesk's local Postfix.

### 6.1 Create the relay mailbox [👤 Manual]

```bash
NEWPASS="$(openssl rand -base64 64 | tr -d '/+=' | head -c 28)"
sudo plesk bin mail --create noreply@catholicdigitalcommons.org \
    -mailbox true -passwd "$NEWPASS" \
    -manage-virusfilter true -manage-spamfilter true -mbox_quota 100M
# Save NEWPASS into your secrets vault — needed for the env file below.
```

### 6.2 Stash creds in `.env.production` [👤 Manual]

Append (or update) the SMTP block:

```bash
SMTP_HOST=catholicdigitalcommons.org    # NOT host.docker.internal — see §9.4
SMTP_PORT=587
SMTP_USER=noreply@catholicdigitalcommons.org
SMTP_PASSWORD=<from above>
SMTP_FROM_ADDRESS=noreply@catholicdigitalcommons.org
SMTP_FROM_NAME="Catholic Digital Commons Foundation"     # quote — has spaces
```

### 6.3 Register the SMTP provider with Zitadel [👤 Manual, via API]

There's no script for this yet (it's a one-time bootstrap). Use the automation PAT:

```bash
cd /opt/cdcf-auth/auth
set -a; source .env.production; set +a
PAT=$(cat /opt/cdcf-auth/runtime/zitadel-data/automation-user.pat)

ADD_RESULT=$(curl -sS -X POST http://127.0.0.1:8080/admin/v1/email/smtp \
    -H "Host: auth.catholicdigitalcommons.org" \
    -H "Authorization: Bearer $PAT" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg sender "$SMTP_FROM_ADDRESS" --arg name "$SMTP_FROM_NAME" \
                --arg host "$SMTP_HOST:$SMTP_PORT" --arg user "$SMTP_USER" --arg password "$SMTP_PASSWORD" \
        '{tls: true, senderAddress: $sender, senderName: $name, host: $host, user: $user, password: $password, description: "Plesk Postfix relay"}')")
SMTP_ID=$(echo "$ADD_RESULT" | jq -r '.id')

# Activate the provider
curl -sS -X POST "http://127.0.0.1:8080/admin/v1/smtp/$SMTP_ID/_activate" \
    -H "Host: auth.catholicdigitalcommons.org" \
    -H "Authorization: Bearer $PAT" \
    -H "Content-Type: application/json" -d '{}'

# Send a test
curl -sS -X POST "http://127.0.0.1:8080/admin/v1/smtp/$SMTP_ID/_test" \
    -H "Host: auth.catholicdigitalcommons.org" \
    -H "Authorization: Bearer $PAT" \
    -H "Content-Type: application/json" \
    -d "{\"receiverAddress\":\"$ZITADEL_ADMIN_EMAIL\"}"
# Check inbox; check mail log for the outbound DKIM-signed delivery.
```

This procedure is a candidate for promotion to a CLI script (e.g. `auth/setup-smtp.sh`) when we have a second umbrella SMTP scenario to validate against.

### Key constraints / gotchas

- Zitadel SMTP is **instance-wide**, not per-org. All umbrella properties get the same sender. Per-org **email body templates** are still customizable via the management API if/when property-branded copy is wanted.
- `SMTP_HOST` MUST be the public hostname (`catholicdigitalcommons.org`), not `host.docker.internal`. Plesk presents the proper Let's Encrypt cert via SNI on the public hostname; the loopback connection presents the self-signed Plesk cert and Zitadel's TLS verification fails. The container reaches the public IP via NAT loopback.
- DKIM signing happens transparently via OpenDKIM milter on outbound mail. The selector is `mail` (not the default `default` or Plesk's `plesk`).

---

## 7. Day-2 operations

### 7.1 Backups [👤 Manual setup, 🤖 cron-automated thereafter]

The script `auth/backup/pg-dump.sh` produces gzipped pg_dump output of both DBs and prunes anything older than 14 days. Wire into cron:

```cron
15 3 * * * /opt/cdcf-auth/auth/backup/pg-dump.sh >> /var/log/cdcf-auth-backup.log 2>&1
```

Dumps land in `/var/backups/cdcf-auth/`. **Off-server copy is the operator's responsibility** — use Plesk's backup tool, rclone, restic, or your existing off-server backup channel.

**Critical**: the `ZITADEL_MASTERKEY` is NOT in pg_dump. Without it, the dump is mathematically unrecoverable (secrets in events are encrypted). Back up the masterkey separately, out-of-band, in your password manager.

### 7.2 Restoration drill [👤 Manual, run periodically]

To verify backups actually work — recommended at least quarterly:

1. Provision a throwaway VPS or VM with the same Postgres version.
2. Restore the latest `zitadel-*.sql.gz` and `openfga-*.sql.gz` dumps.
3. Bring up the compose stack with the SAME `ZITADEL_MASTERKEY`.
4. Confirm `curl /debug/ready` returns 200 and a known user can log in to the admin console.
5. Tear down.

If step 4 fails, the masterkey backup is wrong/missing OR the dump is corrupted — diagnose before you actually need to restore.

### 7.3 Upgrades [👤 Manual]

1. Pin a new image tag in `auth/docker-compose.prod.yml` (e.g. `ghcr.io/zitadel/zitadel:v4.13.0`). Open a PR for the version bump.
2. Read the upstream changelog for the bump range — Zitadel occasionally has manual migration steps.
3. Take a backup IMMEDIATELY before the upgrade (`./backup/pg-dump.sh`).
4. Merge PR, pull on VPS, `docker compose pull && docker compose up -d`. Zitadel migrations run automatically on first start of the new version.
5. Verify `/debug/ready` returns 200 and re-test admin console login.
6. If it breaks, roll back: pin the previous tag, `docker compose up -d`, restore DB if migrations were destructive.

Login UI (`zitadel-login`) and OpenFGA upgrade the same way. Version-pin the login UI to match the backend; mixing versions is unsupported.

### 7.4 Monitoring [👤 Manual setup]

The umbrella infra doesn't currently have a monitoring story baked in. Recommendations:

- **Liveness**: external uptime check on `/debug/ready` for both subdomains (UptimeRobot, Statuscake, etc.)
- **Mail**: parse `/var/log/maillog` for rejection patterns or set up a periodic test send + receipt check
- **Disk**: alert on `/var/backups/cdcf-auth/` not changing day-over-day (no recent backup = silent failure)
- **Postgres**: standard Postgres monitoring covers both Zitadel + OpenFGA since they share the host instance

---

## 8. GitHub Actions vs manual: env-handling strategy

The question: could GitHub Actions hold the umbrella's env values and push them to `.env.staging` / `.env.production` on the VPS automatically?

**Short answer: partially, and only after first provisioning is done. The hybrid is more sensible than going all-in either direction.**

### What CAN flow from GH Actions to server `.env`

| Value | Source of truth | Auto-publish to GH secrets? |
|---|---|---|
| `ZITADEL_ISSUER` | Stable infrastructure constant | ✓ yes (it's not even secret — could be a `vars`, not a `secrets`) |
| `OPENFGA_API_URL` | Same | ✓ yes |
| `ZITADEL_PROJECT_ID` (per property) | Generated by `setup-zitadel.sh --provision-litcal` | ⚠ Yes BUT only after Phase 2 has run — operator manually puts the ID into the GH secret after generation. |
| `ZITADEL_CLIENT_ID` (per OIDC app) | Same | ⚠ Same as above |
| `OPENFGA_STORE_ID`, `OPENFGA_MODEL_ID` | Generated by `setup-openfga.sh --create-litcal-store` | ⚠ Same |
| Static config (image versions, hostnames) | This repo's compose file | ✓ Already source-controlled — no need to mirror in GH secrets |

### What probably should NOT flow through GH Actions

| Value | Why not |
|---|---|
| `ZITADEL_MASTERKEY` | Single most catastrophic-if-leaked secret; generated once and never rotated. Don't put it in any system that's not strictly need-to-know. |
| Per-property `OPENFGA_PRESHARED_KEY` | Currently shared across consumers. Future direction may split per-consumer; keep delivery out-of-band until that's decided. |
| `ZITADEL_DB_PASSWORD`, `OPENFGA_DB_PASSWORD` | Tied to Postgres role passwords; if you rotate via CI, you need atomic ALTER ROLE + .env update + container restart, which is hard to do safely. |
| `ZITADEL_ADMIN_PASSWORD` | Bootstrap only — force-changed on first login. Pointless to keep in CI after that. |
| SMTP relay password | Tied to the Plesk mailbox; rotating means coordinated Plesk + Zitadel API update. |

### Recommended hybrid

1. **Source-control non-secret config** in this repo (already done): image versions, public hostnames, port mappings, env templates, compose file.
2. **Manual generation + manual `.env` placement on the VPS** for the small set of high-stakes secrets (masterkey, DB passwords, SMTP password, preshared key). They live exactly one place: the VPS `.env.production`, backed up to a password manager. No CI involvement.
3. **GH Actions secrets for generated-then-stable IDs** (Project ID, Client ID, Store ID, Model ID) once Phase 1 + Phase 2 have produced them. The CI in each consumer property's repo can then read these as env at deploy time, eliminating manual env edits per-consumer.

### The bootstrap circular problem

You can't put generated IDs in GH secrets before you've generated them. So Phase 1 is ALWAYS manual on the VPS. Once Phase 1 + Phase 2 emit the handoff IDs, you can promote them to GH secrets for future re-deploys of consumer repos. Setting up CI for the umbrella infra repo itself (cdcf-infra) is low-value — there's nothing here to "deploy" beyond the compose file + scripts that the operator already runs by hand.

### Concrete suggestion

- Leave the umbrella infra repo (`cdcf-infra`) CI-free for now. Operator runs scripts by hand from the VPS.
- For each consumer property repo, after Phase 2 emits its handoff values, the property's maintainer adds the non-secret IDs to their repo's GH Actions secrets (e.g. `ZITADEL_PROJECT_ID`, `ZITADEL_CLIENT_ID`, `OPENFGA_STORE_ID`, `OPENFGA_MODEL_ID`). Their existing deploy workflow templates them into the `.env.production` it ships.
- Truly-secret values (preshared key, machine-token PATs, JWT_SECRET) stay as GH Actions secrets too if the property's CI deploys them; the umbrella operator delivers them once via secure channel.

---

## 9. Troubleshooting catalog

Each entry: error message → root cause → fix. Drawn from real incidents during the umbrella's initial rollout.

### 9.1 Bootstrap PAT files don't appear in `runtime/zitadel-data/`

**Symptom**: `ls /opt/cdcf-auth/runtime/zitadel-data/` returns empty after first `docker compose up`; Zitadel logs show the bootstrap PAT printed to stdout as a bare random-looking string.

**Cause**: `ZITADEL_FIRSTINSTANCE_PATPATH` and/or `ZITADEL_FIRSTINSTANCE_LOGINCLIENTPATPATH` not set in compose — Zitadel falls back to printing the PAT to stdout.

**Fix**: verify both env vars are set in `auth/docker-compose.prod.yml` under the `zitadel` service. They were added in PR #3; pull main if you're on an older checkout.

### 9.2 Zitadel container crash-looping with "permission denied to create database"

**Cause**: `zitadel` Postgres role doesn't have `CREATEDB`. Zitadel's `start-from-init` probes by attempting CREATE DATABASE even when the target DB exists.

**Fix**: `sudo -u postgres psql -c "ALTER ROLE zitadel CREATEDB;"`, then `docker compose restart zitadel`.

### 9.3 Zitadel container crash-looping with `no pg_hba.conf entry for host ... user "zitadel", database "postgres"`

**Cause**: Zitadel's `start-from-init` connects to the `postgres` system DB BEFORE connecting to its target. The pg_hba.conf rule covering `database=zitadel` doesn't cover the system DB connect.

**Fix**: add the third pg_hba.conf rule per §4.2 (`host postgres zitadel ...`), reload Postgres.

### 9.4 Zitadel SMTP test fails with TLS cert verification error

**Cause**: Set `SMTP_HOST` to `host.docker.internal`. The Postfix loopback presents the self-signed `CN=Plesk` cert; Zitadel's TLS verification rejects it.

**Fix**: change `SMTP_HOST` to `catholicdigitalcommons.org` (the public hostname). Plesk serves the proper Let's Encrypt cert via SNI on the public name. Container resolves via public DNS and reaches the VPS via NAT loopback.

### 9.5 Admin console redirects to `/ui/v2/login/login?authRequest=...` and shows `{"code": 5, "message": "Not Found"}`

**Cause**: `zitadel-login` (v2 UI) container not running, OR Plesk Docker Proxy Rule for `auth.*` points directly at `cdcf-auth-zitadel-1` instead of the internal nginx proxy `cdcf-auth-zitadel-proxy-1`.

**Fix**: verify `docker compose ps` shows `cdcf-auth-zitadel-login-1` as up. Verify Plesk Docker Proxy Rule for `auth.catholicdigitalcommons.org` targets `cdcf-auth-zitadel-proxy-1` (port 80), not the Zitadel backend directly.

### 9.6 Bootstrap admin login name has weird `@<orgdomain>` suffix

**Cause**: Even with `DEFAULTINSTANCE_DOMAINPOLICY_USERLOGINMUSTBEDOMAIN=false` set in compose, the domain policy doesn't apply retroactively to the bootstrap user created inside the same `03_default_instance` migration.

**Fix**: `./setup-zitadel.sh --target production --rename-bootstrap-admin` (renames to `${ZITADEL_ADMIN_EMAIL}` via `PUT /management/v1/users/{id}/username`). Note: `PUT` not `POST` — Zitadel's v1 management API uses PUT for username changes; POST returns 405; the v2 PATCH `/v2/users/{id}` returns 501 ("user type is not implemented").

### 9.7 Property's frontend login fails after env "just" being set

**Class of symptoms**:
- `/auth/login.php` → 503 `{"error":"OIDC not configured"}` — `ZITADEL_ISSUER` or `ZITADEL_CLIENT_ID` missing/empty.
- `/auth/login.php` → 500 `{"error":"Failed to initialize OIDC client"}` — `FRONTEND_URL` missing (separate var, not checked by `isConfigured()`; throws inside `fromEnv()`).
- Redirects to Zitadel but registration creates user in WRONG ORG (the ZITADEL default org, not LiturgicalCalendar) — Frontend's authorize URL doesn't include the Zitadel-specific org-scope `urn:zitadel:iam:org:id:{orgId}`.
- Login form rejects credentials — `ZITADEL_CLIENT_ID` cross-wired (used the API Backend's `PRIVATE_KEY_JWT` client_id where the Frontend's Web/PKCE client_id should be).

**Common diagnostic** for the env-missing ones: PHP's catch in `auth/login.php` hides the actual exception message but logs it. `sudo tail /var/log/apache2/error.log` (or equivalent) shows the real cause.

### 9.8 Admin console shows `[permission_denied] Organisation doesn't exist (AUTH-Bs7Ds)` then works after refresh

**Cause**: Initial-load race in Zitadel v4 — multiple parallel API calls fire immediately after token issue; some hit the org-context resolver before some cache primes. Identical calls a few hundred ms later succeed.

**Fix**: none needed — benign. The error popup goes away after a page refresh and the underlying state is sound. Consider opening an upstream issue if it ever blocks real work.

### 9.9 `.env.<environment>` file edited but values don't take effect (LitCal Frontend specific)

**Cause**: `Dotenv\Dotenv::createImmutable` with multi-file array means **first-match-wins**. If `.env.local` exists with `KEY=` unset, it shadows `.env.production` where the value is set. Also, `.env.staging` was missing from the loader list until LiturgicalCalendarFrontend PR #308 — older deployments may not have the fix.

**Fix**: ensure target env file is HIGHER priority in the loader list than any shadowing file. Order is `.env.local → .env.development → .env.staging → .env.production → .env`.

### 9.10 New user registered via passkey but no email verification sent

**Cause**: Passkey signup flow doesn't auto-trigger email verification (WebAuthn is treated as sufficient proof of identity). User is created in `USER_STATE_ACTIVE` with email unverified.

**Fix**: trigger verification explicitly via management API `POST /management/v1/users/{id}/email/_resendinitialization` (or equivalent v2 endpoint), or add a "verify email" prompt in the consuming app's UX.

---

## 10. Appendix

### 10.1 Env var reference (umbrella `.env.production`)

| Variable | Required | Purpose |
|---|---|---|
| `ZITADEL_MASTERKEY` | ✓ | 32-char encryption key. **Never rotate.** Loss = unrecoverable DB. |
| `ZITADEL_DB_NAME`, `ZITADEL_DB_USER`, `ZITADEL_DB_PASSWORD` | ✓ | Host Postgres role for Zitadel |
| `OPENFGA_DB_NAME`, `OPENFGA_DB_USER`, `OPENFGA_DB_PASSWORD` | ✓ | Host Postgres role for OpenFGA |
| `ZITADEL_ADMIN_USER`, `ZITADEL_ADMIN_EMAIL`, `ZITADEL_ADMIN_PASSWORD` | ✓ | IAM admin bootstrap. Login name = email. |
| `ZITADEL_ADMIN_FIRSTNAME`, `ZITADEL_ADMIN_LASTNAME` | optional | Display name (default: "IAM Admin") |
| `OPENFGA_PRESHARED_KEY` | ✓ | Bearer token for OpenFGA HTTP API |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_FROM_ADDRESS`, `SMTP_FROM_NAME` | required for §6 | Plesk Postfix relay creds (reference values; Zitadel stores its own internally) |

### 10.2 Useful API endpoints (Zitadel admin/management)

All require automation PAT in `Authorization: Bearer ...` + `Host: auth.catholicdigitalcommons.org` header.

| Action | Method + path |
|---|---|
| List Orgs | `POST /zitadel.org.v2.OrganizationService/ListOrganizations` |
| Create Org | `POST /zitadel.org.v2.OrganizationService/AddOrganization` (NOT `CreateOrganization` — Zitadel inconsistency) |
| List Projects (in org) | `POST /zitadel.project.v2.ProjectService/ListProjects` |
| Create Project | `POST /zitadel.project.v2.ProjectService/CreateProject` |
| Update Project | `POST /zitadel.project.v2.ProjectService/UpdateProject` — body uses `projectId`, NOT `id` |
| Add Role | `POST /zitadel.project.v2.ProjectService/AddProjectRole` |
| Create App (API or OIDC) | `POST /zitadel.application.v2.ApplicationService/CreateApplication` |
| Rename user | `PUT /management/v1/users/{id}/username` (PUT, not POST — POST returns 405) |
| Add SMTP provider | `POST /admin/v1/email/smtp` |
| Activate SMTP provider | `POST /admin/v1/smtp/{id}/_activate` |
| Test SMTP send | `POST /admin/v1/smtp/{id}/_test` |

### 10.3 Gotchas list (one-liners)

- Zitadel v2 verb inconsistency: `AddOrganization` but `CreateProject` + `CreateApplication`. `UpdateProject` body uses `projectId`, not `id`.
- `DEFAULTINSTANCE_DOMAINPOLICY_*` env vars apply to USERS CREATED AFTER bootstrap, not retroactively to the bootstrap admin itself.
- `ZITADEL_MASTERKEY` must be exactly 32 chars.
- `ZITADEL_ADMIN_PASSWORD` must satisfy default complexity policy (upper + lower + digit + symbol). Alphanumeric-only crashes the `03_default_instance` migration.
- The `zitadel` Postgres role needs `CREATEDB`.
- pg_hba.conf needs THREE rules for Zitadel: `zitadel`-on-`zitadel`, `openfga`-on-`openfga`, AND `zitadel`-on-`postgres` (for the bootstrap DB-existence probe).
- `host.docker.internal` is reachable from containers via the docker bridge gateway, but Postfix's self-signed cert on that hostname fails Zitadel's TLS verification. Use the public hostname for SMTP.
- Per-org SMTP is not natively supported. One instance-wide sender; per-org email body templates are still customizable.
- DKIM selector for catholicdigitalcommons.org is `mail` (not `default` or `plesk`).
- File-load order on multi-file Dotenv loaders is first-match-wins; `.env.local` shadows everything.
- Passkey registration doesn't trigger email verification automatically.
- Property frontends must include the Zitadel org-scope on the authorize URL or registrations land in the IAM default org.
- API Backend's `client_id` and Frontend's `client_id` are DIFFERENT and must not be cross-wired.
- The Liturgical-Calendar GitHub org uses `development` as default branch (not `main`). Always target `development` for PRs there.

### 10.4 Related external docs

- Zitadel self-hosting: <https://zitadel.com/docs/self-hosting/manage/configure>
- Zitadel API reference: <https://zitadel.com/docs/apis/introduction>
- OpenFGA modeling: <https://openfga.dev/docs/modeling>
- This repo's other docs: [`auth/README.md`](../auth/README.md), [`auth/handoffs/README.md`](../auth/handoffs/README.md)
- Umbrella architecture discussion: <https://github.com/CatholicOS/cdcf-website/discussions/98>

---

*Last updated: 2026-05-17. Edits welcome via PR.*
