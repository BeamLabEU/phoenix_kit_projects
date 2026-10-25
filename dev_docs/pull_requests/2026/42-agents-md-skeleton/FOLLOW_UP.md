# Follow-up — PR #42

How the finding in `CLAUDE_REVIEW.md` stands against the current code.

- **NITPICK: the `test_helper.exs` comment still says the core floor is
  `~> 2.0`** — **Fixed in this sweep.** The comment above `db_check`
  (`test/test_helper.exs:40-41`) no longer names a floor; it says the
  preflight is used when the running core has it and otherwise falls through
  to the previous behaviour. The `Code.ensure_loaded?` guard is unchanged.
