# Hybrid production-like scenarios

These scenarios isolate one production-like infrastructure boundary while using
the simpler Docker environment for the rest. They reuse the existing Compose
components and contain no duplicate service definitions.

## Available scenarios

| Scenario | PostgreSQL | Applications | nginx |
| --- | --- | --- | --- |
| `compose.postgres.yaml` | Ubuntu/PostgreSQL production-like component | Pinned official images | None |
| `compose.nginx.yaml` | Lightweight `postgres:16-alpine` containers | Pinned official images | Ubuntu/nginx production-like component |

The full environment remains available through
`local/production-like/compose.yaml` when both boundaries must be tested
together.

## PostgreSQL boundary

This scenario starts the simulated Ubuntu PostgreSQL host together with Zitadel,
Login V2 and OpenFGA. It does not start nginx. Application traffic reaches
PostgreSQL through `host.docker.internal:5432` and the restricted simulation
network.

```bash
docker compose \
  -f local/production-like/scenarios/compose.postgres.yaml \
  up -d --build --wait
```

Stop the scenario while preserving its data:

```bash
docker compose \
  -f local/production-like/scenarios/compose.postgres.yaml \
  down
```

Repeat a completely blank PostgreSQL and Zitadel first boot:

```bash
docker compose \
  -f local/production-like/scenarios/compose.postgres.yaml \
  down -v
```

## nginx boundary

This scenario starts the fast development databases and application containers,
but replaces the lightweight `nginx:alpine` proxy with the production-like
Ubuntu/nginx component.

The development proxy overlay is included because it supplies the Login V2
first-boot configuration and PAT volume. Its `plesk-proxy` service is placed
behind the disabled `dev-proxy-disabled` profile, so only `nginx-host` publishes
port 8090.

```bash
docker compose \
  -f local/production-like/scenarios/compose.nginx.yaml \
  up -d --build --wait
```

The reverse proxy is available at `http://localhost:8090`.

Stop the scenario while preserving its data:

```bash
docker compose \
  -f local/production-like/scenarios/compose.nginx.yaml \
  down
```

Repeat a blank Zitadel/Login V2 first boot and regenerate the PAT:

```bash
docker compose \
  -f local/production-like/scenarios/compose.nginx.yaml \
  down -v
```

## Overrides

Files under `overrides/` only connect existing definitions:

- `postgres.yaml` gives the database scenario its isolated network and disables
  the standalone database verifier by default;
- `applications-postgres.yaml` connects the official application containers to
  the PostgreSQL scenario;
- `dev-nginx.yaml` disables the lightweight dev proxy and names the scenario
  application network;
- `nginx.yaml` connects the production-like nginx container to that network and
  waits for Zitadel and Login V2 to become healthy.

## Usage rules

- Run only one dev, hybrid or full production-like environment at a time. They
  intentionally publish some of the same loopback ports.
- Use the same Compose file for `up` and `down` so the correct project resources
  are selected.
- The credentials and volumes are disposable local test data. Never reuse them
  in staging or production.
- These scenarios do not reproduce Plesk, TLS termination, Let's Encrypt, the
  VPS firewall, production secrets or production data.
