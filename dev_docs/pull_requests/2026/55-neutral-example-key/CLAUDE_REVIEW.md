# Claude (Sonnet 5.5) review — PR #55, after the merge (2026-10-22)

PR #55 (`timujinne/docs/neutral-host-examples`, merge `dc91c7b`): replaces the
host-specific example project key (`ANDI` / `Andi`) with the neutral `ACME` in
comments, docs, API guide text, gettext msgids and test data — 47 files, 148
lines in, 148 out, no behaviour change.

## Verified, no change needed

- **Gettext stays in step.** The one runtime-visible string that carried the
  example (`ApiKeyPanel.setup_prompt/3`'s "Send the token…" msgid) changed in
  `api_key_panel.ex`, `default.pot` and all seven locale catalogues; the msgid
  is byte-identical in all nine places, so no locale falls back to English. The
  `et` / `ru` msgstrs were updated too; the other locales' msgstrs never carried
  the example.
- **Nothing left behind.** `grep -rniE '\bandi\b'` over the tree (excluding
  `_build` / `deps` / `.git`) finds no occurrence.
- **Tests keep their meaning.** The renames touch ordering assertions
  (`titles(inside) == ["ACME 3D editor", "ACME Manager", …]`, the extension
  column sort with `"Zeta OÜ"`); the relative order is unchanged because `ACME`
  sorts where `ANDI` did. `Refs.suggest` cases (`ACME Manager` → `ACME`) still
  exercise the leading-acronym rule.
- **Gate.** `mix format --check-formatted` clean, `mix compile
  --warnings-as-errors` clean, `mix test`: 2070 tests, 0 failures (PostgreSQL
  reachable, integration tests ran).

## NITPICK

- **Archived review docs were rewritten.** The PR edits
  `48-…/README.md`, `51-…/README.md` and an earlier `CLAUDE_REVIEW.md`. Only the
  example key changed, so the findings are intact, but these are the repo's
  record of what each reviewer saw; a future example-key change is better left
  to the live docs. Not reverted — the content is equivalent and reverting would
  re-publish the host-specific name.
- **`ACME Manager` in AGENTS.md's narrative** ("ran 27 calls on ACME Manager")
  now names a project that never existed under that name. Harmless; the history
  reads the same.

No bugs, no fixes needed.
