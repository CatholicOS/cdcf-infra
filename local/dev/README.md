# Fast local development

This directory contains a disposable Zitadel and OpenFGA environment optimized
for fast daily development.
The optional proxy overlay mounts the production nginx configuration as its
read-only source:

```text
../../auth/nginx/zitadel.conf
```

There is intentionally no maintained local copy of that configuration. Routing
and the Content Security Policy therefore come from the same file used in
production.

## Base stack

```bash
cd local/dev
docker compose up -d --wait
```

Zitadel is exposed at `http://localhost:8080` and OpenFGA at
`http://localhost:8081`.

On a fresh first boot, the Zitadel administrator credentials are:

```text
Login: local-admin@zitadel.localhost
Password: LocalTest1!
```

Zitadel v4.15.0 creates the bootstrap human before the default domain policy is
fully applied. Consequently, neither `local-admin` nor `admin@example.test` is
accepted as the login name for this particular user, even though the configured
policy permits usernames without a domain and uses email addresses as usernames
for regular users.

## Local Plesk proxy simulation

Login V2 is configured during Zitadel's first boot. Reset the disposable local
volumes before switching to this variant:

```bash
cd local/dev
docker compose -f compose.yaml -f compose.proxy.yaml down -v
docker compose -f compose.yaml -f compose.proxy.yaml up -d --wait
```

The proxy is exposed at `http://localhost:8090`; the admin console is available
at `http://localhost:8090/ui/console/`.

## Scope and known differences

This is not a complete production validation. It does not test Plesk itself,
Plesk-managed TLS, Let's Encrypt, VPS filesystem permissions,
`host.docker.internal`, host PostgreSQL, or production `pg_hba.conf` rules.
The local databases are containerized for ease of use.

The shared template uses nginx's `$http_host` for `Host` and
`X-Forwarded-Host`, preserving the client port locally while retaining the same
behavior for the production hostname. Its only environment-specific value is
`NGINX_FORWARDED_PROTO`: production sets it to `https`, while this overlay sets
it to `http`.

The official nginx image renders the mounted template into `conf.d` at container
startup. This avoids duplicating the routing and CSP-sensitive configuration.

## Stop or reset

```bash
# Keep local database data
docker compose -f compose.yaml -f compose.proxy.yaml down

# Delete all disposable local data
docker compose -f compose.yaml -f compose.proxy.yaml down -v
```
