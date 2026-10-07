# cdcf-infra — Catholic Digital Commons Foundation umbrella infrastructure

Shared production infrastructure for the five CDCF umbrella properties:

- **cdcf-website** — [`CatholicOS/cdcf-website`](https://github.com/CatholicOS/cdcf-website)
- **LiturgicalCalendarAPI** — [`Liturgical-Calendar/LiturgicalCalendarAPI`](https://github.com/Liturgical-Calendar/LiturgicalCalendarAPI)
- **BibleGet API** — [`BibleGet-I-O/endpoint`](https://github.com/BibleGet-I-O/endpoint)
- **OntoKit API** — [`CatholicOS/ontokit-api`](https://github.com/CatholicOS/ontokit-api)
- **Martyrology API** — [`CatholicOS/martyrology-api`](https://github.com/CatholicOS/martyrology-api)

This repo contains **only infrastructure** — no application code. Each property's app lives in its own repo and consumes the shared services configured here.

## What's here

| Path | Purpose |
| --- | --- |
| [`auth/`](./auth/) | Zitadel (identity) at `auth.catholicdigitalcommons.org` + OpenFGA (relationship authz) at `authz.catholicdigitalcommons.org` |
| [`local/`](./local/) | Disposable Docker environments for fast development, isolated boundary tests, and production-like integration checks |

Future sibling directories may be added for other shared services (e.g. `metrics/`, `logs/`) as the umbrella grows.

## Local Docker environments

[`local/`](./local/) provides a fast development stack and a more detailed
production-like assembly for validating PostgreSQL, Zitadel, Login V2, OpenFGA
and nginx changes before they reach the VPS. Hybrid scenarios can isolate either
the PostgreSQL or nginx boundary.

Everything under `local/` remains a Docker simulation. Even the production-like
environment does not reproduce Plesk, managed TLS, Let's Encrypt, the VPS kernel,
firewall, permissions, secrets or production data. A successful local check is
useful evidence, but it is not a substitute for production-specific review.

Files under `local/` are intentionally outside `auth/**` and are therefore not
selected by the production VPS synchronization workflow. See
[`local/README.md`](./local/README.md) for the available modes and commands.

## Architecture

See the architecture choice Discussion in the cdcf-website repo: <https://github.com/CatholicOS/cdcf-website/discussions/98>.

The deployment runs on the existing cdcf-website Plesk VPS via the Plesk Docker extension. Plesk terminates TLS on the new `auth.*` and `authz.*` subdomains via Let's Encrypt; container services bind to `127.0.0.1` and are reverse-proxied by Plesk's nginx.

**Pinned architecture (see [`auth/README.md`](./auth/README.md) for full rationale):**

- Single Zitadel instance, one Org per property (`CDCF`, `LiturgicalCalendar`, `BibleGet`, `OntoKit`, `Martyrology`).
- A shared Zitadel Login V2 service is routed with the Zitadel backend through
  the internal nginx proxy.
- Shared OpenFGA, with its own database on the host's native PostgreSQL.
- **No containerized databases.** Both Zitadel and OpenFGA persist to the host Postgres (the same instance other VPS services already use). One Postgres to back up, patch, monitor.
- Repo is cloned to `/opt/cdcf-auth/` on the VPS — see [`auth/README.md`](./auth/README.md#canonical-vps-layout) for the full path table.
- Phase 1 wiring: LiturgicalCalendarAPI, CDCF Website, and Martyrology (API + frontend OIDC client). BibleGet and OntoKit Orgs remain pre-provisioned stubs.
