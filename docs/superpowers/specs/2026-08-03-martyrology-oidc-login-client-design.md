# Martyrology OIDC login client — design

**Date:** 2026-08-03
**Status:** Approved, not yet implemented
**Closes:** `CatholicOS/martyrology-api` issue #26 — *No OIDC client exists for
human login*
**Repos touched:** `cdcf-infra` (provisioning), `martyrology-frontend` (sign-in).
**Repos NOT touched:** `martyrology-api`.

## Problem

No human being can obtain a token for the Martyrology API.

The `MartyrologyAPI` Zitadel project contains exactly one app — `MartyrologyAPI
Backend`, an API-type app with `API_AUTH_METHOD_TYPE_BASIC`. That app is a token
*validator*: the API uses its `client_id`/`client_secret` to call
`/oauth/v2/introspect`. It has no grant types and no redirect URIs, so it cannot
perform an authorization-code flow. Zitadel issues Personal Access Tokens only
to machine users, so there is no fallback for a human either.

v0.2.0 shipped a working role gate and grant endpoint, and
`priest@johnromanodorazio.com` holds the `admin` role plus a `superuser` tuple —
but that user cannot authenticate. The licensing gate is live in its deny
direction only: anonymous callers correctly receive redacted text for restricted
editions, and nobody can currently reach the allow direction except by
temporarily borrowing a machine user's credentials.

This gap predates v0.2.0. The project never had a user-facing client; it only
became visible once there was something for an authenticated user to do.

## Verified facts

Established 2026-08-03 by reading the repos and the provisioning script.

| Fact | Value |
|---|---|
| Frontend | `martyrology-frontend`, Next.js 16 + React 19, live at `https://romanmartyrology.com` |
| Frontend already proxies server-side | Yes — `app/api/mr/[...path]/route.ts` fetches `API_BASE`; the browser calls same-origin `/api/mr/...` via `lib/api.ts:10` |
| CORS on `martyrology-api` | **None configured** — no `CORSMiddleware`, no `allow_origins`, anywhere in `src/` |
| Staging environment | None, for either the frontend or the API |
| LitCal's registered URIs | Production + staging only, no localhost — `auth/setup-zitadel.sh:309-312` |
| LitCal's local development | A separate full stack (Postgres, Zitadel, OpenFGA, API) in `LiturgicalCalendarFrontend/docker-compose.yml`, provisioned by its own `scripts/setup-zitadel.sh` |
| Martyrology's local stack | Does not exist |
| Sibling precedent | `cdcf-website` runs `next-auth@5.0.0-beta.31` on `next@^16.2.9` against this same Zitadel instance |
| Confidential Web app helper | `create_oidc_web_app` in `auth/setup-zitadel.sh` already parameterises auth method and dev mode |
| Restricted editions | Three 2004 editions, `martyrology-api` `config.py:13-16` |
| Licensing check | `texts_allowed()` requires an identity **and** an OpenFGA `can_read_texts` relation — `licensing.py:12-17` |
| Deployed env precedence | A real env var set in the Plesk Node extension wins; the shipped `.next/standalone/.env` fills in when absent |

## Decisions

### D1 — Confidential Web app, not a PKCE public client

The frontend already runs a backend-for-frontend. Adding a bearer token to the
existing server-side proxy is an addition to that architecture; a browser-held
token is a partial rewrite of it.

Concretely, the confidential client:

- Requires **no CORS work on `martyrology-api`**, which currently has none. A
  public client would need allowed origins, `Authorization` in allowed headers,
  and preflight handling — new surface area on the API purely for the
  frontend's benefit.
- Keeps the access token out of the browser. This matters more here than in a
  typical app: a token grants both curation writes and unredacted text for the
  licensed 2004 editions, so exfiltration via XSS is a contractual problem, not
  only a security one.
- Refreshes server-side. Zitadel is on a different origin, so browser-side
  silent renew via a hidden iframe is blocked by third-party-cookie policy in
  Safari and Chrome; a public client would have to keep a refresh token in the
  browser to avoid logging a curator out mid-edit.
- Preserves server rendering for authenticated views. Server Components can read
  the session; they cannot read a browser-held token.

**Cost, accepted:** a `client_secret` must reach the deployed app's environment,
and Zitadel emits it exactly once at creation. `create_oidc_web_app`'s
"app already exists" branch returns an empty secret because `ListApplications`
does not return secrets, so recovery means regenerating in the console. This is
already-solved friction — `_emit_cdcf_app` carries the same caveat.

**Rejected:** PKCE public client (`do_provision_litcal_frontend`'s shape). Its
genuine advantage — no secret to store or rotate — does not outweigh adding CORS
to the API and undoing the proxy in exchange for a weaker token posture.

### D2 — The app lives in the existing `MartyrologyAPI` project

Not a new project. `create_project` already enables `projectRoleAssertion`, so a
token issued to an app inside the project carries
`urn:zitadel:iam:org:project:384518610174869507:roles` with no
`urn:zitadel:iam:org:project:id:...:aud` scope required. This is how
LiturgicalCalendar is arranged. Resolves open question 3 in the issue.

### D3 — One app: production only. No localhost client in production Zitadel

**Revised 2026-08-03**, after review. This section originally specified two apps,
production plus a localhost dev client, on the CDCF Website precedent. That was
the weaker of the two precedents available.

`LITCAL_FRONTEND_URLS` (`auth/setup-zitadel.sh:309-312`) registers only
`https://litcal.johnromanodorazio.com` and
`https://litcal-staging.johnromanodorazio.com`. No localhost. LiturgicalCalendar
does local development against an entirely separate Zitadel — Postgres, Zitadel,
OpenFGA and the API in `LiturgicalCalendarFrontend/docker-compose.yml`, with its
own `scripts/setup-zitadel.sh` provisioning that instance's project, roles and
OIDC apps.

CDCF Website does register `http://localhost:3000` as a `devMode=true` client in
production Zitadel. Martyrology follows LitCal instead: **production Zitadel
carries production URIs only.**

Consequence, accepted: there is no local sign-in for `martyrology-frontend` until
a local stack exists. That stack is a separate design — see Out of scope.

The gate in §6 does not depend on a dev client. A manual authorization-code flow
can use the production redirect URI: sign in, get bounced to
`https://romanmartyrology.com/api/auth/callback/zitadel`, which 404s while
nothing is deployed there, and read the `code` from the address bar.

### D4 — Auth.js v5, not hand-rolled OIDC

`next-auth@5.0.0-beta.31` pinned to the exact version `cdcf-website` runs. The
usual objection to a beta dependency — unknown behaviour on this Next major — is
already answered by a sibling repo running it in production on `next@^16.2.9`
against this same issuer. Hand-rolling with `openid-client` would mean owning
state/PKCE/CSRF handling, cookie encryption, and refresh rotation for no gain.

## 1. Scope

### What changes

- `cdcf-infra`: one new provisioning function and action; handoff documentation.
- `martyrology-frontend`: Auth.js v5, a session-aware proxy, a sign-in control,
  one added smoke-test assertion.

### What does not change

**`martyrology-api` receives no code changes.** Worth stating plainly, because
the issue is filed there. The API already derives identity solely from the
`Authorization: Bearer` header (`auth.py`, bearer parsing near line 120) and
already gates restricted text through OpenFGA. Both work. The gap was only that
no client could mint a user token.

**Anonymous access is preserved.** Signing in is additive. An unauthenticated
visitor still browses, still receives `text: null` with
`metadata.access = "restricted-texts"` for the three 2004 editions, and still
sees `EulogyView.tsx`'s redaction fallback. Signing in is what makes the same
request return real text.

## 2. Zitadel provisioning — `cdcf-infra/auth/setup-zitadel.sh`

A new `do_provision_martyrology_frontend`, registered as the
`--provision-martyrology-frontend` action in the `main` dispatch `case`.
Structurally a copy of `do_provision_cdcf_website` / `_emit_cdcf_app`.

New constants alongside the existing Martyrology block:

```bash
MARTYROLOGY_FRONTEND_APP_NAME="Martyrology Frontend"
MARTYROLOGY_FRONTEND_URLS=("https://romanmartyrology.com")
MARTYROLOGY_FRONTEND_CALLBACK_PATH="/api/auth/callback/zitadel"
```

One app, via the existing `create_oidc_web_app` with no changes to that helper:

| | Production |
|---|---|
| App name | `Martyrology Frontend` |
| Origin | `https://romanmartyrology.com` |
| `devMode` | `false` |
| Auth method | `OIDC_AUTH_METHOD_TYPE_POST` |
| Callback | `/api/auth/callback/zitadel` |

`_emit_martyrology_frontend_app` keeps its `dev_mode` parameter even though only
`false` is passed today — it mirrors `_emit_cdcf_app`, and the local-stack design
may reuse the helper against a local Zitadel.

The function resolves the org via `find_org_id "$MARTYROLOGY_ORG_NAME"` and the
project via `find_project_id`, failing with a clear message if
`--provision-martyrology` has not been run — matching how
`do_provision_litcal_frontend` guards its own prerequisite.

Handoff values are appended to `auth/handoffs/martyrology.md` alongside the
existing API-app block, including the standard one-time-secret warning and the
console path for rotation.

## 3. Frontend sign-in — `martyrology-frontend`

Four pieces.

**`auth.ts`** — Zitadel OIDC provider, scopes `openid profile email
offline_access`. JWT session strategy: `access_token`, `refresh_token`, and
`expires_at` live in the Auth.js encrypted httpOnly cookie, never in
browser-readable storage. The `jwt` callback refreshes when the access token has
expired.

**`app/api/auth/[...nextauth]/route.ts`** — the Auth.js route handlers.

**`app/api/mr/[...path]/route.ts`** — the one substantive edit to existing code.
Today the proxy forwards only an `accept` header. It gains: read the session;
if a valid access token is present, add `Authorization: Bearer <token>`;
otherwise proxy exactly as it does now. Every existing call site through
`lib/api.ts` continues to work untouched — the behavioural difference lives
entirely in what the API chooses to return.

**Header sign-in / sign-out control**, showing the signed-in identity. No other
UI.

### Acceptance criterion

Signed in as `priest@johnromanodorazio.com` — who holds the `admin` role and the
`superuser` tuple — a `martyrologium_romanum_2004` eulogy renders real text
instead of the redaction fallback. Signed out, the fallback returns.

## 4. Secrets and deployment

The deploy workflow writes `.next/standalone/.env` containing `API_BASE` from
`vars.API_BASE`, and its own comments record the precedence rule: a real
environment variable set in the Plesk Node extension wins, and the file fills in
when absent. That gives a clean split — and the workflow itself notes that
`cat .env`-style poking at the vhost is possible, which is precisely why secrets
must not travel in the tarball.

**Secrets — set once by hand**, in Plesk → Domains → romanmartyrology.com →
Node.js → Custom environment variables:

- `AUTH_SECRET`
- `AUTH_ZITADEL_SECRET`

**Non-secret configuration — shipped via the existing `.env` mechanism**, from
GitHub `vars`, exactly as `API_BASE` is today:

- `AUTH_ZITADEL_ISSUER`
- `AUTH_URL` — must equal `vars.SITE_URL`; a mismatch silently breaks the
  callback.

The deploy workflow's existing smoke-test step gains one assertion:
`GET $SITE_URL/api/auth/providers` must list the `zitadel` provider. This
verifies that the manually-set secrets actually landed, without CI ever holding
them. Without it, a misconfigured sign-in deploys green and fails only when
someone first tries to log in.

## 5. Testing

`vitest` is already configured in the frontend. The proxy route gets unit tests
covering the three branches that matter:

1. No session → no `Authorization` header, behaviour identical to today.
2. Valid session → `Authorization: Bearer` attached to the upstream fetch.
3. Expired access token → refresh path taken before the upstream call.

The third is where this kind of code rots silently, so it is tested explicitly
rather than left to manual observation.

The provisioning function gets an idempotency re-run.
`create_oidc_web_app`'s "app exists" branch syncs redirect URIs and returns an
empty secret; that path is exercised deliberately here rather than discovered
during a future re-provision.

Manual end-to-end is the acceptance criterion in §3, run in both directions.

## 6. Sequencing and risks

### The one unverified assumption

**That `martyrology-api` accepts a token minted by a different app in the same
project.** The API introspects using the *API app's* `client_id`/`client_secret`;
the token would be issued to the *frontend app*. Same project, so it should
introspect `active` and carry the roles claim — but nothing has exercised this.
Every other element of this design is a variation on something already running
in production.

This dictates the order of work:

1. Provision the production app.
2. Complete one manual authorization-code flow using the production redirect URI.
   Nothing is deployed at `https://romanmartyrology.com/api/auth/callback/zitadel`
   yet, so the browser lands on a 404 with the `code` in the address bar.
3. `curl` the API with the resulting token against a restricted 2004 edition.

If that returns unredacted text, the design is proven end to end and everything
after it is assembly. If it does not, we find out before any frontend code is
written. Cheap first milestone, and it retires the only real unknown.

### Lesser risks

- **One-time secret emit.** Unrecoverable; the already-exists branch returns
  empty, so rotation means the Zitadel console. Documented in the handoff, same
  as the API app.
- **Token lifetimes.** Zitadel defaults are inherited, not tuned. If a curator is
  logged out too aggressively, that is a follow-up, not a blocker.
- **Plesk Node custom environment variables.** Documented in the frontend's
  deployment design; the UI pane has not been personally confirmed on that host.

### Explicitly not a risk

The Zitadel Management API fallback that LiturgicalCalendar needed exists because
**JWT-profile service accounts** receive no roles claim. This design is human
login via authorization code, which is the path that works. PAT-authenticated
machine users also receive roles, as verified during v0.2.0 work.

## Out of scope

- **Curation writes.** The Phase B write UI (`PUT`/`PATCH`/`DELETE` against the
  curation endpoints) is deliberately deferred; the frontend MVP design already
  reserved it, and it warrants its own design cycle.
- **A CLI or loopback client** for terminal token acquisition. Considered and
  set aside; if scripted curation is wanted later, a machine user with a PAT
  works today and needs no new client.
- **A Martyrology local development stack.** Following LitCal (D3) means local
  sign-in requires a local Zitadel rather than a localhost client in production
  Zitadel. That stack — Postgres, Zitadel, OpenFGA, `martyrology-api` and
  `martyrology-frontend` in a compose file, with its own provisioning script —
  is its own design cycle, mirroring
  `LiturgicalCalendarFrontend/docker-compose.yml`. Until it exists there is no
  local sign-in, which affects how §3's frontend work can be verified; see the
  implementation plan for the current sequencing.
- **Any change to `martyrology-api`.**
