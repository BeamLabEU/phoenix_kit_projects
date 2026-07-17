# PR #30 review — Calendar everywhere + quality sweep

- **PR:** [#30](https://github.com/BeamLabEU/phoenix_kit_projects/pull/30) — `mdon/main` → `main`
- **Merge:** `798c486` (31 commits, `23d57a2` … `62d8f03`)
- **Author:** mdon · merged by ddon
- **Reviewer:** Claude (Sonnet 5), post-merge
- **Scope:** 60 files, +18896 / −3973. Adds a project **Calendar tab** (`ProjectCalendarLive`,
  new), a task-first rework of the Overview calendar, a shared `ScheduleLayout` module so
  the Timeline and Calendar tabs can never disagree about a task's dates, a person/overdue
  **assignee filter** shared by both calendars (`Web.AssigneeFilter`, `Assignees`,
  `<.assignee_filter_panel>`), a whole-day popup (`<.day_popup_modal>`), and a follow-up
  quality sweep (PR-review catch-up on #25–#28, a delta audit, an AI-panel triage) folded
  into the same branch.
- **Verdict:** One real crash bug (every render of a shipped widget), one real data-staleness
  bug (in two places), and one real logging gap that undercut an already-tested resilience
  contract — all fixed at review time. One documented-but-not-actually-enforced contract
  guarantee in the new filter panel, left as a landmine on record (not fixed — see rationale).
  Gate is green after fixes (see below).

## Findings

### BUG - CRITICAL — `ProjectsBoardWidget` crashes on every render of its default view (FIXED)

`lib/phoenix_kit_projects/web/widgets/projects_board_widget.ex:90` (pre-fix). The grid-view
template read `:if={not @compact}`, but `update/2` never assigns `:compact` — this widget's
only two views are `"grid"`/`"counts"` (no compact variant), unlike its sibling widgets which
dropped `@compact` everywhere when the dashboards lattice was reworked to size-driven layout.
HEEx's `@compact` desugars to `Phoenix.HTML.Engine.fetch_assign!/2`, which raises
`ArgumentError: assign @compact not available in template` on any missing key — no DB error
needed, it fails on the very first render.

**Failure scenario:** any admin who adds the "Projects board" widget to a dashboard (or who
already has one, post-upgrade) gets an immediate crash the moment the widget renders in its
default Grid view. No test exists for this widget's rendering (only the catalog-registration
test), so nothing caught it pre-merge.

**Fix:** removed the stray `:if={not @compact}` — the status-line span now always renders,
matching the widget's own moduledoc ("a uniform tile per project... with the workflow status
as a second line").

### BUG - MEDIUM — an open whole-day popup goes stale after a PubSub reload, in both calendars (FIXED)

`overview_live.ex` and `project_calendar_live.ex`. Both calendars cache the day-popup's rows
once, at the moment it's opened (`day_popup: %{date:, rows: day_rows(socket, date)}`), reading
from whatever `task_calendar_events`/`events` happened to be current then. Neither `reload/1`
(Overview, on any `{:projects, _, _}` broadcast) nor `apply_calendar_filter/1`
(`ProjectCalendarLive`, on the same broadcasts *and* every filter-chip toggle) touched
`day_popup` after rebuilding those events.

**Failure scenario:** open a day's popup, then someone else marks one of that day's listed
tasks done (or reassigns/deletes it) — the popup keeps showing the old status/lateness, or a
row for a task that's gone, until the viewer closes and reopens it. Same gap for a filter
toggle while the popup is open: the popup keeps rows that no longer match the active filter.

**Fix:** both `reload/1` (Overview) and the shared `apply_calendar_filter/1`
(`ProjectCalendarLive`, which both the PubSub path and the filter-toggle path already funnel
through) now re-derive `day_popup.rows` from the just-rebuilt event data when a popup is open.
Factored the row-building logic in `project_calendar_live.ex` into a named `day_popup_rows/2`
shared between `open_day_popup/2` and the refresh, instead of duplicating the mapping inline.

### IMPROVEMENT - HIGH — widget DB-read resilience rescues had zero logging (FIXED)

`web/widgets/{helpers,deadlines_widget,my_tasks_widget,ongoing_tasks_widget,project_status_widget,projects_board_widget,workload_widget}.ex`
— all 10 "never crash the host dashboard" rescue sites added across this branch (commit
`76e10fe`, itself a follow-up to the [PR #28 review](../28-dashboard-widgets/CLAUDE_REVIEW.md)'s
"resilience applied unevenly" finding) used a bare `rescue _ -> <default>` with no logging. A
genuine bug elsewhere (not a DB outage — a logic error, a bad preload, a future regression)
would silently render the widget's empty state forever, with **no trace in the logs**,
contradicting the "logs and returns" half of the convention `Projects.list_assignments_for_user/1`
itself already implements (narrow `rescue e in [Postgrex.Error, DBConnection.ConnectionError,
Ecto.QueryError] -> Logger.warning(...)`).

**Fix, and an important correction made mid-fix:** my first pass narrowed every widget-level
rescue to that same 3-exception list. That broke a real, deliberate, already-tested contract:
`test/phoenix_kit_projects/web/widgets_resilience_test.exs` exercises `MyTasksWidget` and
`DeadlinesWidget` with a malformed viewer uuid that escapes
`list_assignments_for_user/1`'s own narrow rescue as `Ecto.Query.CastError` — a type **not**
in that 3-exception list — specifically so the outer widget-level rescue can catch it as a
last-resort safety net. Narrowing the outer rescue would have made that scenario crash instead
of degrade. Corrected to keep every widget-level `rescue e ->` broad (catches anything, per
the "never crash" contract every one of these widgets documents in its own moduledoc) while
adding the missing `Logger.warning("[Widget] ... failed: #{Exception.message(e)}")` call. This
preserves the tested behavior and adds the observability that was actually missing.

### IMPROVEMENT - HIGH — `<.assignee_filter_panel>`'s own documented collision guarantee isn't actually implemented (documented, not fixed)

`lib/phoenix_kit_projects/web/components/assignee_filter_panel.ex:93-96`. The panel's
moduledoc explicitly says: "Pass a unique `id` per page so two panels (e.g. the Overview and
an embedded project calendar) can't collide" — but the four `<.search_picker>` event-name
attrs it passes (`search_event="assignee_search"`, `results_event="assignee_results"`,
`pick_event="assignee_pick"`, `staged_event="assignee_staged"`) are hardcoded literals, not
derived from `@id`. Only the DOM ids (`#{@id}-panel`/`-search`/`-dropdown`) are actually
parameterized. `SearchPicker`'s own contract (`deps/phoenix_kit/.../search_picker.ex`,
"Multiple pickers in one view") is explicit: `push_event` replies broadcast to every hook
listening on the event name, so two pickers sharing names cross-populate results and a staged
confirm clears both — give each instance distinct names, or echo the `id` the hook sends back
in the payloads and filter on it. `Web.AssigneeFilter.update/3`'s `push_event` calls
(`assignee_filter.ex:138,153,158`) do neither.

**Failure scenario:** exactly the one the panel's own moduledoc names as supported — render
`<.assignee_filter_panel>` twice inside the same LiveView/socket (not currently done anywhere
in this codebase; each of the two current call sites, `overview_live.ex` and
`project_calendar_live.ex`, is the only panel in its own separate LiveView) — typing in picker
A's search box would deliver results into picker B's dropdown too, and picking in one would
stage/clear both.

**Why not fixed:** not reachable today — verified both call sites are each a lone panel per
socket, so there's no reproduction path in the current codebase. A correct fix means either
threading `@id` through the event names on both the component and `AssigneeFilter`'s
`@events`/`update/3` dispatch (which currently matches literal event-name strings), or wiring
the id-echo-and-filter half of the contract through the JS hook — either is a real change to a
shared dispatch contract, not a local one-line fix, and would be speculative hardening against
a scenario that doesn't exist yet. Flagging so the gap between the documented guarantee and the
actual code is on record before a third call site is ever added.

### NITPICK — hardcoded late-marker class duplicated instead of shared (FIXED)

`project_calendar_live.ex` hardcoded the literal `"ring-2 ring-error ring-inset"` instead of
sharing `CalendarDisplay`'s private `@late_class` — harmless today (identical strings) but
nothing enforced they'd stay in sync. Added a public `CalendarDisplay.late_class/0` accessor
(same pattern as the existing `loading_class/0`) and pointed `project_calendar_live.ex` at it.

### NITPICK — `Assignees.search_people/3`'s "Load more" pagination has no deterministic tiebreaker (FIXED)

`assignees.ex:154`. `ORDER BY coalesce(name, email)` alone, re-queried with a growing `limit`
for "Load more" (no offset/cursor) — ties (two people with the same name, or both nameless and
emailless) aren't guaranteed the same relative order across the two separately-executed
queries, so a person could appear twice or be skipped across a page boundary. Added `p.uuid` as
a secondary sort key for a fully deterministic order.

### NITPICK — `ProjectCalendarLive.bar_match/4`'s empty-filter clause reads as conditional but isn't (documented, not fixed)

`project_calendar_live.ex:386`: `defp bar_match(refs, [], false, _direct), do: if(refs, do: nil)`.
`refs` is always a non-empty list (every top item contributes at least its own assignment), and
any list — even `[]` — is truthy in Elixir, so this always evaluates to `nil` (= "matches, no
via/provenance", i.e. shown normally when no filter is active). Correct behavior, just written
as if there were a real condition. Left as-is: purely cosmetic, and touching it risks a mistake
for zero behavioral change.

### NITPICK — `project_calendar_live.ex`/`project_gantt_live.ex` mount reads the project directly, twice per initial load (documented, not fixed)

Both LVs' `mount/2` call `Projects.get_project_with_assignee(id)` directly (not deferred to
`handle_params/3`), so a deep-linked initial load runs it once for the disconnected render and
again for the connected mount. This mirrors an existing, explicitly-accepted pattern
(`ProjectGanttLive` has always done this; `ProjectShowLive` does too — see AGENTS.md
"`ProjectShowLive` is mount-only by design," which explains `handle_params/3` was reverted
project-wide because LiveView refuses to mount an LV exporting it outside a router live route,
which would block `live_render` embedding). `ProjectCalendarLive` is new in this PR but
faithfully follows the same constraint rather than introducing a new one. Not fixed for the
same documented reason.

### NITPICK — Overview `reload/1` extends an already-accepted no-debounce tradeoff (not fixed)

Once the Overview's Calendar tab has ever been opened (`calendar_seen? == true`), every
subsequent `{:projects, _, _}` broadcast now also re-runs the per-project `ScheduleLayout.tree/1`
walk inside `reload/1` — even while the viewer is back on the List tab. This is a natural,
consistent extension of AGENTS.md's already-documented, deliberately-accepted tradeoff ("No
event-debounce / minimal-delta on `OverviewLive` `handle_info`" — flagged in the PR #1 review,
kept for the same scope reason ever since), not a new regression introduced by this PR.

## What I verified (no bug found)

- **The shared-schedule invariant holds.** Both `ProjectGanttLive.build_gantt/2` and
  `ProjectCalendarLive.load_calendar/1` (and `OverviewLive.load_task_calendar/5`) call the
  identical `ScheduleLayout.tree(project)` and read spans via `Map.fetch!/2` off its result —
  no independent date computation exists in either view. The Timeline and Calendar tabs cannot
  disagree about a task's dates.
- **UTC-vs-viewer-offset split is applied to the correct calendar in each case** —
  `ProjectCalendarLive` stays UTC-unshifted (Timeline parity); `OverviewLive`/`CalendarDisplay`
  thread the viewer's offset through. Not swapped.
- **Sub-project bars are genuinely descendant-aware** — `assignment_refs/2` recurses the full
  flattened tree from each top-level item, not a shallow check against the sub-project's own
  assignee.
- **Assignee matching is correct**: `Assignees.match/2` checks direct + team + department;
  `AssigneeFilter.match_any/2` unions correctly across chips ("any `:direct` wins"); "Direct
  only" strips non-direct matches in both consumers; the Unassigned toggle ORs in rather than
  ANDs. `task_late?/3` compares two UTC-naive instants (timezone-invariant, no off-by-one).
- **`embeddable_lvs/0` whitelist was correctly updated** — `ProjectCalendarLive` was added
  alongside the new Calendar tab; every new navigation target from the day popup / assignee
  filter was already on the list.
- **No DB query was added to `OverviewLive.mount/3`** — the Iron Law holds; `load_task_calendar`
  only runs from `reload/1` once `calendar_seen?` flips true (post-mount), not at mount itself.
- **Host-identity threading is intact** — `AssigneeFilter.resolve_me/1` goes through the
  pre-existing `Activity.actor_uuid/1` → `assign_embed_user/2` path; no bypass.
- **No bare `push_navigate`, no `String.to_atom` on user input, no unscoped PubSub topics, no
  N+1s** introduced anywhere in the reviewed diff.

## Gate (project `mix precommit` chain) — all green

Run from the repo root against installed deps (this checkout has no `/www/app` parent workspace):

| Step | Result |
|---|---|
| `format` | ✅ clean |
| `compile --force --warnings-as-errors` | ✅ clean (60 files) |
| `deps.unlock --check-unused` | ✅ clean |
| `hex.audit` | ✅ no retired/advisory packages |
| `credo --strict` | ✅ 137 files, 1608 mods/funs, no issues |
| `dialyzer` | ✅ passed (7 ignored via `.dialyzer_ignore.exs`, 0 unnecessary) |
| `mix test` | ✅ 198 passed / 0 failed (700 excluded — no Postgres in this review env) |

> **Test caveat (environment).** No PostgreSQL is reachable here, so every `:integration`/DB
> test is auto-excluded per this repo's "`mix test` never hard-fails on a missing DB" stance —
> **including `widgets_resilience_test.exs`**, the test that specifically pins the
> `CastError`-escapes-to-a-broad-rescue behavior this review's fix depends on. I read that
> test's source directly (see the IMPROVEMENT-HIGH finding above) to confirm the corrected fix
> satisfies it; it should be re-run in CI (which does have Postgres) to confirm at runtime.

## Files touched by this review

| File | Change |
|---|---|
| `lib/phoenix_kit_projects/web/widgets/projects_board_widget.ex` | fixed the `@compact` crash; broad-catch + log on `statuses_by_project/1` |
| `lib/phoenix_kit_projects/web/overview_live.ex` | refresh an open day-popup's rows after `reload/1` rebuilds calendar data |
| `lib/phoenix_kit_projects/web/project_calendar_live.ex` | same day-popup refresh in `apply_calendar_filter/1`; shared `day_popup_rows/2`; use `CalendarDisplay.late_class/0` |
| `lib/phoenix_kit_projects/calendar_display.ex` | new public `late_class/0` accessor |
| `lib/phoenix_kit_projects/assignees.ex` | deterministic `search_people/3` ordering (`p.uuid` tiebreaker) |
| `lib/phoenix_kit_projects/web/widgets/{helpers,deadlines_widget,my_tasks_widget,ongoing_tasks_widget,project_status_widget,workload_widget}.ex` | added `Logger.warning` to existing broad-catch resilience rescues |
