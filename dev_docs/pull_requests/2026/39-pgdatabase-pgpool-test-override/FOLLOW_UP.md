# Follow-up — PR #39

How each finding in `CLAUDE_REVIEW.md` stands against the current code.

- **IMPROVEMENT - MEDIUM: a `PGDATABASE` exported for other work silently
  redirects `mix test` there** — **Fixed in this sweep.** The behaviour is
  unchanged (`config/test.exs` reads `PGDATABASE` first, as core does); the
  Testing section of `AGENTS.md` now says that a value exported for other work
  redirects the suite too, so a developer whose shell sets it for a dev
  database is warned before the migrations run there.
- **NITPICK: with `PGDATABASE` set, the `MIX_TEST_PARTITION` suffix is
  dropped** — **Fixed in this sweep**, by the same `AGENTS.md` paragraph:
  partitions then share that one database. `config/test.exs` still appends
  the partition only to the default name.
