# PR #27 follow-up — Overview month calendar of running projects

Triaged 2026-07-17 as part of the quality sweep. The review found no bugs;
of its four minor findings, two are fixed here and two stay as documented
judgment calls.

## Fixed (Batch 1 — 2026-07-17)

- ~~NITPICK: new activity actions missing from AGENTS.md~~ — the "Activity
  logging" action list now includes `projects.gantt_display_changed/reset`
  and `projects.calendar_display_changed/reset` (and, found while fixing,
  the also-missing `projects.project_archived/unarchived`,
  `projects.subproject_created/linked/detached`, and
  `projects.assignment_updated`).
- (Same shape as PR #26's read finding, applied here for consistency:)
  `CalendarDisplay.read_animation/0` now batches its six keys through one
  uncached `get_settings_direct/1` call — it runs on **every** Overview
  reload (each `{:projects, …}` broadcast), so this was 6 queries per
  broadcast per open session.

## Fixed (Batch 2 — 2026-07-17, AI-panel consensus)

- ~~IMPROVEMENT-LOW: activity row per debounced slider tick~~ — coalesced
  together with PR #26's card per the AI-panel consensus — one
  settled-value row per drag, both settings cards consistent. See PR #26's
  FOLLOW_UP for the mechanism.

## Skipped (with rationale)

- IMPROVEMENT-LOW: calendar data computed eagerly on every reload — the
  reviewer's rationale stands (deferring behind `calendar_seen?` would
  complicate cross-session reactivity; the cost is a list map over
  already-computed summaries). Since PR #30, Tasks-mode items are also
  cached (`task_calendar_items`), further shrinking the recompute.
- NITPICK: `CalendarDisplay.anim_range/1` has no catch-all — deliberate
  fail-loud on programmer error; only called with the four literal field
  names.

## Files touched

| File | Change |
|------|--------|
| `AGENTS.md` | activity-action list completed (display-settings, archive, subproject, assignment_updated actions) |
| `lib/phoenix_kit_projects/calendar_display.ex` | `read_animation/0` batches its 6 keys through one `get_settings_direct/1` call |

## Verification

- `mix test test/phoenix_kit_projects/calendar_display_test.exs` — green
  (33 tests; the animation read/put round-trips pin the refactor).
- `mix compile --warnings-as-errors` clean; full `mix precommit` run at the
  end of the sweep (see PR #30).

## Open

None.
