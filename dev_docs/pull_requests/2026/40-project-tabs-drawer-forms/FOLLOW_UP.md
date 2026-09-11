# FOLLOW_UP — PR #40: Project tabs, drawer forms

Triaged 2026-09-11 against current `main`. Reviewer: Claude
(`CLAUDE_REVIEW.md`).

## Fixed (pre-existing)

- ~~**BUG-CRITICAL — the module could not be published: it consumed unreleased
  core.**~~ Resolved; core caught up.
- ~~**BUG-HIGH — `mix test` red on `main` (5 failures from the dependency
  bump).**~~ Green: 1511 tests, 0 failures.
- ~~**IMPROVEMENT-MEDIUM — two 49-key placeholder assign lists edited in
  lockstep.**~~ Fixed. One `assign_not_found_placeholders/1`
  (`web/assignment_form_live.ex:200`) is now the single list.
- ~~**IMPROVEMENT-MEDIUM — `TasksLive`'s `one_off_count` had no mount
  default.**~~ Fixed (`web/tasks_live.ex:113`, `one_off_count: 0`).
- ~~**NITPICK — `RunningTiers.prioritize/4` hand-rolled what `Enum.sort_by/2`
  does.**~~ Fixed (`running_tiers.ex:50`).
- ~~**NITPICK — a comment in `DashboardWidgets` contradicted the route
  table.**~~ Resolved.

## Still live (surfaced, not changed in this triage)

- **IMPROVEMENT-MEDIUM — the dashboard widgets re-run the Overview's N+1 on a
  refresh tick.** Unchanged.
- **NITPICK — `Projects.quick_add_assignment/3` takes an `_opts` it never
  reads** (`projects.ex:2920`). Confirmed. The affordance is misleading: a
  caller threading `actor_uuid:` gets no activity attribution and no warning.

## Files touched

None in this triage.

## Verification

`mix precommit` clean; 1511 tests, 0 failures (2026-09-11).

## Open

The two items above.
