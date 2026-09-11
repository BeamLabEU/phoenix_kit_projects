# FOLLOW_UP — PR #38: nav_tabs on the assignment form

Triaged 2026-09-11 against current `main`. Reviewer: Grok (`GROK_REVIEW.md`).

## Fixed (pre-existing)

- ~~**IMPROVEMENT-MEDIUM — `AGENTS.md` still documented the deleted
  component.**~~ Fixed. No `TabsStrip` reference survives in `AGENTS.md` /
  `CLAUDE.md`; the only remaining mention is a deliberate historical comment at
  the call site (`web/assignment_form_live.ex:1865`, "Was a module-local
  TabsStrip duplicating core's `<.nav_tabs>`"), which is the kind of
  one-clause *why* the docs standard asks to keep.

## Files touched

None.

## Verification

`mix precommit` clean; 1511 tests, 0 failures (2026-09-11).

## Open

None.
