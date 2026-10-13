# PR #49 follow-up (2026-10-13)

- Claude's membership-event fix in `6cb9607`: independently verified using its
  real removal test plus new grant and visibility regression tests.
- Codex findings: project deletion, scope refresh, stale issue details,
  participation broadcasts, missing translations, and standalone router
  configuration are fixed in the accompanying patch.
- Complete suite after the portal reload and test-host fixes: **1,736 tests,
  zero failures**, with the PostgreSQL integration tests enabled.
- Final focused suite (`portal_live_test.exs`, `portal_access_test.exs`, and
  `portal_test.exs`): **97 tests, zero failures**. This includes the final
  participation-policy broadcast and core scope-dispatcher regression tests.
- `WITHOUT_STAFF=1 mix deps.get` followed by
  `WITHOUT_STAFF=1 mix compile --force --warnings-as-errors`: passed. Normal
  dependencies restored afterward; the lockfile is unchanged.
- Catalog diff: exactly one added msgid, translated in all seven locales;
  no existing messages changed or removed. Runtime Gettext lookups also
  returned each translated label.
- Final `mix precommit`: passed (compilation with warnings as errors, unused
  dependency check, Hex advisory audit, formatting, strict Credo, Dialyzer).

Publishing is outside this pre-publish review. Changes are recorded as
Unreleased; a future release commit should select the next version, update the
changelog heading, pass the gate, and be pushed before publishing. Tag only
after publication succeeds.
