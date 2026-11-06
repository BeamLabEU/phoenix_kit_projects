# Follow-up — PR #62

2026-11-05: how Claude's findings (`CLAUDE_REVIEW.md`) were resolved.

- **Fixed, with a test that fails when the fix is reverted:** MEDIUM, the full `down/1`; IMPROVEMENT, the test
  for the staff and entities chains.
- **Left, recorded:** the two NITPICKs.
- **Closed the same day:** `phoenix_kit_staff#24` is in staff 0.11.1, and `mix.exs` now requires it
  (`>= 0.11.1 and < 1.0.0`), so the next projects release cannot go out ahead of the guard.

## Gate (this tree, with #61's fixes)

- `mix precommit`: passes (compile, `deps.unlock --check-unused`, `hex.audit`, format, credo, dialyzer).
- `mix test` on a brand-new database: 2760 tests, 0 failures, none excluded. The chain test was added after that
  run; its file passes alone (16 tests, 0 failures), and that file's format and credo are clean.
- `WITHOUT_STAFF=1 mix compile --warnings-as-errors`: passes.

The shared `phoenix_kit_projects_test` database is at core V224, below core 3.3.0's V225 floor, so `mix test` there
excludes every DB-backed test and still reports success. These runs used scratch databases through `PGDATABASE`.
`mix test.reset` would fix it for good.
