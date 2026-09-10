# Production-like application simulation

## Purpose

`local/production-like/components/applications` is the application layer of the production-like
local environment. It runs the real pinned Zitadel, Zitadel Login V2, and
OpenFGA images, but contains neither PostgreSQL nor nginx.

This is intentionally different from `local/dev`, the quick development mode:

| Mode | Purpose | Database | Proxy |
| --- | --- | --- | --- |
| `local/dev` | Fast daily development | Simple PostgreSQL containers | Optional local overlay |
| `local/production-like/components/applications` | Production-like application boundaries | External host-like simulation | Separate, connected later |

## Architecture

```text
                    nginx component
                           |
                           v
                  applications
                 /        |         \
            Zitadel   Login V2    OpenFGA
                 \                    /
                  host.docker.internal
                           |
                           v
               PostgreSQL host component
                      PostgreSQL
```

## Prerequisite and startup

Start the existing PostgreSQL host simulation first:

```bash
cd local/production-like/components/postgres
docker compose up -d --build --wait
./verify.sh
```

Then start this application layer:

```bash
cd ../applications
docker compose config
docker compose up -d --wait
./verify.sh
```

All credentials in this Compose file are public local-test defaults. Never reuse
them outside a developer machine.

## Database boundary

The application services join the existing external network
`cdcf-production-simulation_production-simulation`. Inside Zitadel and OpenFGA,
`host.docker.internal` is explicitly mapped to the PostgreSQL simulation's
verified static address `172.31.250.10`. Both use TCP port 5432 with SSL disabled,
matching that simulation's restricted `pg_hba.conf` rules and local credentials.

No database container or database volume is owned by this Compose project.
Consequently, `docker compose down -v` here resets the Login V2 PAT volume but
does **not** erase PostgreSQL. A true first-boot test also requires resetting the
separate disposable PostgreSQL simulation as shown below.

## Zitadel and Login V2

Zitadel advertises `http://localhost:8090`, matching the local nginx
entrypoint. Ports `127.0.0.1:18080` (Zitadel), `127.0.0.1:13000` (Login V2), and
`127.0.0.1:18081` (OpenFGA) are diagnostic-only; the future nginx connection
uses Docker DNS instead.

The first boot creates the local admin and a Login V2 machine user. Zitadel
writes `/zitadel-data/login-client.pat` into a named runtime volume. Login V2
waits for Zitadel to become healthy and mounts the same volume read-only.

The first-boot settings request `UserLoginMustBeDomain=false` and
`UserEmailAsUsername=true`. Zitadel persists `UserLoginMustBeDomain=false`, but
the bootstrap human is a special case in v4.15.0: it is created earlier in the
same migration and retains `local-admin@zitadel.localhost`. Neither `local-admin`
nor `admin@example.test` is accepted as its login. `verify.sh` checks the
persisted policy and user projections, then proves this behavior through real
password-backed session creation. Zitadel does not persist a separate
`UserEmailAsUsername` boolean in its domain-policy projection; for the bootstrap
human its observable effect is therefore explicitly **not** present. Renaming
that special user through the Zitadel API is a later provisioning concern, not a
responsibility of this clean application layer.

## OpenFGA

`openfga-migrate` runs the real database migration as a successful one-shot.
`openfga` starts only afterward, enforces the local preshared bearer key, and uses
the image's `/usr/local/bin/grpc_health_probe` against port 8081. The playground
is disabled because preshared authentication is enabled.

## Persistence, restart, and true reset

Application restart while retaining PostgreSQL and the PAT volume:

```bash
docker compose down
docker compose up -d --wait
./verify.sh
```

For a genuinely blank bootstrap, reset both disposable projects:

```bash
cd local/production-like/components/applications
docker compose down -v
cd ../postgres
docker compose down -v
docker compose up -d --build --wait
cd ../applications
docker compose up -d --wait
./verify.sh
```

## Networks and nginx integration

The stable application network is named `cdcf-application-simulation`. The
top-level `local/production-like/compose.yaml` attaches the nginx component to
the applications network so its production configuration resolves
`zitadel:8080` and `zitadel-login:3000`.

## Limits

- No Plesk, TLS, Let's Encrypt, real domain, VPS firewall, or host kernel.
- PostgreSQL lifecycle belongs to its separate simulation.
- Diagnostic ports bypass the future nginx path and bind only to loopback.
- The standalone component does not start nginx; use the top-level
  `local/production-like/compose.yaml` for the complete path.
