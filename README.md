# cdcf-infra — Catholic Digital Commons Foundation umbrella infrastructure

Shared production infrastructure for the four CDCF umbrella properties:

- **cdcf-website** — [`CatholicOS/cdcf-website`](https://github.com/CatholicOS/cdcf-website)
- **LiturgicalCalendarAPI** — [`Liturgical-Calendar/LiturgicalCalendarAPI`](https://github.com/Liturgical-Calendar/LiturgicalCalendarAPI)
- **BibleGet API** — [`BibleGet-I-O/endpoint`](https://github.com/BibleGet-I-O/endpoint)
- **OntoKit API** — [`CatholicOS/ontokit-api`](https://github.com/CatholicOS/ontokit-api)

This repo contains **only infrastructure** — no application code. Each property's app lives in its own repo and consumes the shared services configured here.

## What's here

| Path | Purpose |
| --- | --- |
| [`auth/`](./auth/) | Zitadel (identity) at `auth.catholicdigitalcommons.org` + OpenFGA (relationship authz) at `authz.catholicdigitalcommons.org` |

Future sibling directories may be added for other shared services (e.g. `metrics/`, `logs/`) as the umbrella grows.

## Architecture

See the architecture choice Discussion in the cdcf-website repo: <https://github.com/CatholicOS/cdcf-website/discussions/98>.

The deployment runs on the existing cdcf-website Plesk VPS via the Plesk Docker extension. Plesk terminates TLS on the new `auth.*` and `authz.*` subdomains via Let's Encrypt; container services bind to `127.0.0.1` and are reverse-proxied by Plesk's nginx.

**Pinned architecture (see [`auth/README.md`](./auth/README.md) for full rationale):**

- Single Zitadel instance, one Org per property (`CDCF`, `LiturgicalCalendar`, `BibleGet`, `OntoKit`).
- No `zitadel-login` v2 UI service — each property implements its own login UI by calling Zitadel APIs.
- Shared OpenFGA, with its own database on the host's native PostgreSQL.
- **No containerized databases.** Both Zitadel and OpenFGA persist to the host Postgres (the same instance other VPS services already use). One Postgres to back up, patch, monitor.
- Repo is cloned to `/opt/cdcf-auth/` on the VPS — see [`auth/README.md`](./auth/README.md#canonical-vps-layout) for the full path table.
- Phase 1 wiring: LiturgicalCalendarAPI only (the only consumer already client-ready). Other Orgs are pre-provisioned stubs.
