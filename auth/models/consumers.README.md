# `consumers.json`

Registry of which consumers depend on which store in `auth/models/`, and
where each consumer's declared expectations file lives. Read by
`auth/validate-expectations.sh`; see that script's header for the
expectations schema.

JSON has no comment syntax, so this note lives beside the registry instead
of inside it.

**The registry starts empty on purpose.** An empty array is not a stand-in
for "not yet gotten to" — the validator treats it as a genuine pass (there
are no declared expectations to contradict) and says so explicitly, rather
than silently exiting 0. A fabricated entry pointing at a file that does not
exist would instead make every model-touching PR fail on a fetch error,
which is worse than not enforcing anything yet.

Consumers are added here only once they have actually published an
expectations file at the URL being registered — not before. Currently
pending:

- **LiturgicalCalendarAPI** — depends on the `LiturgicalCalendar` store.
  Its expectations file (`authz/openfga-expectations.json` in that repo) is
  Task 8 of `docs/superpowers/plans/2026-08-04-openfga-1182-upgrade.md`,
  which is itself blocked on an unmerged PR as of this writing. Once that
  file exists and is merged to `development`, add:

  ```json
  {
    "consumer": "LiturgicalCalendarAPI",
    "store": "LiturgicalCalendar",
    "expectations_url": "https://raw.githubusercontent.com/Liturgical-Calendar/LiturgicalCalendarAPI/development/authz/openfga-expectations.json"
  }
  ```

- **Martyrology** (`martyrology-api`) — deliberately absent until that repo
  declares its own expectations file. An empty contract is honest; a
  fabricated one is not.
