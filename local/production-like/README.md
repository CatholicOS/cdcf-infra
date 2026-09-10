# Full production-like Docker integration

## Environments

- `local/dev`: quick mode for daily development.
- `local/production-like/components/postgres`: standalone PostgreSQL host component test.
- `local/production-like/components/applications`: standalone application component test.
- `local/production-like/components/nginx`: standalone nginx/Plesk-like component test.
- `local/production-like/scenarios`: hybrid assemblies isolating one production-like boundary.
- `local/production-like`: full production-like assembly of those three components.

The integration Compose uses Docker Compose `include`; it does not duplicate any
service implementation.

## Hybrid scenarios

Use the PostgreSQL scenario to exercise the simulated Ubuntu/PostgreSQL host with
the pinned Zitadel, Login V2 and OpenFGA images, without nginx:

```bash
docker compose -f local/production-like/scenarios/compose.postgres.yaml \
  up -d --build --wait
```

Use the nginx scenario to exercise the Ubuntu/nginx component with the fast
containerized databases and application services from `local/dev`:

```bash
docker compose -f local/production-like/scenarios/compose.nginx.yaml \
  up -d --build --wait
```

The nginx scenario includes the dev proxy overlay to configure Login V2 during
Zitadel's first boot, but places `plesk-proxy` behind a disabled profile so only
the production-like `nginx-host` publishes port 8090.

Run only one local environment or scenario at a time: the dev, hybrid and full
production-like projects intentionally publish some of the same loopback ports.
Stop the active project with the same Compose file before switching scenarios.

```text
localhost:8090
      |
      v
 nginx-host
      |
      v
+-------------------------------+
| cdcf-integration-application  |
| zitadel  zitadel-login        |
| openfga                       |
+---------------+---------------+
                |
     host.docker.internal:5432
                |
                v
   cdcf-integration-database
     postgres-host (172.31.250.10)
```

## Composition and overrides

`compose.yaml` includes the Compose files from `components/postgres`,
`components/applications`, and `components/nginx`. Small overrides provide only:

- the two integration network names;
- application dependencies on healthy PostgreSQL;
- nginx dependencies on healthy Zitadel and Login V2;
- replacement of standalone network attachments;
- a profile that keeps the standalone `db-verifier` out of nominal integration.

The final network boundary is deliberately narrow:

- `postgres-host`: database network only;
- `zitadel`, `openfga-migrate`, `openfga`: application + database networks;
- `zitadel-login`, `nginx-host`: application network only.

The application containers map `host.docker.internal` to `172.31.250.10`, while
their database traffic originates from `172.31.250.0/24`. This exercises the
real restricted `pg_hba.conf` rules instead of using the published port 15432.
nginx uses Docker DNS names `zitadel:8080` and `zitadel-login:3000`.

## Start and verify

The standalone simulations publish some of the same diagnostic ports. Stop them
before running the integration project (plain `down`, without `-v`, preserves
their independent state):

```bash
docker compose -f local/production-like/components/postgres/compose.yaml down
docker compose -f local/production-like/components/applications/compose.yaml down
docker compose -f local/production-like/components/nginx/compose.yaml down
```

Then:

```bash
cd local/production-like
docker compose config
docker compose build
docker compose up -d --build --wait
./scripts/verify.sh
```

The component verification scripts are not invoked automatically: each changes
to or assumes its standalone project directory/name. Integration verification
instead tests the cross-component boundaries without copying their exhaustive
component-level assertions.

Optional, recoverable boundary-failure checks:

```bash
./scripts/failure-tests.sh
```

This briefly stops PostgreSQL and proves an application DB operation fails, then
stops Login V2 and proves only its nginx route fails (proxy error or a bounded
client timeout, depending on nginx's upstream timeout). A trap restores the stack.

## Restart versus full reset

A normal restart preserves all PostgreSQL and PAT data:

```bash
docker compose down
docker compose up -d --wait
./scripts/verify.sh
```

A full reset removes only resources owned by the `cdcf-integration` project,
including the two PostgreSQL volumes and the Zitadel PAT runtime volume:

```bash
./scripts/reset.sh
docker compose up -d --build --wait
./scripts/verify.sh
```

Never use the full reset for production or for unrelated Compose projects.

## Limits

- PostgreSQL and the nginx/Plesk host remain Docker simulations.
- There is no real systemd, Plesk, TLS, Let's Encrypt, VPS firewall, or VPS kernel.
- Credentials and data are local and disposable.
- Post-bootstrap production provisioning, including bootstrap-admin renaming, is
  not reproduced.
- Diagnostic ports 15432, 18080, 13000, and 18081 remain loopback-only because
  they come from the reusable standalone component definitions.
