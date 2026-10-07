# Production-like integration scripts

These scripts validate and manage the complete environment defined by
`local/production-like/compose.yaml`. They are not intended for `local/dev` or
the hybrid scenarios.

Each script resolves the parent `production-like` directory automatically, so it
can be invoked from the repository root or from another working directory.

## `verify.sh`

Runs the nominal end-to-end verification after the complete environment has
started:

```bash
cd local/production-like
docker compose up -d --build --wait
./scripts/verify.sh
```

It checks:

- health of PostgreSQL, Zitadel, Login V2, OpenFGA and nginx;
- successful completion of the OpenFGA migration;
- the `host.docker.internal` mappings used by Zitadel and OpenFGA;
- PostgreSQL connections through the restricted simulation subnet;
- creation and consumption of the Login V2 PAT;
- Docker DNS and direct upstream connectivity from nginx;
- Zitadel and Login V2 routes through nginx;
- the expected `http://localhost:8090` OIDC issuer;
- authenticated access to the OpenFGA API.

The script is read-only with respect to persistent application data, although
its HTTP requests may create short-lived session or response data.

## `failure-tests.sh`

Exercises recoverable dependency failures:

```bash
cd local/production-like
./scripts/failure-tests.sh
```

It temporarily stops PostgreSQL and confirms that an OpenFGA database operation
fails. It then temporarily stops Login V2 and confirms that its nginx route fails
while the Zitadel backend route remains available.

An exit trap starts the stack again if the test exits early. At the end, the
script runs `verify.sh` to confirm that the complete environment recovered.
Because services are deliberately interrupted, do not run this script against
an environment being used by someone else.

## `reset.sh`

Removes the complete production-like Compose project and its named volumes:

```bash
cd local/production-like
./scripts/reset.sh
```

This deletes only resources owned by the `cdcf-integration` Compose project, but
it permanently removes its local PostgreSQL data, configuration and Zitadel PAT
volume. The operation is intended for disposable local data and allows the next
start to exercise a genuine first boot:

```bash
docker compose up -d --build --wait
./scripts/verify.sh
```

Do not use this reset script for `local/dev`, a hybrid scenario, production, or
an unrelated Compose project.

## Component-specific checks

The standalone components retain their own verification scripts:

- `components/postgres/verify.sh` checks the PostgreSQL host simulation;
- `components/applications/verify.sh` checks Zitadel, Login V2 and OpenFGA;
- `components/nginx/verify.sh` checks nginx against the development application
  stack.

Those scripts assume their respective standalone Compose project and should not
be substituted for the full integration verification described above.
