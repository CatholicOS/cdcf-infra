# `consumers.json`

Registry of which consumers depend on which store in `auth/models/`, and
where each consumer's declared expectations file lives. Read by
`auth/validate-expectations.sh`; see that script's header for the
expectations schema.

JSON has no comment syntax, so this note lives beside the registry instead
of inside it.

**Consumers are added here only once they have actually published an
expectations file at the URL being registered — not before.** An entry
pointing at a file that does not yet exist makes every model-touching PR
fail on a fetch error (exit 2), which is worse than not enforcing that
consumer yet. The empty registry the validator started with was a genuine
pass, not a stand-in for "not yet gotten to": with nothing declared there is
nothing to contradict, and the validator says so explicitly rather than
silently exiting 0.

Registered:

- **LiturgicalCalendarAPI** — depends on the `LiturgicalCalendar` store,
  declaring `authz/openfga-expectations.json` on that repo's `development`
  branch. Registered once Liturgical-Calendar/LiturgicalCalendarAPI#757
  merged that file; before then the fetch would have failed. This is Task 8
  of `docs/superpowers/plans/2026-08-04-openfga-1182-upgrade.md`.

  Because the URL tracks `development` rather than a tag or commit, the
  contract this repo enforces is whatever that branch says *now*. A consumer
  can therefore tighten its own expectations and turn this repo's CI red
  without any change landing here — which is the intended direction (the
  consumer owns its contract), but it does mean a red `validate-models` run
  on `main` is not necessarily caused by the commit under test.

Pending:

- **Martyrology** (`martyrology-api`) — deliberately absent until that repo
  declares its own expectations file. An empty contract is honest; a
  fabricated one is not.
