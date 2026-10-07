# Docker simulation of the production PostgreSQL host

This environment approximates PostgreSQL installed natively on an Ubuntu VPS,
while remaining fully disposable and runnable with Docker.

It is separate from `local/dev/`: that stack is optimized for fast application
development, while this one focuses on the production host/PostgreSQL boundary.

## What it reproduces

- Ubuntu 24.04 as the simulated host operating system.
- PostgreSQL installed from Ubuntu APT packages, not the official PostgreSQL
  container image.
- PostgreSQL 16 explicitly (`postgresql-16` and `postgresql-client-16`). The
  repository only documents production as PostgreSQL 14 or newer; it does not
  identify the production major version. PostgreSQL 16 is therefore the
  explicit Ubuntu 24.04 choice, not a claim about production.
- Ubuntu's `16/main` cluster managed with `pg_createcluster` and
  `pg_ctlcluster`, without systemd.
- Configuration at `/etc/postgresql/16/main/` and data at
  `/var/lib/postgresql/16/main/`, persisted in separate Docker volumes.
- `postgresql.conf` with network listening and SCRAM password storage.
- `pg_hba.conf` rules limited to the `172.31.250.0/24` simulation network.
- Separate `zitadel` and `openfga` roles and databases.
- The `CREATEDB` privilege required by Zitadel's `start-from-init` probe.
- Application-style access through `host.docker.internal`.

## Network model

```text
db-verifier (same conditions as an application container)
    |
    | host.docker.internal:5432
    v
172.31.250.10
postgres-host (Ubuntu 24.04)
    |
    v
PostgreSQL 16/main from Ubuntu packages
```

Production Compose maps `host.docker.internal` to Docker's real host gateway.
That mapping cannot point at a containerized simulated host. This local Compose
therefore overrides the name only inside application-style test containers with
an explicit hosts entry targeting the predictable `postgres-host` address:

```yaml
extra_hosts:
  - 'host.docker.internal:172.31.250.10'
```

`verify.sh` checks the resolution from `db-verifier`; it does not merely assume
the mapping works. Connections originate from the dedicated bridge subnet, so
the restricted `pg_hba.conf` rules are exercised by real TCP connections.

## Local credentials

Copying the example is optional because Compose provides the same public local
defaults:

```bash
cp .env.example .env
```

The `.env` file is ignored locally. These values are intentionally public test
credentials and must never be reused in staging or production:

```text
ZITADEL_DB_PASSWORD=local-zitadel-db-password
OPENFGA_DB_PASSWORD=local-openfga-db-password
```

The entrypoint passes them to `psql` variables; passwords are not embedded in
the SQL script.

Roles and passwords are created only during the first bootstrap of the data
volume. Changing either password in `.env` afterward does not rotate the
password already stored by PostgreSQL. To apply different bootstrap credentials,
recreate both simulation volumes:

```bash
docker compose down -v
docker compose up -d --build --wait
./verify.sh
```

## Build, start, and verify

```bash
cd local/production-like/components/postgres
docker compose config
docker compose build
docker compose up -d --wait
./verify.sh
```

If the local Docker installation lacks Buildx, use the classic builder:

```bash
DOCKER_BUILDKIT=0 docker compose build
```

PostgreSQL is also published to the workstation at `127.0.0.1:15432` for
diagnostics. Application verification deliberately uses
`host.docker.internal:5432` from `db-verifier`, not this published port.

## Persistence and complete reset

Container recreation preserves both the Ubuntu cluster data and configuration:

```bash
docker compose down
docker compose up -d --wait
./verify.sh
```

Remove both volumes to repeat the complete `pg_createcluster` bootstrap:

```bash
docker compose down -v
docker compose up -d --build --wait
./verify.sh
```

## Demonstrating the `pg_hba.conf` boundary

The application TCP connections succeed only because
`/etc/postgresql/16/main/pg_hba.conf` permits the simulation subnet for the
specific database/user combinations. To demonstrate the failure mode in a
disposable run, change the subnet in the generated rule to a non-matching one,
reset with `docker compose down -v`, and start again. `./verify.sh` will fail on
the first password-authenticated application connection. Restore the rule and
reset the volumes afterward.

## What Docker cannot reproduce exactly

- systemd as PID 1 and Ubuntu service boot ordering;
- the VPS firewall and external network policy;
- the real host kernel, sysctls, resource limits, storage, and I/O behavior;
- Plesk and Plesk-managed TLS;
- the literal Docker bridge-to-kernel-host boundary;
- the production PostgreSQL major version, which is not recorded in this repo;
- production credentials, data volume, extensions, load, backups, and upgrade
  history.

A future VM-based simulation would mainly be justified for systemd behavior,
host firewall rules, kernel/network boundaries, filesystem ownership across
real host users, and Plesk-adjacent host integration. Those concerns are
intentionally outside this Docker-only simulation.
