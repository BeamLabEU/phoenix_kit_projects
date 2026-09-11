# FOLLOW_UP — PR #31: Admin UI overhaul, list architecture

Triaged 2026-09-11 against current `main`. Reviewer: Claude
(`CLAUDE_REVIEW.md`).

## Fixed (pre-existing)

The review marked three BUGs `(FIXED)` in the PR itself and they remain fixed:
DnD reorder gating vs. load-more truncation, the tautological test assertion,
and `DashboardWidgets.project_options/0` rescuing every exception rather than
the declared set.

## Still live (surfaced, not changed in this triage)

- **IMPROVEMENT-MEDIUM — `ilike` escaping duplicated instead of shared.**
  Confirmed. `projects.ex:145` has a private `escape_like/1` used at `:127` and
  `:1588`, but `assignees.ex:179-184` hand-rolls the identical three
  `String.replace/3` calls. Two copies of an escaping rule is one copy too
  many — the day one gains a case the other silently does not.
- **NITPICK (pre-existing, PR-unrelated) — brief stale-content flash on rapid
  day-popup close-then-reopen.** Unchanged.

## Files touched

None in this triage.

## Verification

`mix precommit` clean; 1511 tests, 0 failures (2026-09-11).

## Open

The shared-escaping helper. Low risk, and the fix is to move `escape_like/1`
somewhere both modules can reach rather than to change behaviour.
