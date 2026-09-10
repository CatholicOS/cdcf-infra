# Full integration Compose overrides

These overrides connect the standalone components under
`local/production-like/components` into the complete environment defined by
`local/production-like/compose.yaml`.

They contain only integration-specific dependencies and network attachments.
Service images, commands, environment variables, healthchecks, volumes and build
instructions remain owned by the component Compose files.

The files are applied through Compose `include` path lists:

```yaml
include:
  - path:
      - ./components/postgres/compose.yaml
      - ./overrides/postgres.yaml
  - path:
      - ./components/applications/compose.yaml
      - ./overrides/applications.yaml
  - path:
      - ./components/nginx/compose.yaml
      - ./overrides/nginx.yaml
```

## `postgres.yaml`

- gives the database network the integration-specific name
  `cdcf-integration-database`;
- places the standalone `db-verifier` service behind the optional
  `component-verification` profile so it is not started during normal full-stack
  operation.

The PostgreSQL host remains attached only to the database network.

## `applications.yaml`

- makes Zitadel and the OpenFGA migration wait for healthy PostgreSQL;
- attaches Zitadel, OpenFGA and its migration to both the application and
  database networks;
- attaches Login V2 only to the application network;
- gives the application network the integration-specific name
  `cdcf-integration-application`.

The application containers retain their explicit
`host.docker.internal:172.31.250.10` mapping. Their database connections still
exercise the restricted PostgreSQL simulation subnet.

## `nginx.yaml`

- makes nginx wait for healthy Zitadel and Login V2 services;
- replaces its standalone external-network attachment with the integration
  application network.

nginx is not attached to the database network and cannot reach PostgreSQL
directly.

## Why `!override` is used

The component Compose files define the networks required when each component is
run independently. During full integration those attachments must be replaced,
not appended. Compose's `!override` YAML tag ensures the final network list is
exactly the one declared by the integration override.

Without replacement, a service could remain connected to a stale external
standalone network, making the full environment depend on another Compose
project or weakening the intended network boundary.

## Validation

Validate the merged model from the repository root:

```bash
docker compose -f local/production-like/compose.yaml config
```

The hybrid scenarios use their own overrides under `scenarios/overrides`; they
must not import these full-integration overrides unless they intentionally want
the `cdcf-integration-*` network names and complete-stack dependencies.
