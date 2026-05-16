# Credential handoff docs

One markdown file per umbrella property that consumes the shared auth stack. Each handoff records the **non-secret** values the property's repo needs to point its prod env at the shared infrastructure.

**Never put secrets in handoff docs.** Client secrets, preshared keys, and PATs are delivered out-of-band (encrypted message, password manager share, etc.).

## File convention

`handoffs/<property-slug>.md` — slug matches the Zitadel Org name, lowercased and hyphenated (e.g. `liturgicalcalendar.md`, `bibleget.md`).

## Template

```markdown
# <Property name> — auth handoff

## Zitadel

- Issuer: `https://auth.catholicdigitalcommons.org`
- Org name: `<OrgName>`
- Project ID: `<digits>`
- OIDC app type: <web | api>
- Client ID: `<digits@projectslug>`
- Client secret: **out-of-band**
- Roles defined: `<role_key>` (description), …
- Callback URLs registered: `<url>`, …

## OpenFGA (if applicable)

- API URL: `https://authz.catholicdigitalcommons.org`
- Store ID: `<id>`
- Authorization model ID: `<id>`
- Preshared key: **out-of-band**

## Consumer integration

- Repo: `<owner>/<repo>`
- Env vars to set in the property's prod env:
  - `ZITADEL_ISSUER=...`
  - `ZITADEL_CLIENT_ID=...`
  - `ZITADEL_CLIENT_SECRET=...` (out-of-band)
  - `OPENFGA_API_URL=...`
  - `OPENFGA_STORE_ID=...`
  - `OPENFGA_MODEL_ID=...`
  - `OPENFGA_PRESHARED_KEY=...` (out-of-band)
```
