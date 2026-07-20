# PR #30 follow-up

Triage of [CLAUDE_REVIEW.md](CLAUDE_REVIEW.md) (post-merge review, Claude
Sonnet 5). Unusual shape for a follow-up: the reviewer **applied its own
fixes at review time** — so the triage here is verification that each fix
is present in the current tree, plus resolution of the deliberately-
unfixed items.

## Fixed (pre-existing — applied by the review itself, verified 2026-07-20)

- ~~BUG-CRITICAL `ProjectsBoardWidget` `@compact` crash~~ — verified: no
  `@compact` reference remains in `projects_board_widget.ex`; the
  status-line span renders unconditionally; `Logger.warning` present in
  its resilience rescue.
- ~~BUG-MEDIUM stale open day-popup after PubSub reload (both calendars)~~
  — verified: `overview_live.ex` re-derives `day_popup.rows` in
  `reload/1`; `project_calendar_live.ex` has the shared
  `day_popup_rows/2` and refreshes through `apply_calendar_filter/1`.
- ~~IMPROVEMENT-HIGH widget resilience rescues had zero logging~~ —
  verified: all 7 widget files carry `Logger.warning` in their broad
  rescues (broadness itself is the tested "never crash" contract per
  `widgets_resilience_test.exs` — do not narrow).
- ~~NITPICK `search_people/3` non-deterministic Load-more order~~ —
  verified: `asc: p.uuid` tiebreaker present in `assignees.ex`.
- ~~NITPICK hardcoded late-marker class~~ — the review added
  `CalendarDisplay.late_class/0` and pointed the calendar tab at it.
  **Superseded since:** the configurable late-marker system
  (`late_marker_class/1`, marker enum pattern|ring|none, shipped in the
  post-#30 customizer work) replaced the call site, orphaning the
  accessor. The dead `late_class/0` is deleted in this sweep (the
  `@late_class` attr itself stays — it backs `late_marker_class/1` and
  the `:late_class` opt default).

## Skipped (with rationale)

- `<.assignee_filter_panel>` hardcoded SearchPicker event names vs its
  documented per-`id` collision guarantee — **left on record, not
  fixed**, per the review's own rationale: both call sites are each the
  lone panel in their own LiveView socket, so the collision is
  unreachable today; the fix touches the shared `AssigneeFilter`
  dispatch contract and would be speculative. The landmine note stands
  for whoever adds a third call site. (Surfaced again in this sweep's
  report rather than silently carried.)
- `bar_match/4` empty-filter clause cosmetics; mount double-read of the
  project on deep links; Overview no-debounce reload — all documented
  accepted patterns (see the review; the mount/debounce items trace to
  AGENTS.md-documented constraints).

## Files touched

| File | Change |
|---|---|
| (verification only) | all review-time fixes confirmed present |
| `lib/phoenix_kit_projects/calendar_display.ex` | delete orphaned `late_class/0` (this sweep) |

## Verification

- Fix-presence greps 2026-07-20 (this file's Fixed section).
- `mix precommit` + full suite green as part of the 2026-07-20 quality
  sweep this follow-up ships in (946+ tests; see the sweep PR body).

## Open

None.
