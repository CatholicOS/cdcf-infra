# cdcf-infra/auth — Zitadel + OpenFGA

Shared identity (Zitadel) and relationship-based authorization (OpenFGA) for the Catholic OS umbrella.

- **Identity:** `https://auth.catholicdigitalcommons.org`
- **Authorization:** `https://authz.catholicdigitalcommons.org`

Both run as containers on the existing cdcf-website Plesk VPS via the Plesk Docker extension. Plesk terminates TLS upstream via Let's Encrypt; containers bind to `127.0.0.1` only and are reverse-proxied by Plesk's nginx. **Both services persist to the host's native PostgreSQL** — no containerized DBs in this stack.

## Canonical VPS layout

| Path on VPS | Contents |
| --- | --- |
| `/opt/cdcf-auth/` | Git clone of [`CatholicOS/cdcf-infra`](https://github.com/CatholicOS/cdcf-infra). All compose, env, and scripts live under here. |
| `/opt/cdcf-auth/auth/docker-compose.prod.yml` | The compose file. |
| `/opt/cdcf-auth/auth/.env.production` | Secrets (gitignored, mode 0600, deploy user only). |
| `/opt/cdcf-auth/auth/setup-*.sh` | Bootstrap + provisioning scripts. |
| `/opt/cdcf-auth/auth/backup/pg-dump.sh` | Daily backup job (host `pg_dump`, not docker exec). |
| `/opt/cdcf-auth/runtime/zitadel-data/` | Zitadel's bind-mounted data dir. PAT lands here on first boot. World-writable (scratch-image constraint). |
| `/var/www/vhosts/catholicdigitalcommons.org/auth.catholicdigitalcommons.org/` | Plesk's vhost dir for the `auth.*` subdomain — just nginx config Plesk manages. No app content. |
| `/var/www/vhosts/catholicdigitalcommons.org/authz.catholicdigitalcommons.org/` | Same, for `authz.*`. |

Plesk's Docker extension picks up `docker-compose.prod.yml` at the path above via *"Add Docker Compose Project → From a folder"* pointing at `/opt/cdcf-auth/auth/`.

## Architecture pin

- Single Zitadel instance, **one Zitadel Org per property** (`CDCF`, `LiturgicalCalendar`, `BibleGet`, `OntoKit`). No automatic cross-property SSO — intentional.
- **`zitadel-login` v2 UI service is deployed** but ONLY serves `/ui/v2/login/*` — that's the login flow the **admin console** (`/ui/console/`) redirects to. Per-property end-user login UIs are still built into each property's frontend (calling Zitadel APIs directly). The two concerns are independent: admin console login (this service) vs. end-user login (each property's own UI).
- **Shared OpenFGA**, with its own database on the host Postgres.
- **Host Postgres only** — no containerized DBs. One Postgres instance to back up, patch, monitor.
- Phase 1 consumer: LiturgicalCalendarAPI. Other Orgs are pre-provisioned stubs.
- See the open-question Discussion: <https://github.com/CatholicOS/cdcf-website/discussions/98>.

## Prerequisites

### 1. Host Postgres ≥ 14

Zitadel requires PostgreSQL 14 or newer. Check on the VPS:

```bash
psql --version
```

If older, upgrade the host Postgres (or fall back to a containerized DB in the compose) before bring-up.

### 2. Create roles + databases on the host

Run these as the Postgres superuser (typically `postgres`) on the VPS, **substituting strong passwords matching what you'll put in `.env.production`**:

```sql
CREATE ROLE zitadel WITH LOGIN PASSWORD 'CHANGEME-zitadel';
ALTER ROLE zitadel CREATEDB;   -- Zitadel's start-from-init checks for the DB
                               -- via a CREATE-style probe even when it exists.
CREATE DATABASE zitadel OWNER zitadel;

CREATE ROLE openfga WITH LOGIN PASSWORD 'CHANGEME-openfga';
CREATE DATABASE openfga OWNER openfga;
```

Owner role gives the runtime user the privileges Zitadel + OpenFGA need for their own migrations. The `CREATEDB` grant on `zitadel` is required even though we pre-create the database — Zitadel's `start-from-init` command always runs a database-creation probe and fails on first boot otherwise.

### 3. Allow docker-bridge connections in `pg_hba.conf`

The compose uses `host.docker.internal` to resolve to the docker-bridge host-gateway (typically `172.17.0.1`). Add to `/etc/postgresql/<version>/main/pg_hba.conf`:

```
# Allow docker-bridge connections (cdcf-auth stack)
host  zitadel   zitadel  172.16.0.0/12  scram-sha-256
host  openfga   openfga  172.16.0.0/12  scram-sha-256
# Zitadel's start-from-init first connects to the postgres system DB
# to verify its target DB exists — it needs auth permission there too.
# (The zitadel role has no privileges in the postgres DB by default;
# this is a connect-only allow.)
host  postgres  zitadel  172.16.0.0/12  scram-sha-256
```

The `172.16.0.0/12` range covers all default Docker networks (172.16-31.x.x). Reload Postgres:

```bash
sudo systemctl reload postgresql
```

### 4. Make Postgres listen on the docker bridge

In `/etc/postgresql/<version>/main/postgresql.conf`:

```
listen_addresses = 'localhost,172.17.0.1'
```

(or just `*` if the firewall already restricts external access to Postgres). Restart Postgres after this change:

```bash
sudo systemctl restart postgresql
```

## First-time bring-up

```bash
# 0. Prerequisites above are done.

# 1. Clone the repo to the canonical path
sudo git clone git@github.com:CatholicOS/cdcf-infra.git /opt/cdcf-auth

# 2. Create the Zitadel runtime data dir
sudo mkdir -p /opt/cdcf-auth/runtime/zitadel-data
# Zitadel image is scratch-based — bind mount must be world-writable
sudo chmod 0777 /opt/cdcf-auth/runtime/zitadel-data

# 3. Fill the env file
sudo cp /opt/cdcf-auth/auth/.env.production.example /opt/cdcf-auth/auth/.env.production
sudo chmod 0600 /opt/cdcf-auth/auth/.env.production
# Edit — generate ZITADEL_MASTERKEY with:
#   openssl rand -base64 32 | head -c 32
# Generate OPENFGA_PRESHARED_KEY with:
#   openssl rand -base64 48
# Set ZITADEL_DB_PASSWORD and OPENFGA_DB_PASSWORD to match what you
# CREATE ROLE'd in step 2 of Prerequisites.

# 4. Bring up the stack
cd /opt/cdcf-auth/auth
sudo docker compose --env-file .env.production -f docker-compose.prod.yml up -d

# 5. Confirm healthy
curl -s http://127.0.0.1:8080/debug/ready   # Zitadel → 200
curl -s http://127.0.0.1:8081/healthz       # OpenFGA → 200

# 6. Two PAT files land in /opt/cdcf-auth/runtime/zitadel-data/ after first boot:
#      automation-user.pat  - IAM_OWNER, used by setup-zitadel.sh and our own admin scripts
#      login-client.pat     - IAM_LOGIN_CLIENT, consumed by the zitadel-login container
#    Run the bootstrap scripts using the automation PAT:
sudo /opt/cdcf-auth/auth/setup-zitadel.sh --target production --create-orgs
sudo /opt/cdcf-auth/auth/setup-openfga.sh --target production --create-store liturgical_calendar
```

## Plesk-side setup

Two subdomains + three Plesk Docker Proxy Rules. DNS + Let's Encrypt set up in the standard Plesk UI; routing is handled by Tools & Settings → Docker → Proxy Rules (NOT by "Additional nginx directives", which gets shadowed by Plesk's default `location /` going to Apache).

| Subdomain | Path | Container | Container port | Purpose |
| --- | --- | --- | --- | --- |
| `auth.catholicdigitalcommons.org` | `/ui/v2/login` | `cdcf-auth-zitadel-login-1` | 3000 | Admin console login flow (v2 login UI) |
| `auth.catholicdigitalcommons.org` | `/` (catch-all) | `cdcf-auth-zitadel-1` | 8080 | Zitadel backend (APIs, console, OIDC endpoints) |
| `authz.catholicdigitalcommons.org` | `/` | `cdcf-auth-openfga-1` | 8080 | OpenFGA HTTP API |

**Order matters in Plesk's UI** — the more specific path (`/ui/v2/login`) must be evaluated before the catch-all (`/`). Plesk handles this correctly if you add the more specific rule first.

## Backup

`backup/pg-dump.sh` uses the host's `pg_dump` directly (no `docker exec` needed since the DBs are on the host) and writes gzipped dumps to `/var/backups/cdcf-auth/`. Wire it into cron:

```cron
15 3 * * * /opt/cdcf-auth/auth/backup/pg-dump.sh >> /var/log/cdcf-auth-backup.log 2>&1
```

The Zitadel masterkey and `.env.production` are NOT in pg_dump output — back them up separately (e.g. via Plesk's backup tools, encrypted at rest).

## Recovery

Restoring Zitadel requires both the pg_dump AND the original `ZITADEL_MASTERKEY`. The masterkey decrypts secrets in the dump; without it the dump is unrecoverable. **This is the single most important secret to preserve out-of-band.**

## Adding a new consumer property

1. Decide whether the property gets its own Zitadel Org (per-property isolation, default) or fits under an existing Org.
2. Pre-provision the Org via `setup-zitadel.sh --create-org <NAME>` if it doesn't exist.
3. Create a Project under the Org for the property's apps.
4. Create OIDC apps with the property's prod callback URLs.
5. For OpenFGA-using properties:
   - `CREATE DATABASE <slug>_authz OWNER <slug>` on the host Postgres (or reuse the shared `openfga` database with namespaced stores — current pattern uses one DB, multiple stores keyed by slug).
   - Run `setup-openfga.sh --create-store <slug>` to create the store and seed an authorization model.
6. Write a handoff doc under `handoffs/<property>.md` with the non-secret values (issuer URL, client ID, project ID, store ID, model ID) the property's repo needs to consume. Secrets (client secret, preshared key) deliver out-of-band.
7. Open an issue in the property's repo with the handoff doc inline.
