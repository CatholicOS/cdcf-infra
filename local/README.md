# Local environments

This directory provides two complementary Docker environments for auth and
authorization development.

## Important: Docker simulation, not production

Everything under `local/` is designed to run locally with Docker. The
`production-like` name means that the environment reproduces selected service,
network and dependency boundaries from production; it does **not** mean that it
is a complete or exact copy of the production VPS.

In particular:

- Plesk is not installed or executed. A containerized nginx service reproduces
  only the internal reverse-proxy routes and headers relevant to Zitadel and
  Login V2;
- TLS termination, Plesk-generated configuration, certificate renewal and
  Let's Encrypt are not reproduced;
- the production-like PostgreSQL host is still a Docker container. It installs
  PostgreSQL from Ubuntu packages to approximate the host layout, but it is not
  a real VPS host installation;
- Docker networks approximate the application-to-host and reverse-proxy
  boundaries, but they do not reproduce the VPS firewall, kernel, bridge,
  routing or public network;
- production users, secrets, volumes, permissions, traffic, backups and data are
  never used;
- systemd, Plesk service management and operator-driven production restarts are
  outside the scope of these environments.

A successful local or production-like verification proves only the behaviors
explicitly checked by these Docker environments. It must not be treated as
approval to deploy a Compose, PostgreSQL, nginx or Plesk change directly to
production without the normal review and production-specific checks.

## Fast development

Use [`dev`](dev/) for daily work. It runs the pinned Zitadel and OpenFGA images
with simple containerized PostgreSQL databases. An optional Compose overlay adds
Login V2 and a local reverse proxy based on the production nginx configuration.

```bash
cd local/dev
docker compose up -d --wait
```

## Production-like validation

Use [`production-like`](production-like/) before proposing infrastructure or
routing changes. It assembles independently testable PostgreSQL, application,
and nginx components and exercises boundaries that the fast environment omits.

```bash
cd local/production-like
docker compose up -d --build --wait
./scripts/verify.sh
```

Two hybrid scenarios are also available when only one production-like boundary
needs to be isolated:

```bash
# Production-like PostgreSQL with the pinned application images, without nginx
docker compose -f local/production-like/scenarios/compose.postgres.yaml up -d --build --wait

# Production-like nginx with the fast dev databases and application stack
docker compose -f local/production-like/scenarios/compose.nginx.yaml up -d --build --wait
```

## Layout

```text
local/
├── dev/                         fast daily environment
└── production-like/
    ├── compose.yaml             complete production-like assembly
    ├── components/
    │   ├── postgres/            Ubuntu/PostgreSQL host boundary
    │   ├── applications/        Zitadel, Login V2, and OpenFGA
    │   └── nginx/               reverse-proxy boundary
    ├── scenarios/               hybrid boundary assemblies
    └── scripts/                 integration checks and reset helpers
```

## Continuous integration

`.github/workflows/validate-local.yml` validates every local shell script and
Compose model when `local/**` or the shared production nginx configuration
changes. These lightweight checks run on pull requests, merge-queue entries and
pushes to `main`.

The required checks also render the shared nginx template with both `http` and
`https` through the official `nginx:alpine` template mechanism. They verify the
preserved `$http_host` directives, protocol substitution, CSP and final nginx
syntax without contacting production.

The same workflow exposes a manual `workflow_dispatch` run that additionally
builds, starts and verifies the complete production-like environment. Its cleanup
step always removes the CI project's containers, networks and volumes.

Run the required lightweight checks locally with:

```bash
docker compose -f local/dev/compose.yaml config --quiet
docker compose -f local/dev/compose.yaml -f local/dev/compose.proxy.yaml config --quiet
docker compose -f local/production-like/components/postgres/compose.yaml config --quiet
docker compose -f local/production-like/components/applications/compose.yaml config --quiet
docker compose -f local/production-like/components/nginx/compose.yaml config --quiet
docker compose -f local/production-like/scenarios/compose.postgres.yaml config --quiet
docker compose -f local/production-like/scenarios/compose.nginx.yaml config --quiet
docker compose -f local/production-like/compose.yaml config --quiet
```
