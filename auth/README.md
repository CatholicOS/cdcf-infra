# cdcf-infra/auth — Zitadel + OpenFGA

Shared identity (Zitadel) and relationship-based authorization (OpenFGA) for the Catholic OS umbrella.

- **Identity:** `https://auth.catholicdigitalcommons.org`
- **Authorization:** `https://authz.catholicdigitalcommons.org`

Both run as containers on the existing cdcf-website Plesk VPS via the Plesk Docker extension. Plesk terminates TLS upstream via Let's Encrypt; containers bind to `127.0.0.1` only and are reverse-proxied by Plesk's nginx.

## Architecture pin

- Single Zitadel instance, **one Zitadel Org per property** (`CDCF`, `LiturgicalCalendar`, `BibleGet`, `OntoKit`). No automatic cross-property SSO — intentional.
- **No `zitadel-login` v2 service.** Each property's frontend implements its own login UI calling Zitadel APIs. Zitadel's built-in v1 console at `/ui/console/` is retained for admin tasks only.
- Shared OpenFGA with a separate `openfga-db` Postgres instance (decoupled backups).
- Phase 1 consumer: LiturgicalCalendarAPI. Other Orgs are pre-provisioned stubs.
- See the open-question Discussion: <https://github.com/CatholicOS/cdcf-website/discussions/98>.

## First-time bring-up

```bash
# 1. On the VPS, create bind-mount targets owned by the deploy user
sudo mkdir -p /var/lib/cdcf-auth/{zitadel-pgdata,zitadel-data,openfga-pgdata}
# Zitadel image is scratch-based; PAT bind-mount must be world-writable
sudo chmod 0777 /var/lib/cdcf-auth/zitadel-data

# 2. Copy the env template and fill it
cp .env.production.example .env.production
chmod 0600 .env.production
# Edit .env.production — generate ZITADEL_MASTERKEY with:
#   openssl rand -base64 32 | head -c 32
# Generate OPENFGA_PRESHARED_KEY with:
#   openssl rand -base64 48

# 3. Bring up the stack
docker compose --env-file .env.production -f docker-compose.prod.yml up -d

# 4. Confirm Zitadel + OpenFGA are healthy
curl -s http://127.0.0.1:8080/debug/ready    # → 200
curl -s http://127.0.0.1:8081/healthz        # → 200

# 5. The automation-user PAT lands at /var/lib/cdcf-auth/zitadel-data/automation-user.pat
#    after first boot. Run the bootstrap scripts:
./setup-zitadel.sh --target production --create-orgs
./setup-openfga.sh --target production --create-store liturgical_calendar
```

## Plesk-side setup

Two subdomains, configured in Plesk's UI:

| Subdomain | Reverse-proxies to | Notes |
| --- | --- | --- |
| `auth.catholicdigitalcommons.org` | `http://127.0.0.1:8080` | Let's Encrypt; pass `X-Forwarded-Proto: https` |
| `authz.catholicdigitalcommons.org` | `http://127.0.0.1:8081` | Let's Encrypt; pass `X-Forwarded-Proto: https` |

Sample nginx directives (paste into Plesk's "Additional nginx directives" per subdomain):

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;  # 8081 for the authz subdomain
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Host $host;
    proxy_request_buffering off;
    proxy_buffering off;
    client_max_body_size 10m;
}
```

## Backup

`backup/pg-dump.sh` produces gzipped pg_dump output for both Postgres instances. Wire it into cron daily and copy to off-server storage:

```cron
15 3 * * * /opt/cdcf-auth/backup/pg-dump.sh >> /var/log/cdcf-auth-backup.log 2>&1
```

The Zitadel masterkey and `.env.production` are NOT in pg_dump output — back them up separately (e.g. via Plesk's backup tools, encrypted at rest).

## Recovery

Restoring Zitadel requires both the pg_dump AND the original `ZITADEL_MASTERKEY`. The masterkey decrypts secrets in the dump; without it the dump is unrecoverable. This is the single most important secret to preserve out-of-band.

## Adding a new consumer property

1. Decide whether the property gets its own Zitadel Org (per-property isolation, default) or fits under an existing Org.
2. Pre-provision the Org via `setup-zitadel.sh --create-org <NAME>` if it doesn't exist.
3. Create a Project under the Org for the property's apps.
4. Create OIDC apps with the property's prod callback URLs.
5. For OpenFGA-using properties, create a store and seed an authorization model via `setup-openfga.sh --create-store <slug>`.
6. Write a handoff doc under `handoffs/<property>.md` with the non-secret values (issuer URL, client ID, project ID, store ID, model ID) the property's repo needs to consume. Secrets (client secret, preshared key) deliver out-of-band.
7. Open an issue in the property's repo with the handoff doc inline.
