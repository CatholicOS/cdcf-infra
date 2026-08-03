# Martyrology OIDC Login Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a human sign in to the Martyrology API as themselves, so a licensed reader receives unredacted restricted texts instead of the anonymous redaction fallback.

**Architecture:** Two confidential OIDC Web apps are provisioned in the existing `MartyrologyAPI` Zitadel project by `cdcf-infra/auth/setup-zitadel.sh`. `martyrology-frontend` gains Auth.js v5, which keeps the access token in an encrypted httpOnly cookie; its existing server-side proxy at `app/api/mr/[...path]/route.ts` attaches that token as a bearer header on the upstream call. The browser never holds a token and `martyrology-api` is not modified.

**Tech Stack:** Bash + Zitadel Management API v2 (`cdcf-infra`); Next.js 16 App Router, React 19, TypeScript, Auth.js v5 (`next-auth@5.0.0-beta.31`), Vitest + Testing Library (`martyrology-frontend`).

**Spec:** `docs/superpowers/specs/2026-08-03-martyrology-oidc-login-client-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- **`martyrology-api` receives no changes.** No CORS, no new endpoints, no auth code. If a task appears to require one, stop and escalate — it means the design is wrong.
- **The anonymous request path must stay behaviourally identical.** An unauthenticated visitor sends the same upstream request as today, with only an `accept` header. Signing in is purely additive.
- **`next-auth` is pinned to exactly `5.0.0-beta.31`** — the version `cdcf-website` runs in production against this same Zitadel issuer. Do not use `^` or `latest`; the whole justification for a beta dependency is that this exact version is proven here.
- **Node `>=24`** (`martyrology-frontend/package.json` `engines`).
- **All commits are GPG-signed** (`git commit -S`). Never bypass signing; if pinentry blocks, pause and let the user unlock.
- **Zitadel app name, redirect URI and callback path are exact strings.** `Martyrology Frontend`, `https://romanmartyrology.com`, `/api/auth/callback/zitadel`. The callback path is determined by Auth.js's provider id (`zitadel`) — changing one without the other breaks sign-in with an opaque Zitadel error.
- **No localhost client in production Zitadel.** Revised 2026-08-03: this plan originally provisioned a `devMode=true` localhost app on the CDCF Website precedent. `LITCAL_FRONTEND_URLS` registers production and staging only, and LitCal develops locally against a separate Zitadel in its own compose stack. Martyrology follows LitCal. See the spec's D3.
- **The app goes in the existing `MartyrologyAPI` project.** Never create a new project; the roles claim depends on this.
- **Secrets never enter git or the deploy tarball.** `AUTH_SECRET` and `AUTH_ZITADEL_SECRET` are set by hand in Plesk's Node environment pane only.

## Branches

- `cdcf-infra`: `feat/martyrology-frontend-oidc-client` (already created; the design doc is committed there).
- `martyrology-frontend`: create `feat/oidc-sign-in` at the start of Task 3.

## File Structure

**`cdcf-infra`**

| File | Responsibility |
|---|---|
| `auth/setup-zitadel.sh` (modify) | Add `_emit_martyrology_frontend_app` + `do_provision_martyrology_frontend`, constants, and CLI wiring |
| `auth/handoffs/martyrology.md` (modify) | Record the provisioned client IDs, the manual Plesk secret step, and the verification evidence |

**`martyrology-frontend`**

| File | Responsibility |
|---|---|
| `lib/zitadel-token.ts` (create) | Pure token-lifecycle logic: expiry check + refresh-grant exchange. No Auth.js imports, so it is trivially testable |
| `lib/proxy-headers.ts` (create) | Build the upstream header map from an optional access token. One responsibility, one function |
| `auth.ts` (create) | Auth.js configuration; wires the Zitadel provider to `lib/zitadel-token.ts` |
| `types/next-auth.d.ts` (create) | Module augmentation for the JWT's token fields and the session's `error`. The access token is declared on the JWT only, never on the Session |
| `app/api/auth/[...nextauth]/route.ts` (create) | Auth.js route handlers |
| `app/api/mr/[...path]/route.ts` (modify) | Attach the bearer token; stays thin by delegating to `lib/proxy-headers.ts` |
| `components/AuthStatusView.tsx` (create) | Presentational sign-in/sign-out control — a client component, so it is testable without async-server-component machinery |
| `components/AuthStatus.tsx` (create) | Thin async server wrapper that reads the session and renders `AuthStatusView` |
| `components/SiteHeader.tsx` (create) | Site header containing `AuthStatus` |
| `app/layout.tsx` (modify) | Render `SiteHeader` |
| `.github/workflows/deploy.yml` (modify) | Ship non-secret auth config; assert sign-in is configured before declaring the deploy green |

**Why the split:** the two genuinely testable pieces of logic (token refresh, header construction) are extracted into `lib/` as pure functions. Auth.js configuration and Next route handlers are thin wiring around them. This keeps tests out of `app/`, where Next's router would otherwise try to interpret test files as routes.

---

### Task 1: Provision the production OIDC Web app

> **Revised 2026-08-03, after implementation.** This task originally created two
> apps, production plus a `devMode=true` localhost client. The localhost client
> was dropped — see Global Constraints. The steps below are kept as a record of
> what was built; the amendment commit removes `MARTYROLOGY_FRONTEND_APP_NAME_DEV`,
> `MARTYROLOGY_FRONTEND_DEV_URLS`, and the second
> `_emit_martyrology_frontend_app` call, and corrects the `usage()` line.
> `_emit_martyrology_frontend_app` keeps its `dev_mode` parameter for the
> local-stack design.

**Files:**
- Modify: `cdcf-infra/auth/setup-zitadel.sh` — constants near line 744 (after `MARTYROLOGY_API_APP_NAME`), new functions before `# --- main ---`, CLI wiring at lines 73-83 (usage), 92-107 (arg parsing), 820-828 (dispatch)

**Interfaces:**
- Consumes: `create_oidc_web_app "$project_id" "$name" "$redirect_uris_json" "$post_logout_uris_json" "$auth_method_type" "$dev_mode"` → prints `app_id|client_id|client_secret`; `find_org_id`, `find_project_id`, `log`, `ok`, `warn`, `err`
- Produces: the `--provision-martyrology-frontend` action, and the production Zitadel app whose `client_id`/`client_secret` Task 2 and Task 6 consume

All work happens in `cd /home/johnrdorazio/development/CatholicOS_org/cdcf-infra`.

- [ ] **Step 1: Add the constants**

Insert immediately after the `MARTYROLOGY_API_APP_NAME="MartyrologyAPI Backend"` line:

```bash
# --- Martyrology Frontend (OIDC login client) -----------------------------
#
# Two confidential Web apps in the SAME MartyrologyAPI project as the API
# validator app. Same project means create_project's projectRoleAssertion puts
# urn:zitadel:iam:org:project:<id>:roles into the token with no :aud scope
# requested — which is why these are not a project of their own.
#
# Production and dev are separate apps so that the secret on a developer's
# machine is never the production secret, and so the production client never
# accepts an HTTP redirect URI (devMode=false rejects them outright).
MARTYROLOGY_FRONTEND_APP_NAME="Martyrology Frontend"
MARTYROLOGY_FRONTEND_APP_NAME_DEV="Martyrology Frontend (Dev)"
MARTYROLOGY_FRONTEND_URLS=("https://romanmartyrology.com")
MARTYROLOGY_FRONTEND_DEV_URLS=("http://localhost:3000")
# Auth.js v5 mounts its callback at /api/auth/callback/<provider-id>, and the
# built-in Zitadel provider's id is "zitadel". This string and the frontend's
# provider id must change together or sign-in fails at the redirect.
MARTYROLOGY_FRONTEND_CALLBACK_PATH="/api/auth/callback/zitadel"
```

- [ ] **Step 2: Add the emit helper and the provisioning function**

Insert immediately before the `# --- main ---` separator:

```bash
# Create one Martyrology Frontend OIDC app and emit its handoff block.
# Internal helper for do_provision_martyrology_frontend — mirrors
# _emit_cdcf_app, which solves the identical prod/non-prod problem.
#
# Args:
#   $1 project_id
#   $2 app_name
#   $3 dev_mode      "true" | "false"
#   $4 label         handoff section label
#   $5..  origin URLs, one per arg
_emit_martyrology_frontend_app() {
    local project_id="$1" app_name="$2" dev_mode="$3" label="$4"
    shift 4
    local origins=("$@")

    local redirect_uris_json post_logout_uris_json
    redirect_uris_json=$(printf '%s\n' "${origins[@]}" \
        | jq -R --arg cb "$MARTYROLOGY_FRONTEND_CALLBACK_PATH" '. + $cb' | jq -s '.')
    post_logout_uris_json=$(printf '%s\n' "${origins[@]}" | jq -R '.' | jq -s '.')

    # Confidential client with client_secret_post (Auth.js v5 server-side).
    local app_info app_id client_id client_secret
    app_info=$(create_oidc_web_app "$project_id" "$app_name" \
        "$redirect_uris_json" "$post_logout_uris_json" \
        "OIDC_AUTH_METHOD_TYPE_POST" "$dev_mode")
    IFS='|' read -r app_id client_id client_secret <<<"$app_info"

    echo
    echo "${B}=== Martyrology Frontend handoff values — $label ===${N}"
    echo "ZITADEL_APP_ID=$app_id"
    echo "AUTH_ZITADEL_ID=$client_id          # ← client_id"
    if [[ -n "$client_secret" ]]; then
        echo "AUTH_ZITADEL_SECRET=$client_secret   # ← client_secret (one-time emit)"
        warn "The client secret above is printed ONCE and is UNRECOVERABLE."
        warn "  Put it into the Plesk Node environment NOW, before this shell scrolls."
    else
        warn "Client secret not emitted (app already existed; ListApplications"
        warn "  does not return secrets). Rotate via the Zitadel console:"
        warn "  $MARTYROLOGY_ORG_NAME Org → Projects → $MARTYROLOGY_PROJECT_NAME →"
        warn "  Apps → $app_name → Regenerate Client Secret"
    fi
    echo "# Registered redirect URIs:"
    for url in "${origins[@]}"; do echo "#   $url$MARTYROLOGY_FRONTEND_CALLBACK_PATH"; done
    echo "# Registered post-logout URIs:"
    for url in "${origins[@]}"; do echo "#   $url"; done
    echo "# devMode=$dev_mode"
}

do_provision_martyrology_frontend() {
    log "Provisioning Martyrology Frontend OIDC apps"
    local org_id
    org_id=$(find_org_id "$MARTYROLOGY_ORG_NAME")
    if [[ -z "$org_id" ]]; then
        err "$MARTYROLOGY_ORG_NAME Org not found. Run --create-orgs (or --create-org $MARTYROLOGY_ORG_NAME) first."
        exit 15
    fi
    local project_id
    project_id=$(find_project_id "$org_id" "$MARTYROLOGY_PROJECT_NAME")
    if [[ -z "$project_id" ]]; then
        err "Project $MARTYROLOGY_PROJECT_NAME not found. Run --provision-martyrology first."
        exit 16
    fi
    ok "Found $MARTYROLOGY_PROJECT_NAME Project: $project_id"

    echo
    echo "${B}=== Martyrology Frontend shared values ===${N}"
    echo "AUTH_ZITADEL_ISSUER=$ZITADEL_ISSUER"
    echo "ZITADEL_PROJECT_ID=$project_id"

    _emit_martyrology_frontend_app "$project_id" "$MARTYROLOGY_FRONTEND_APP_NAME" \
        "false" "Production" "${MARTYROLOGY_FRONTEND_URLS[@]}"
    _emit_martyrology_frontend_app "$project_id" "$MARTYROLOGY_FRONTEND_APP_NAME_DEV" \
        "true" "Dev (localhost)" "${MARTYROLOGY_FRONTEND_DEV_URLS[@]}"
    echo
}
```

Exit codes 15 and 16 are the next free values — 10 through 14 are already taken by `create_oidc_web_app`, `do_provision_litcal_frontend`, `do_provision_cdcf_website`, and `do_provision_martyrology`.

- [ ] **Step 3: Wire the CLI — usage text**

In `usage()`, add a line after the `--provision-martyrology` line:

```text
  --provision-martyrology-frontend
                              Provision Martyrology Frontend OIDC apps (Web/client_secret_post, prod + dev)
```

and change `--all`'s description from `Above six in dependency order` to `Above seven in dependency order`.

- [ ] **Step 4: Wire the CLI — argument parsing and dispatch**

In the `while` loop, after the `--provision-martyrology)` case:

```bash
        --provision-martyrology-frontend) ACTIONS+=("provision-martyrology-frontend"); shift ;;
```

Append `"provision-martyrology-frontend"` to the end of the `--all` array so it runs after `provision-martyrology`, which creates the project it depends on:

```bash
        --all)                       ACTIONS+=("rename-bootstrap-admin" "create-orgs" "provision-litcal" "provision-litcal-frontend" "provision-cdcf-website" "provision-martyrology" "provision-martyrology-frontend"); shift ;;
```

In the dispatch `case`, after the `provision-martyrology)` line:

```bash
        provision-martyrology-frontend) do_provision_martyrology_frontend ;;
```

- [ ] **Step 5: Verify the script parses and lints**

```bash
bash -n auth/setup-zitadel.sh
shellcheck auth/setup-zitadel.sh
```

Expected: `bash -n` silent. `shellcheck` reports nothing new — compare against `git stash && shellcheck auth/setup-zitadel.sh` output if unsure that a finding is pre-existing.

- [ ] **Step 6: Verify the action is reachable and guarded**

```bash
./auth/setup-zitadel.sh --help 2>&1 | grep -A1 'provision-martyrology-frontend'
```

Expected: the new usage line appears.

```bash
./auth/setup-zitadel.sh --target production --provision-martyrology-frontend --nonsense 2>&1 | head -3
```

Expected: `Unknown arg: --nonsense` followed by usage — confirming the new action does not swallow the following token.

- [ ] **Step 7: Commit**

```bash
git add auth/setup-zitadel.sh
git commit -S -m "Add Martyrology Frontend OIDC login apps to the provisioner

Two confidential Web apps (production + localhost dev) in the existing
MartyrologyAPI project, so the roles claim needs no :aud scope. Mirrors
_emit_cdcf_app, which solves the same prod/non-prod secret-separation
problem for the CDCF website."
```

---

### Task 2: Verify the API accepts a sibling-app token — GATE

**Files:** none modified. This task produces evidence, not code.

**Interfaces:**
- Consumes: the `--provision-martyrology-frontend` action from Task 1
- Produces: the production app's `client_id` and `client_secret`, and a go/no-go answer for the entire rest of the plan

**This is a gate.** The design rests on one unverified assumption: that `martyrology-api`, which introspects using the *API app's* credentials, accepts a token issued to a *different app in the same project*. Everything else is a variation on something already in production. If this fails, stop and escalate — do not start Task 3.

### Which machine runs what

Only Step 1 runs on the VPS. `setup-zitadel.sh` reaches Zitadel over loopback
(`ZITADEL_INTERNAL_URL` defaults to `http://127.0.0.1:8080`), reads the PAT from
`/opt/cdcf-auth/runtime/zitadel-data/automation-user.pat`, and sources
`.env.production`, which is deliberately kept `ubuntu:ubuntu` mode `0600` on the
VPS and never leaves it. Every later step talks only to public HTTPS endpoints
and to a browser on your own machine.

| Steps | Machine | Why |
|---|---|---|
| 1 | **VPS**, in `/opt/cdcf-auth` | Loopback Zitadel, PAT file, `.env.production` |
| 2-8 | **Local** | Issuer, token endpoint and API are all public HTTPS; the browser is yours |

Carry the client secret from Step 1's VPS output into your local shell for Step 2.

**The flow uses the production redirect URI.** There is no localhost client (see
Global Constraints). Nothing is deployed at
`https://romanmartyrology.com/api/auth/callback/zitadel` yet, so after signing in
the browser lands on a 404 with the authorization code in the address bar — which
is all this verification needs.

**Prerequisite:** Task 1's commit must be on `main` before Step 1 can run. The
`sync-to-vps.yml` workflow fires on push to `main` under `auth/**` and pulls
`--ff-only origin main` into `/opt/cdcf-auth`; a feature branch never reaches the
VPS. Merge the Task 1 PR first. The new action is inert until invoked, so merging
it ahead of this gate carries no risk.

- [ ] **Step 1: Run the provisioner against production — ON THE VPS**

```bash
ssh <your-account>@<the VPS running Zitadel>
cd /opt/cdcf-auth
git log --oneline -1          # confirm the sync landed Task 1's commit
./auth/setup-zitadel.sh --target production --provision-martyrology-frontend
```

Do not run this as the `cdcfinfra-deploy` sync user — it has no shell access and
cannot read `.env.production` by design.

Expected: one handoff block, `Production`, with `AUTH_ZITADEL_ID` and a one-time `AUTH_ZITADEL_SECRET`.

**Capture the secret now.** It is unrecoverable. Put it somewhere safe before the shell scrolls.

- [ ] **Step 2: Build an authorization URL — LOCAL, and every step from here on**

```bash
export ISSUER=https://auth.catholicdigitalcommons.org
export CLIENT_ID='<AUTH_ZITADEL_ID from the Production block>'
export CLIENT_SECRET='<AUTH_ZITADEL_SECRET from the Production block>'
export REDIRECT='https://romanmartyrology.com/api/auth/callback/zitadel'

python3 - <<'PY'
import os, urllib.parse
print(os.environ["ISSUER"] + "/oauth/v2/authorize?" + urllib.parse.urlencode({
    "client_id": os.environ["CLIENT_ID"],
    "redirect_uri": os.environ["REDIRECT"],
    "response_type": "code",
    "scope": "openid profile email offline_access",
    "state": "manual-verification",
}))
PY
```

- [ ] **Step 3: Complete the flow in a browser**

Open the printed URL, sign in as `priest@johnromanodorazio.com`. Zitadel redirects to `https://romanmartyrology.com/api/auth/callback/zitadel?code=...&state=manual-verification`.

No Auth.js route is deployed there yet, so the browser shows a 404. **That is expected** — the authorization code is in the address bar. Copy its value.

```bash
export CODE='<the code query parameter>'
```

- [ ] **Step 4: Exchange the code for tokens**

```bash
curl -sS -X POST "$ISSUER/oauth/v2/token" \
  -d grant_type=authorization_code \
  -d "code=$CODE" \
  -d "redirect_uri=$REDIRECT" \
  -d "client_id=$CLIENT_ID" \
  -d "client_secret=$CLIENT_SECRET" | tee /tmp/martyrology-token.json | jq 'keys'
```

Expected: `["access_token","expires_in","id_token","refresh_token","scope","token_type"]`.

If this returns `invalid_client`, the app's `authMethodType` and the request form disagree. Retry with HTTP Basic instead of form fields to identify which:
`curl -sS -X POST "$ISSUER/oauth/v2/token" -u "$CLIENT_ID:$CLIENT_SECRET" -d grant_type=authorization_code -d "code=$CODE" -d "redirect_uri=$REDIRECT"`. Record which one works — Task 3 Step 6 needs the answer.

- [ ] **Step 5: Confirm the roles claim is present**

```bash
export ACCESS_TOKEN=$(jq -r .access_token /tmp/martyrology-token.json)
python3 -c "import sys,base64,json; p=sys.argv[1].split('.')[1]; p+='='*(-len(p)%4); print(json.dumps(json.loads(base64.urlsafe_b64decode(p)),indent=2))" "$ACCESS_TOKEN"
```

Expected: a claim `urn:zitadel:iam:org:project:384518610174869507:roles` containing `admin`.

If it is absent, the in-project assumption (design D2) is wrong and the client needs the `urn:zitadel:iam:org:project:id:384518610174869507:aud` scope. Stop and escalate.

- [ ] **Step 6: The decisive check — call the API with the token**

```bash
curl -sS -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://api.romanmartyrology.com/api/v1/elogia/edition/martyrologium_romanum_2004/01/01" \
  | jq '{access: .metadata.access, first_text: (.elogia[0].text // null)}'
```

Expected: `first_text` is a non-null string — real elogium text.

- [ ] **Step 7: Negative control**

```bash
curl -sS "https://api.romanmartyrology.com/api/v1/elogia/edition/martyrologium_romanum_2004/01/01" \
  | jq '{access: .metadata.access, first_text: (.elogia[0].text // null)}'
```

Expected: `access` is `"restricted-texts"` and `first_text` is `null`.

Both results together prove the whole chain: authorization code → introspection → roles claim → role gate → OpenFGA → unredacted text. Record both outputs; Task 7 puts them in the handoff.

- [ ] **Step 8: Clean up the token file**

```bash
shred -u /tmp/martyrology-token.json 2>/dev/null || rm -f /tmp/martyrology-token.json
```

---

> ## Tasks 3-7 are stale pending the local-stack design
>
> **Added 2026-08-03.** These tasks were written assuming a localhost Zitadel
> client existed, so several of their verification steps cannot be performed as
> written. Do not execute them until they have been revised.
>
> Specifically affected:
>
> - **Task 3 Step 9** — the `.env.local` block uses the Dev app's credentials and
>   runs a live sign-in against `localhost:3000`. No such client exists.
> - **Task 5 Step 8** — the browser acceptance sequence runs against
>   `localhost:3000` while signed in.
> - **Task 6 Step 2** — instructs generating an `AUTH_SECRET` distinct from "the
>   dev value".
> - **Task 7 Step 1** — the handoff table lists both apps.
> - **Task 7 Step 3** — the README section documents local sign-in with the Dev
>   client.
> - **Task 7 Step 5** — the issue-close comment claims two apps exist and that
>   "both apps live in the MartyrologyAPI project". Do not post it as written.
>
> The code and unit tests in Tasks 3, 4 and 5 are unaffected — they mock the
> session and never contact Zitadel. Only the live verification steps are.
>
> Two ways forward, to be settled when the local-stack design lands: verify
> against the local stack once it exists, or verify against production after
> deploying and drop local sign-in from the plan entirely.

### Task 3: Auth.js configuration and token refresh

**Files:**
- Create: `martyrology-frontend/lib/zitadel-token.ts`
- Create: `martyrology-frontend/lib/__tests__/zitadel-token.test.ts`
- Create: `martyrology-frontend/auth.ts`
- Create: `martyrology-frontend/lib/__tests__/auth-callbacks.test.ts`
- Create: `martyrology-frontend/types/next-auth.d.ts`
- Create: `martyrology-frontend/app/api/auth/[...nextauth]/route.ts`
- Modify: `martyrology-frontend/package.json`

**Interfaces:**
- Consumes: nothing from earlier tasks (Task 2 was verification only)
- Produces:
  - `isExpired(expiresAt: number | undefined, nowMs: number): boolean`
  - `refreshAccessToken(token: ZitadelToken, fetchImpl?: typeof fetch): Promise<ZitadelToken>`
  - `type ZitadelToken = { access_token?: string; refresh_token?: string; expires_at?: number; error?: string }` (`expires_at` is **seconds** since epoch, matching Auth.js's `account.expires_at`)
  - `auth()`, `handlers`, `signIn`, `signOut` exported from `@/auth`
  - `callbacks` exported from `@/auth` — the `jwt` and `session` callbacks as a plain object, so the leak guard can call `session` directly. Exported for testability, not for reuse; nothing else should import it.
  - `session.error?: string` on the Session; `access_token`, `refresh_token`, `expires_at`, `error` on the JWT. The access token is never placed on the Session — Auth.js serves the Session as the body of `GET /api/auth/session`.

All work happens in `cd /home/johnrdorazio/development/CatholicOS_org/martyrology-frontend`.

- [ ] **Step 1: Branch and install the dependency**

```bash
git checkout -b feat/oidc-sign-in
npm install --save-exact next-auth@5.0.0-beta.31
```

Verify the pin is exact (no `^`):

```bash
jq -r '.dependencies["next-auth"]' package.json
```

Expected: `5.0.0-beta.31`

- [ ] **Step 2: Write the failing test**

Create `lib/__tests__/zitadel-token.test.ts`:

```ts
import { describe, it, expect, vi } from "vitest";
import { isExpired, refreshAccessToken } from "@/lib/zitadel-token";

describe("isExpired", () => {
  it("treats a missing expiry as expired", () => {
    expect(isExpired(undefined, 1_000_000)).toBe(true);
  });

  it("is false while the token still has more than the 60s skew left", () => {
    // expires_at is in SECONDS; now is in MILLISECONDS.
    expect(isExpired(2_000, 1_000_000)).toBe(false);
  });

  it("is true inside the 60s skew window, before the wall-clock expiry", () => {
    // 30s of real life left, which is inside the skew, so refresh early.
    expect(isExpired(1_030, 1_000_000)).toBe(true);
  });
});

describe("refreshAccessToken", () => {
  const base = { access_token: "old", refresh_token: "r1", expires_at: 1_000 };

  it("posts the refresh grant with client credentials and returns new values", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ access_token: "new", refresh_token: "r2", expires_in: 3600 }), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    );

    const result = await refreshAccessToken(base, fetchImpl as never);

    expect(result.access_token).toBe("new");
    expect(result.refresh_token).toBe("r2");
    expect(result.error).toBeUndefined();

    const [url, init] = fetchImpl.mock.calls[0];
    expect(url).toContain("/oauth/v2/token");
    const body = (init as RequestInit).body as URLSearchParams;
    expect(body.get("grant_type")).toBe("refresh_token");
    expect(body.get("refresh_token")).toBe("r1");
  });

  it("keeps the previous refresh token when the response omits a new one", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ access_token: "new", expires_in: 3600 }), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    );

    const result = await refreshAccessToken(base, fetchImpl as never);

    expect(result.refresh_token).toBe("r1");
  });

  it("flags RefreshAccessTokenError on a non-2xx response rather than throwing", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(new Response("{}", { status: 400 }));

    const result = await refreshAccessToken(base, fetchImpl as never);

    expect(result.error).toBe("RefreshAccessTokenError");
  });

  it("flags RefreshAccessTokenError when there is no refresh token to use", async () => {
    const fetchImpl = vi.fn();

    const result = await refreshAccessToken({ access_token: "old" }, fetchImpl as never);

    expect(result.error).toBe("RefreshAccessTokenError");
    expect(fetchImpl).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
npx vitest run lib/__tests__/zitadel-token.test.ts
```

Expected: FAIL — cannot resolve `@/lib/zitadel-token`.

- [ ] **Step 4: Write the implementation**

Create `lib/zitadel-token.ts`:

```ts
// Token-lifecycle logic, kept free of Auth.js imports so it can be unit
// tested without booting a provider. auth.ts is the only consumer.

export type ZitadelToken = {
  access_token?: string;
  refresh_token?: string;
  /** Seconds since epoch, matching Auth.js's account.expires_at. */
  expires_at?: number;
  error?: string;
};

/**
 * Refresh 60s before the wall-clock expiry. Without the skew a token that
 * passes this check can still expire in flight, between the session read and
 * the upstream API call, which surfaces as a spurious 401 for the curator.
 */
const SKEW_SECONDS = 60;

export function isExpired(expiresAt: number | undefined, nowMs: number): boolean {
  if (expiresAt === undefined) return true;
  return expiresAt - SKEW_SECONDS <= Math.floor(nowMs / 1000);
}

export async function refreshAccessToken(
  token: ZitadelToken,
  fetchImpl: typeof fetch = fetch,
): Promise<ZitadelToken> {
  if (!token.refresh_token) {
    return { ...token, error: "RefreshAccessTokenError" };
  }

  const issuer = process.env.AUTH_ZITADEL_ISSUER ?? "";
  const body = new URLSearchParams({
    grant_type: "refresh_token",
    refresh_token: token.refresh_token,
    client_id: process.env.AUTH_ZITADEL_ID ?? "",
    client_secret: process.env.AUTH_ZITADEL_SECRET ?? "",
  });

  try {
    const res = await fetchImpl(`${issuer}/oauth/v2/token`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body,
    });
    if (!res.ok) return { ...token, error: "RefreshAccessTokenError" };

    const refreshed = (await res.json()) as {
      access_token: string;
      refresh_token?: string;
      expires_in: number;
    };

    return {
      access_token: refreshed.access_token,
      // Zitadel rotates refresh tokens, but not on every response. Keeping the
      // previous one when none is returned avoids logging the curator out.
      refresh_token: refreshed.refresh_token ?? token.refresh_token,
      expires_at: Math.floor(Date.now() / 1000) + refreshed.expires_in,
      error: undefined,
    };
  } catch {
    return { ...token, error: "RefreshAccessTokenError" };
  }
}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
npx vitest run lib/__tests__/zitadel-token.test.ts
```

Expected: PASS, 7 tests.

- [ ] **Step 6: Write the Auth.js configuration**

Create `auth.ts`:

```ts
import NextAuth from "next-auth";
import Zitadel from "next-auth/providers/zitadel";
import { isExpired, refreshAccessToken, type ZitadelToken } from "@/lib/zitadel-token";

// Exported so the callbacks can be unit tested without booting a provider.
// The test that matters asserts the access token never reaches the Session —
// see lib/__tests__/auth-callbacks.test.ts. Auth.js serves whatever the session
// callback returns as the body of GET /api/auth/session, so that property is a
// security boundary, not a style choice, and it needs a permanent guard.
export const callbacks = {
    async jwt({ token, account }) {
      // Initial sign-in: account is present exactly once.
      if (account) {
        return {
          ...token,
          access_token: account.access_token,
          refresh_token: account.refresh_token,
          expires_at: account.expires_at,
        };
      }
      const current = token as ZitadelToken;
      if (!isExpired(current.expires_at, Date.now())) return token;
      return { ...token, ...(await refreshAccessToken(current)) };
    },
    async session({ session, token }) {
      // NEVER put the access token here. Auth.js sets the session callback's
      // return value as the response body of GET /api/auth/session
      // (packages/core/src/lib/actions/session.ts: `response.body = newSession`),
      // so anything on the session is readable by the browser. Putting the
      // token here would hand out exactly what the BFF exists to withhold.
      // The proxy reads it from the JWT server-side instead — see Task 4.
      //
      // `error` is safe: it is a string like "RefreshAccessTokenError", and
      // the header needs it to tell the curator to sign in again.
      const current = token as ZitadelToken;
      session.error = current.error;
      return session;
    },
};

export const { handlers, auth, signIn, signOut } = NextAuth({
  providers: [
    Zitadel({
      issuer: process.env.AUTH_ZITADEL_ISSUER,
      clientId: process.env.AUTH_ZITADEL_ID,
      clientSecret: process.env.AUTH_ZITADEL_SECRET,
      // offline_access is what makes Zitadel return a refresh token; without
      // it the curator is logged out when the access token expires.
      authorization: { params: { scope: "openid profile email offline_access" } },
    }),
  ],
  // JWT strategy, not a database session: the tokens live in the encrypted
  // httpOnly cookie Auth.js already manages. Nothing here is readable by
  // browser JavaScript, which is the entire point of the BFF arrangement.
  session: { strategy: "jwt" },
  callbacks,
});
```

**Checkpoint — client authentication method.** The Auth.js provider and the Zitadel app must agree on how the client authenticates at the token endpoint. We provisioned `OIDC_AUTH_METHOD_TYPE_POST`, i.e. `client_secret_post` — credentials as form fields. Task 2 Step 4 established what the live app actually accepts. Two cases, and only one of them calls for an override:

- **Task 2 succeeded with form fields** (the expected result, matching `_POST`). The app is correct. Sign in at Step 9. If it fails with `invalid_client`, Auth.js is defaulting to HTTP Basic — *then* add `client: { token_endpoint_auth_method: "client_secret_post" }` to the `Zitadel({...})` call and retry.
- **Task 2 succeeded only with HTTP Basic.** The app is not really `_POST`, despite what we asked for. Do not paper over this by forcing `client_secret_post` in Auth.js — that would break the exchange. Reconcile the mismatch at its source: confirm what the app's `authMethodType` is in the Zitadel console and either correct the app or change the provisioner's constant so the two agree.

Either way, verify at Step 9 rather than assuming.

**Checkpoint — `getToken` and the `salt` argument.** Task 4's proxy calls
`getToken({ req, secret })` from `next-auth/jwt`. Auth.js v5 encrypts the session
cookie with a salt derived from the cookie name, and in some v5 betas `getToken`
requires `salt` explicitly rather than defaulting it. If `getToken` returns
`null` for a request that is definitely signed in, that is the cause: pass
`salt` matching the session cookie name — `authjs.session-token`, or
`__Secure-authjs.session-token` when the cookie is secure. Confirm which by
reading the cookie names in the browser's dev tools rather than guessing, since
the prefix depends on whether the deployment is HTTPS.

Note also that the v5 migration guide steers callers from `getToken` toward
`auth()`. That guidance does not apply here: `auth()` returns the Session, and
this design specifically requires a value the Session must not carry.

- [ ] **Step 6b: Write the leak guard — the test that matters most**

Create `lib/__tests__/auth-callbacks.test.ts`. This is a permanent guard on a
security boundary, not a coverage exercise: if a later change routes the token
back through the Session, Auth.js will publish it at `GET /api/auth/session`.

```ts
import { describe, it, expect } from "vitest";
import { callbacks } from "@/auth";

const token = {
  access_token: "SECRET-TOKEN",
  refresh_token: "SECRET-REFRESH",
  expires_at: 9_999_999_999,
  error: undefined,
};

describe("session callback", () => {
  it("never exposes the access or refresh token on the session", async () => {
    const session = await callbacks.session({
      session: { user: { email: "a@b.c" }, expires: "2099-01-01" },
      token,
    } as never);

    // Auth.js returns this object as the body of GET /api/auth/session.
    const serialized = JSON.stringify(session);
    expect(serialized).not.toContain("SECRET-TOKEN");
    expect(serialized).not.toContain("SECRET-REFRESH");
    expect(serialized).not.toContain("access_token");
    expect(serialized).not.toContain("accessToken");
  });

  it("does pass the refresh error through, which is not sensitive", async () => {
    const session = await callbacks.session({
      session: { user: { email: "a@b.c" }, expires: "2099-01-01" },
      token: { ...token, error: "RefreshAccessTokenError" },
    } as never);

    expect((session as { error?: string }).error).toBe("RefreshAccessTokenError");
  });
});
```

Asserting on the serialized form rather than on named properties is deliberate —
it catches the token arriving under any key, including one a future edit invents.

- [ ] **Step 6c: Run the guard**

```bash
npx vitest run lib/__tests__/auth-callbacks.test.ts
```

Expected: PASS, 2 tests. If importing `@/auth` fails for want of environment
variables, set the four `AUTH_*` values from `.env.local` in the test run — do
not weaken the test to avoid the import, since importing the real module is what
makes it a guard rather than a restatement.

- [ ] **Step 7: Add the type augmentation**

Create `types/next-auth.d.ts`:

```ts
import "next-auth";
import "next-auth/jwt";

declare module "next-auth" {
  interface Session {
    // Deliberately no accessToken — the session is browser-readable.
    error?: string;
  }
}

declare module "next-auth/jwt" {
  interface JWT {
    access_token?: string;
    refresh_token?: string;
    expires_at?: number;
    error?: string;
  }
}
```

- [ ] **Step 8: Add the route handlers**

Create `app/api/auth/[...nextauth]/route.ts`:

```ts
export { GET, POST } from "@/auth";
```

`@/auth` exports `handlers`, so re-export its members explicitly:

```ts
import { handlers } from "@/auth";

export const { GET, POST } = handlers;
```

Use the second form — the first only works if `auth.ts` re-exports `GET`/`POST` directly, which it does not.

- [ ] **Step 9: Verify types and a live local sign-in**

```bash
npx tsc --noEmit
npm run lint
```

Expected: both clean.

Create `.env.local` (already gitignored) using the **Dev** app values from Task 2:

```bash
AUTH_ZITADEL_ISSUER=https://auth.catholicdigitalcommons.org
AUTH_ZITADEL_ID=<Dev client_id>
AUTH_ZITADEL_SECRET=<Dev client_secret>
AUTH_SECRET=<output of: npx auth secret --raw, or openssl rand -base64 32>
AUTH_URL=http://localhost:3000
API_BASE=https://api.romanmartyrology.com
```

Then:

```bash
npm run dev
```

Visit `http://localhost:3000/api/auth/signin`, sign in as yourself, and confirm the redirect lands back on localhost without an Auth.js error page. Then:

```bash
curl -sS http://localhost:3000/api/auth/providers | jq .
```

Expected: an object containing a `zitadel` entry.

If sign-in fails with `invalid_client`, apply the `token_endpoint_auth_method` override from Step 6's checkpoint.

- [ ] **Step 10: Commit**

```bash
git add package.json package-lock.json auth.ts lib/zitadel-token.ts \
        lib/__tests__/zitadel-token.test.ts types/next-auth.d.ts \
        "app/api/auth/[...nextauth]/route.ts"
git commit -S -m "Add Auth.js v5 sign-in against Zitadel

Token lifecycle lives in lib/zitadel-token.ts as pure functions so the
refresh path is unit tested rather than discovered in production. Access and
refresh tokens stay in the encrypted httpOnly cookie; nothing reaches the
browser.

next-auth is pinned exactly to 5.0.0-beta.31, the version cdcf-website
already runs against this issuer."
```

---

### Task 4: Attach the bearer token in the proxy

**Files:**
- Create: `martyrology-frontend/lib/proxy-headers.ts`
- Create: `martyrology-frontend/lib/__tests__/proxy-headers.test.ts`
- Create: `martyrology-frontend/lib/__tests__/mr-route.test.ts`
- Modify: `martyrology-frontend/app/api/mr/[...path]/route.ts`

**Interfaces:**
- Consumes: `getToken` from `next-auth/jwt`, reading the JWT fields declared in `types/next-auth.d.ts` (Task 3). Deliberately **not** `auth()` — see the route's comment.
- Produces: `buildUpstreamHeaders(accessToken?: string | null): Record<string, string>`

- [ ] **Step 1: Write the failing header test**

Create `lib/__tests__/proxy-headers.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { buildUpstreamHeaders } from "@/lib/proxy-headers";

describe("buildUpstreamHeaders", () => {
  it("sends only accept when there is no token — the anonymous path is unchanged", () => {
    expect(buildUpstreamHeaders(undefined)).toEqual({ accept: "application/json" });
  });

  it("sends only accept when the token is null", () => {
    expect(buildUpstreamHeaders(null)).toEqual({ accept: "application/json" });
  });

  it("sends only accept when the token is an empty string", () => {
    expect(buildUpstreamHeaders("")).toEqual({ accept: "application/json" });
  });

  it("adds a bearer authorization header when a token is present", () => {
    expect(buildUpstreamHeaders("abc123")).toEqual({
      accept: "application/json",
      authorization: "Bearer abc123",
    });
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

```bash
npx vitest run lib/__tests__/proxy-headers.test.ts
```

Expected: FAIL — cannot resolve `@/lib/proxy-headers`.

- [ ] **Step 3: Write the implementation**

Create `lib/proxy-headers.ts`:

```ts
/**
 * Build the header map for the upstream API call.
 *
 * With no token this returns exactly what the proxy sent before sign-in
 * existed, which is what keeps anonymous browsing byte-identical: the API
 * redacts restricted editions for callers it cannot identify, and that
 * behaviour is a feature, not a fallback.
 */
export function buildUpstreamHeaders(accessToken?: string | null): Record<string, string> {
  const headers: Record<string, string> = { accept: "application/json" };
  if (accessToken) headers.authorization = `Bearer ${accessToken}`;
  return headers;
}
```

- [ ] **Step 4: Run it to verify it passes**

```bash
npx vitest run lib/__tests__/proxy-headers.test.ts
```

Expected: PASS, 4 tests.

- [ ] **Step 5: Write the failing route test**

Create `lib/__tests__/mr-route.test.ts`. It lives in `lib/__tests__/` rather than under `app/` so Next's router never sees a test file as a route:

```ts
import { describe, it, expect, vi, beforeEach } from "vitest";

// Mock the JWT reader, not the session. The route deliberately never calls
// auth() — see the comment in route.ts.
const authMock = vi.fn();
vi.mock("next-auth/jwt", () => ({ getToken: authMock }));

import { GET } from "@/app/api/mr/[...path]/route";

const ctx = (path: string[]) => ({ params: Promise.resolve({ path }) });
const req = (url: string) => ({ nextUrl: new URL(url) }) as never;

describe("/api/mr proxy", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    authMock.mockReset();
  });

  it("does not send an authorization header when signed out", async () => {
    authMock.mockResolvedValue(null);
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response("{}", { status: 200, headers: { "content-type": "application/json" } }),
    );

    await GET(req("http://localhost:3000/api/mr/editions"), ctx(["editions"]));

    const init = fetchSpy.mock.calls[0][1] as RequestInit;
    expect((init.headers as Record<string, string>).authorization).toBeUndefined();
  });

  it("forwards the session access token as a bearer header when signed in", async () => {
    authMock.mockResolvedValue({ access_token: "tok-123" });
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response("{}", { status: 200, headers: { "content-type": "application/json" } }),
    );

    await GET(req("http://localhost:3000/api/mr/editions"), ctx(["editions"]));

    const init = fetchSpy.mock.calls[0][1] as RequestInit;
    expect((init.headers as Record<string, string>).authorization).toBe("Bearer tok-123");
  });

  it("still proxies anonymously if the session lookup throws", async () => {
    authMock.mockRejectedValue(new Error("cannot decrypt session cookie"));
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response("{}", { status: 200, headers: { "content-type": "application/json" } }),
    );

    const res = await GET(req("http://localhost:3000/api/mr/editions"), ctx(["editions"]));

    expect(res.status).toBe(200);
    const init = fetchSpy.mock.calls[0][1] as RequestInit;
    expect((init.headers as Record<string, string>).authorization).toBeUndefined();
  });

  it("preserves the query string on the upstream URL", async () => {
    authMock.mockResolvedValue(null);
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response("{}", { status: 200, headers: { "content-type": "application/json" } }),
    );

    await GET(
      req("http://localhost:3000/api/mr/elogia?edition=x&locale=la"),
      ctx(["elogia"]),
    );

    expect(fetchSpy.mock.calls[0][0]).toContain("?edition=x&locale=la");
  });
});
```

The third test matters: a broken session store must degrade to anonymous browsing, not a 500 on every page for every visitor.

- [ ] **Step 6: Run it to verify it fails**

```bash
npx vitest run lib/__tests__/mr-route.test.ts
```

Expected: FAIL — the route sends no `authorization` header for the signed-in case.

- [ ] **Step 7: Modify the route**

Replace the whole body of `app/api/mr/[...path]/route.ts`:

```ts
import { NextRequest } from "next/server";
import { getToken } from "next-auth/jwt";
import { buildUpstreamHeaders } from "@/lib/proxy-headers";

const API_BASE = process.env.API_BASE ?? "http://localhost:8000";

export async function GET(req: NextRequest, ctx: { params: Promise<{ path: string[] }> }) {
  const { path } = await ctx.params;
  const qs = req.nextUrl.search; // includes leading "?" or ""
  const url = `${API_BASE}/api/v1/${path.map(encodeURIComponent).join("/")}${qs}`;

  // Read the token from the encrypted JWT, NOT from auth(). auth() returns the
  // Session, which Auth.js also serves as the body of GET /api/auth/session —
  // so a token routed through the session would be readable by the browser.
  // getToken decodes the cookie server-side and never leaves this process.
  //
  // A failure to read it must not take the site down for anonymous visitors,
  // who are the majority and who need no token at all.
  let accessToken: string | undefined;
  try {
    const token = await getToken({ req, secret: process.env.AUTH_SECRET });
    accessToken = typeof token?.access_token === "string" ? token.access_token : undefined;
  } catch {
    accessToken = undefined;
  }

  try {
    const upstream = await fetch(url, { headers: buildUpstreamHeaders(accessToken), cache: "no-store" });
    const body = await upstream.text();
    return new Response(body, {
      status: upstream.status,
      headers: { "content-type": upstream.headers.get("content-type") ?? "application/json" },
    });
  } catch {
    return new Response(JSON.stringify({ title: "API unreachable", detail: `Could not reach ${API_BASE}` }), {
      status: 502,
      headers: { "content-type": "application/json" },
    });
  }
}
```

- [ ] **Step 8: Run the full suite**

```bash
npm run test
npx tsc --noEmit
```

Expected: all tests pass, including the pre-existing `lib/__tests__/api.test.ts`, and types are clean.

- [ ] **Step 9: Commit**

```bash
git add lib/proxy-headers.ts lib/__tests__/proxy-headers.test.ts \
        lib/__tests__/mr-route.test.ts "app/api/mr/[...path]/route.ts"
git commit -S -m "Forward the session access token through the /api/mr proxy

Header construction is extracted so the anonymous path is asserted, not
assumed: with no token the upstream request is identical to what it was
before sign-in existed. A failing session lookup degrades to anonymous
rather than 500ing the site."
```

---

### Task 5: Sign-in control in the site header

**Files:**
- Create: `martyrology-frontend/components/AuthStatusView.tsx`
- Create: `martyrology-frontend/components/__tests__/AuthStatusView.test.tsx`
- Create: `martyrology-frontend/components/AuthStatus.tsx`
- Create: `martyrology-frontend/components/SiteHeader.tsx`
- Modify: `martyrology-frontend/app/layout.tsx`

**Interfaces:**
- Consumes: `auth`, `signIn`, `signOut` from `@/auth` (Task 3)
- Produces: `<SiteHeader />`, rendered by the root layout

- [ ] **Step 1: Write the failing view test**

Create `components/__tests__/AuthStatusView.test.tsx`:

```tsx
import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { AuthStatusView } from "@/components/AuthStatusView";

describe("AuthStatusView", () => {
  it("offers sign-in when there is no identity", () => {
    render(<AuthStatusView email={null} onSignIn={<button>Sign in</button>} onSignOut={<button>Sign out</button>} />);
    expect(screen.getByText("Sign in")).toBeInTheDocument();
    expect(screen.queryByText("Sign out")).not.toBeInTheDocument();
  });

  it("shows the identity and offers sign-out when signed in", () => {
    render(
      <AuthStatusView
        email="priest@johnromanodorazio.com"
        onSignIn={<button>Sign in</button>}
        onSignOut={<button>Sign out</button>}
      />,
    );
    expect(screen.getByText("priest@johnromanodorazio.com")).toBeInTheDocument();
    expect(screen.getByText("Sign out")).toBeInTheDocument();
    expect(screen.queryByText("Sign in")).not.toBeInTheDocument();
  });

  it("warns when the session carries a refresh error", () => {
    render(
      <AuthStatusView
        email="priest@johnromanodorazio.com"
        error="RefreshAccessTokenError"
        onSignIn={<button>Sign in</button>}
        onSignOut={<button>Sign out</button>}
      />,
    );
    expect(screen.getByRole("status")).toHaveTextContent("Session expired");
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

```bash
npx vitest run components/__tests__/AuthStatusView.test.tsx
```

Expected: FAIL — cannot resolve `@/components/AuthStatusView`.

- [ ] **Step 3: Write the view**

Create `components/AuthStatusView.tsx`:

```tsx
// Presentational only. The sign-in and sign-out controls are passed in as
// elements so this component has no dependency on Auth.js and can be
// rendered in a plain jsdom test.
export function AuthStatusView({
  email,
  error,
  onSignIn,
  onSignOut,
}: {
  email: string | null | undefined;
  error?: string;
  onSignIn: React.ReactNode;
  onSignOut: React.ReactNode;
}) {
  if (!email) return <div className="flex items-center gap-3">{onSignIn}</div>;

  return (
    <div className="flex items-center gap-3">
      {error ? (
        <span role="status" className="text-sm text-amber-700 dark:text-amber-400">
          Session expired — sign in again
        </span>
      ) : null}
      <span className="text-sm text-slate-600 dark:text-slate-400">{email}</span>
      {onSignOut}
    </div>
  );
}
```

- [ ] **Step 4: Run it to verify it passes**

```bash
npx vitest run components/__tests__/AuthStatusView.test.tsx
```

Expected: PASS, 3 tests.

- [ ] **Step 5: Write the server wrapper**

Create `components/AuthStatus.tsx`:

```tsx
import { auth, signIn, signOut } from "@/auth";
import { AuthStatusView } from "@/components/AuthStatusView";

const buttonClass =
  "rounded border border-slate-300 px-3 py-1 text-sm dark:border-slate-700";

export async function AuthStatus() {
  // Never let an auth backend problem blank the header on every page.
  let session = null;
  try {
    session = await auth();
  } catch {
    session = null;
  }

  const signInButton = (
    <form
      action={async () => {
        "use server";
        await signIn("zitadel");
      }}
    >
      <button type="submit" className={buttonClass}>
        Sign in
      </button>
    </form>
  );

  const signOutButton = (
    <form
      action={async () => {
        "use server";
        await signOut();
      }}
    >
      <button type="submit" className={buttonClass}>
        Sign out
      </button>
    </form>
  );

  return (
    <AuthStatusView
      email={session?.user?.email}
      error={session?.error}
      onSignIn={signInButton}
      onSignOut={signOutButton}
    />
  );
}
```

- [ ] **Step 6: Write the header**

Create `components/SiteHeader.tsx`:

```tsx
import Link from "next/link";
import { AuthStatus } from "@/components/AuthStatus";

export function SiteHeader() {
  return (
    <header className="border-b border-slate-200 dark:border-slate-800">
      <div className="mx-auto flex max-w-5xl items-center justify-between gap-4 p-4">
        <Link href="/" className="font-semibold">
          Martyrology Curation
        </Link>
        <AuthStatus />
      </div>
    </header>
  );
}
```

- [ ] **Step 7: Render it from the layout**

Modify `app/layout.tsx`:

```tsx
import "./globals.css";
import { SiteHeader } from "@/components/SiteHeader";

export const metadata = { title: "Martyrology Curation", description: "CRMEDR curation tool" };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className="min-h-screen bg-white text-slate-900 dark:bg-slate-950 dark:text-slate-100">
        <SiteHeader />
        {children}
      </body>
    </html>
  );
}
```

- [ ] **Step 8: Verify the acceptance criterion end to end**

```bash
npm run test
npx tsc --noEmit
npm run dev
```

With `.env.local` from Task 3 Step 9 still in place:

1. Open `http://localhost:3000` — the header shows **Sign in**.
2. Open `http://localhost:3000/compare`, select `martyrologium_romanum_2004`, and confirm `EulogyView` shows the redaction fallback.
3. Click **Sign in**, authenticate as `priest@johnromanodorazio.com`.
4. Header now shows the email and **Sign out**.
5. Return to the same 2004 elogium — **real text renders**.
6. Click **Sign out** — the redaction fallback returns.

This is the spec's acceptance criterion. If step 5 fails while Task 2 Step 6 passed, the problem is token plumbing in the proxy, not the design.

- [ ] **Step 9: Commit**

```bash
git add components/AuthStatusView.tsx components/AuthStatus.tsx \
        components/SiteHeader.tsx components/__tests__/AuthStatusView.test.tsx \
        app/layout.tsx
git commit -S -m "Add a sign-in control to the site header

Presentation is split from the Auth.js wiring so the three states — signed
out, signed in, refresh failed — are tested without an async server
component in jsdom. A failing session read renders the signed-out header
rather than breaking every page."
```

---

### Task 6: Ship auth configuration through the deploy

**Files:**
- Modify: `martyrology-frontend/.github/workflows/deploy.yml` — config-check step (~line 55-86), build step (~line 117-143), smoke-test step (~line 265-315)

**Interfaces:**
- Consumes: the **Production** app's `client_id`/`client_secret` from Task 2
- Produces: a deploy that fails loudly when sign-in is misconfigured

- [ ] **Step 1: Set the GitHub repository variable**

In `martyrology-frontend` → Settings → Secrets and variables → Actions → Variables:

- `AUTH_ZITADEL_ISSUER` = `https://auth.catholicdigitalcommons.org`
- `AUTH_ZITADEL_ID` = the `client_id` from Task 2 Step 1's `Production` handoff block

An OAuth client id is public by design, so it belongs with the variables rather
than the secrets — but Auth.js cannot build the provider without it. Omitting it
breaks sign-in exactly as omitting the secret would.

`AUTH_URL` is not a separate variable — it is derived from the existing `vars.SITE_URL` at build time, which guarantees the two cannot drift.

- [ ] **Step 2: Set the two secrets in Plesk, by hand**

Plesk → Domains → `romanmartyrology.com` → Node.js → **Custom environment variables**:

| Name | Value |
|---|---|
| `AUTH_SECRET` | output of `openssl rand -base64 32` (generate fresh; do not reuse the dev value) |
| `AUTH_ZITADEL_SECRET` | the **Production** `client_secret` from Task 2 Step 1 |

These deliberately do not travel through GitHub or the deploy tarball. The deploy workflow writes `.next/standalone/.env` into the vhost, and a real environment variable set here takes precedence over that file — so secrets stay out of a file that anything with read access to the vhost could print.

- [ ] **Step 3: Add the config preflight check**

In the "Validate deploy configuration" step, add `AUTH_ZITADEL_ISSUER` to its `env:` block:

```yaml
          AUTH_ZITADEL_ISSUER: ${{ vars.AUTH_ZITADEL_ISSUER }}
```

and add the assertion alongside the existing `API_BASE` and `SITE_URL` checks:

```bash
          [ -n "$AUTH_ZITADEL_ISSUER" ] || fail "vars.AUTH_ZITADEL_ISSUER is empty (e.g. https://auth.catholicdigitalcommons.org)"
          # The providers smoke check cannot detect a missing issuer or id —
          # it reads configuration and performs no discovery. This preflight
          # is the only thing standing between a blank var and a broken
          # sign-in that deploys green.
          [ -n "$AUTH_ZITADEL_ID" ]     || fail "vars.AUTH_ZITADEL_ID is empty (the client_id from the Martyrology Frontend handoff block)"
```

Extend the existing confirmation echo to mention it:

```bash
          echo "Deploy configuration OK. APP_DIR=$VPS_APP_DIR SITE_URL=$SITE_URL API_BASE=$API_BASE AUTH_ZITADEL_ISSUER=$AUTH_ZITADEL_ISSUER"
```

- [ ] **Step 4: Ship the non-secret auth config in the standalone .env**

Add `AUTH_ZITADEL_ISSUER` and `AUTH_ZITADEL_ID` to the build step's `env:` block, then replace the single-line `.env` write:

```bash
          printf 'API_BASE=%s\n' "$API_BASE" > .next/standalone/.env
```

with a grouped write:

```bash
          # Non-secret configuration only. AUTH_SECRET and AUTH_ZITADEL_SECRET
          # are set in the Plesk Node environment by hand and MUST NOT appear
          # here — a real env var wins over this file, and this file is
          # readable by anything that can read the vhost.
          {
            printf 'API_BASE=%s\n' "$API_BASE"
            printf 'AUTH_ZITADEL_ISSUER=%s\n' "$AUTH_ZITADEL_ISSUER"
            printf 'AUTH_ZITADEL_ID=%s\n' "$AUTH_ZITADEL_ID"
            printf 'AUTH_URL=%s\n' "$SITE_URL"
          } > .next/standalone/.env
```

`SITE_URL` is already in that step's environment; confirm it is listed in the step's `env:` block and add it if not.

- [ ] **Step 5: Add the sign-in smoke assertion**

In the "Smoke-test the deployed site" step, insert this **between** the home-page retry loop and the `/api/mr/editions` loop.

Placement is not cosmetic: the editions loop ends with `exit 0` on success, so anything appended after it never runs.

```bash
          # Provider-registration check only. It proves Auth.js booted and
          # registered the provider, which catches a missing AUTH_SECRET.
          # It does NOT validate AUTH_ZITADEL_ISSUER or AUTH_ZITADEL_ID: this
          # endpoint reports configuration and performs no OIDC discovery, so
          # a wrong issuer survives it. Those two are guarded by the preflight
          # above instead. It does NOT validate AUTH_ZITADEL_SECRET either —
          # the provider is built from config and advertised whether or not
          # the secret is right, because nothing exchanges a code here. A
          # wrong secret shows up as invalid_client during a real sign-in,
          # which is why the manual acceptance run is what proves it.
          PROV_FILE=$(mktemp)
          STATUS=$(curl -sS -o "$PROV_FILE" -w '%{http_code}' \
            --connect-timeout 10 --max-time 45 "$SITE_URL/api/auth/providers" || echo "000")
          if [ "$STATUS" != "200" ] || ! grep -q '"zitadel"' "$PROV_FILE"; then
            echo "::error::GET $SITE_URL/api/auth/providers returned $STATUS without a zitadel provider. Auth.js did not boot or did not register the provider — check AUTH_SECRET in Plesk → Domains → romanmartyrology.com → Node.js → Custom environment variables, then redeploy. Note this check reads configuration only: it cannot detect a wrong AUTH_ZITADEL_ISSUER, AUTH_ZITADEL_ID or AUTH_ZITADEL_SECRET. Those surface at sign-in, as a discovery failure or invalid_client."
            head -c 300 "$PROV_FILE"; echo
            exit 1
          fi
          echo "Auth providers: zitadel present"
```

- [ ] **Step 6: Verify the workflow is valid**

```bash
npx --yes yaml-lint .github/workflows/deploy.yml 2>/dev/null \
  || python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/deploy.yml')); print('YAML OK')"
```

Expected: `YAML OK`.

Confirm the new smoke block precedes the editions loop:

```bash
grep -n 'api/auth/providers\|api/mr/editions' .github/workflows/deploy.yml
```

Expected: the `api/auth/providers` line number is **lower** than the `api/mr/editions` line number.

- [ ] **Step 7: Commit and deploy**

```bash
git add .github/workflows/deploy.yml
git commit -S -m "Ship auth config and fail the deploy when sign-in is misconfigured

Non-secret auth config rides the existing standalone .env; the two secrets
stay in the Plesk Node environment, which takes precedence over that file.
The providers smoke check goes before the editions loop because that loop
exits 0 on success — anything after it is unreachable."
```

Open the PR, merge, and confirm the deploy run reaches `Auth providers: zitadel present`. Then sign in at `https://romanmartyrology.com` and re-run the Task 5 Step 8 acceptance sequence against production.

---

### Task 7: Document and close

**Files:**
- Modify: `cdcf-infra/auth/handoffs/martyrology.md`
- Modify: `martyrology-frontend/README.md`

**Interfaces:**
- Consumes: the verification output from Task 2, the client IDs from Task 2 Step 1

- [ ] **Step 1: Record the provisioned clients in the handoff**

Append to `cdcf-infra/auth/handoffs/martyrology.md`:

```markdown
## Human login — the frontend OIDC clients

Provisioned by `./setup-zitadel.sh --target production --provision-martyrology-frontend`.
Two confidential Web apps in the **existing `MartyrologyAPI` project** — not a
project of their own, because same-project membership is what puts
`urn:zitadel:iam:org:project:384518610174869507:roles` in the token without
requesting an `:aud` scope.

| App | Origin | devMode | Auth method |
|---|---|---|---|
| `Martyrology Frontend` | `https://romanmartyrology.com` | false | `client_secret_post` |
| `Martyrology Frontend (Dev)` | `http://localhost:3000` | true | `client_secret_post` |

Callback path on both: `/api/auth/callback/zitadel` — fixed by the Auth.js
provider id, so it cannot be changed on one side alone.

### Secrets are not in git and not in the deploy

`AUTH_SECRET` and `AUTH_ZITADEL_SECRET` are set by hand in Plesk → Domains →
romanmartyrology.com → Node.js → Custom environment variables. The deploy
writes `.next/standalone/.env` with non-secret values only; a real environment
variable takes precedence over that file.

Both client secrets were emitted once at creation and are unrecoverable. To
rotate: Martyrology Org → Projects → MartyrologyAPI → Apps → *app name* →
Regenerate Client Secret, then update the Plesk environment variable.

### Verified end to end

A user token minted by the frontend app **is** accepted by the API, which
introspects using the separate API app's credentials. Confirmed by
authorization-code flow as `priest@johnromanodorazio.com`:
`GET /api/v1/elogia/edition/martyrologium_romanum_2004/01/01` returns real text
with the bearer header and `metadata.access = "restricted-texts"` with
`text: null` without it. This was the design's one unverified assumption.
```

- [ ] **Step 2: Update the follow-ups list**

In the same file's "What's NOT provisioned here (follow-ups)" section, strike the human-login gap and note what remains:

```markdown
- ~~**No human can obtain a token**~~ **Done** — see "Human login — the frontend OIDC clients" above. Curation *writes* still have no UI; the frontend signs in and reads, and the Phase B authoring operations remain unbuilt.
```

- [ ] **Step 3: Document local development in the frontend README**

Add to `martyrology-frontend/README.md`:

```markdown
## Signing in locally

Local sign-in uses the `Martyrology Frontend (Dev)` Zitadel app, which is the
only one that accepts an `http://localhost:3000` redirect. Create `.env.local`
(gitignored):

    AUTH_ZITADEL_ISSUER=https://auth.catholicdigitalcommons.org
    AUTH_ZITADEL_ID=<Dev client_id>
    AUTH_ZITADEL_SECRET=<Dev client_secret>
    AUTH_SECRET=<openssl rand -base64 32>
    AUTH_URL=http://localhost:3000
    API_BASE=https://api.romanmartyrology.com

Credentials come from `cdcf-infra/auth/handoffs/martyrology.md`. Never use the
production client secret locally.

Signing in is additive: anonymous browsing works unchanged, and restricted
editions render redacted. Signing in as a user who holds the OpenFGA
`can_read_texts` relation is what makes their text appear.
```

- [ ] **Step 4: Commit both repos**

```bash
cd /home/johnrdorazio/development/CatholicOS_org/cdcf-infra
git add auth/handoffs/martyrology.md
git commit -S -m "Record the Martyrology frontend OIDC clients in the handoff"

cd /home/johnrdorazio/development/CatholicOS_org/martyrology-frontend
git add README.md
git commit -S -m "Document local sign-in against the dev Zitadel client"
```

- [ ] **Step 5: Close the issue**

```bash
gh issue close 26 --repo CatholicOS/martyrology-api --comment "Closed by the OIDC login client work.

Two confidential Web apps (\`Martyrology Frontend\`, \`Martyrology Frontend (Dev)\`) now exist in the MartyrologyAPI project, and martyrology-frontend signs in against them with Auth.js v5. The access token stays server-side and rides the existing /api/mr proxy, so martyrology-api needed no changes — no CORS, no new endpoints.

Answers to the open questions in this issue:

1. **Who is the client?** martyrology-frontend, the existing Next.js curation app at romanmartyrology.com. It already ran a server-side proxy, so a confidential Web app fit the architecture that was there.
2. **Does curation get a UI?** Yes, but reading only for now. Phase B authoring is still unbuilt and out of scope here.
3. **Audience.** Moot — both apps live in the MartyrologyAPI project, so the roles claim appears with no \`:aud\` scope requested. Verified against a live token.
4. **Service accounts.** Unchanged; a machine user with a PAT still works and needs no new client.

Verified end to end: signed in as a user holding \`can_read_texts\`, a 2004-edition elogium returns real text; signed out, the same request returns \`text: null\` with \`metadata.access = \"restricted-texts\"\`."
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| D1 confidential Web app | Task 1 (`OIDC_AUTH_METHOD_TYPE_POST`), Task 3 |
| D2 same project | Task 1 Step 1, verified Task 2 Step 5 |
| D3 one app, production only (revised) | Task 1 Steps 1-2, as amended |
| D4 Auth.js v5 pinned | Global Constraints, Task 3 Step 1 |
| §1 no `martyrology-api` changes | Global Constraints |
| §1 anonymous path preserved | Task 4 Steps 1, 3 (asserted, not assumed) |
| §2 provisioning function + CLI | Task 1 |
| §3 `auth.ts`, route handlers, proxy, header control | Tasks 3, 4, 5 |
| §3 acceptance criterion | Task 5 Step 8, re-run against production in Task 6 Step 7 |
| §4 secrets in Plesk, non-secrets in `.env` | Task 6 Steps 2, 4 |
| §4 `/api/auth/providers` smoke assertion | Task 6 Step 5 |
| §5 three proxy branches | Task 4 (no session, session) + Task 3 (expiry/refresh) |
| Access token never on the Session | Task 3 Steps 6b-6c — asserted on the serialized session, so any key name is caught |
| §5 provisioning idempotency re-run | Task 1 Step 6 exercises argument handling; the "app exists" branch is exercised the second time Task 2 Step 1 runs |
| §6 introspection assumption first | Task 2, gated |
| §6 one-time secret emit | Task 1 Step 2 warnings, Task 7 Step 1 rotation note |

**Deviation from the spec, deliberate:** §5 says the *proxy route* gets tests for all three branches including refresh. Refresh is tested at the `lib/zitadel-token.ts` layer instead (Task 3 Step 2), because refresh happens in the Auth.js `jwt` callback, not in the route — the route only ever sees an already-refreshed session. Both branches the route can actually observe are tested there, plus two the spec did not name: a throwing session lookup and query-string preservation.

**Placeholder scan:** no TBD/TODO; every code step carries the actual code; `<Dev client_id>`-style angle brackets appear only where a runtime secret must be pasted by the operator, and each is accompanied by where to get it.

**Type consistency:** `ZitadelToken` fields (`access_token`, `refresh_token`, `expires_at`, `error`) are used identically in `lib/zitadel-token.ts`, `auth.ts`, and the tests. `expires_at` is seconds everywhere, `nowMs` is milliseconds and only appears as an `isExpired` parameter. `access_token` is declared on the `JWT` interface in `types/next-auth.d.ts` and consumed in Task 4's route via `getToken` and in Task 4's test mock; it never appears on the `Session` interface. `buildUpstreamHeaders` has one signature across its definition, test, and call site.
