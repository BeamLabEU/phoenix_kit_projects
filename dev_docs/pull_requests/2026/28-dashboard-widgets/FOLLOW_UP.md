# PR #28 follow-up — Dashboard widgets provider

Triaged 2026-07-17 as part of the quality sweep. The review's HIGH bug was
fixed at review time; its deferred resilience improvement is now done as the
deliberate, tested pass the reviewer asked for.

## Fixed (pre-existing)

- ~~BUG-HIGH: `only_mine` filtered after the row cap~~ — fixed at review
  with the pure `scope_and_limit/4` (filter-then-take, "no resolvable
  viewer ⇒ never leak all"); re-verified live at
  `lib/phoenix_kit_projects/web/widgets/deadlines_widget.ex:65` with its
  unit tests.

## Fixed (Batch 1 — 2026-07-17)

- ~~IMPROVEMENT-MEDIUM: DB-read resilience applied unevenly across
  widgets~~ — every widget's primary read is now guarded, matching the
  AGENTS.md "never crash the host dashboard" convention the two existing
  rescues implemented:
  - `OngoingTasksWidget.ongoing_tasks/2` → `[]`
  - `MyTasksWidget.my_tasks/2` → `[]`
  - `DeadlinesWidget.mine_uuids/1` → `nil` (keeps the never-leak branch)
  - `ProjectStatusWidget`/`ProjectScheduleWidget` → shared
    `Helpers.safe_project_summary/1` → `nil` (both renders already have a
    nil-summary state)
  - `ProjectStatusWidget.workflow_status/1` → `nil` (badge dropped)
  - `ProjectsBoardWidget`/`WorkloadWidget` → shared
    `Helpers.safe_list_projects/0` → `[]`;
    `ProjectsBoardWidget.statuses_by_project/1` → `%{}`
  - Pinned by the new `test/phoenix_kit_projects/web/widgets_resilience_test.exs`:
    a **real raising read** (malformed viewer uuid escapes
    `list_assignments_for_user/1`'s rescue list as `Ecto.Query.CastError`)
    renders the empty state for My tasks and the no-leak empty Deadlines,
    and all seven widgets render (not raise) from a process with no DB
    access at all.

## Fixed (Batch 2 — 2026-07-17, AI-panel consensus)

- ~~NITPICK: Workload "detailed" omits `:setup` so the four tiles can sum
  below the total~~ — unanimous panel pick: fold `:setup` into the
  Scheduled tile relabeled **"Not started"** (both mean "work hasn't
  begun"; tiles now always reconcile with the headline count, no layout
  change). Pinned by `workload_widget_test.exs`.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_projects/web/widgets/helpers.ex` | new `safe_list_projects/0` + `safe_project_summary/1` guards |
| `lib/phoenix_kit_projects/web/widgets/ongoing_tasks_widget.ex` | rescue on the primary read |
| `lib/phoenix_kit_projects/web/widgets/my_tasks_widget.ex` | rescue on the primary read |
| `lib/phoenix_kit_projects/web/widgets/deadlines_widget.ex` | rescue on the staff lookup |
| `lib/phoenix_kit_projects/web/widgets/project_status_widget.ex` | guarded summary + workflow-status reads; unused alias dropped |
| `lib/phoenix_kit_projects/web/widgets/project_schedule_widget.ex` | guarded summary read; unused alias dropped |
| `lib/phoenix_kit_projects/web/widgets/projects_board_widget.ex` | guarded projects + statuses reads; unused alias dropped |
| `lib/phoenix_kit_projects/web/widgets/workload_widget.ex` | guarded projects read |
| `test/phoenix_kit_projects/web/widgets_resilience_test.exs` | new — pins the no-crash invariant (3 tests) |

## Verification

- `mix test test/phoenix_kit_projects/web/widgets_resilience_test.exs
  test/phoenix_kit_projects/dashboard_widgets_test.exs` — 9 tests, 0
  failures.
- `mix compile --warnings-as-errors` clean; full `mix precommit` run at the
  end of the sweep (see PR #30).

## Open

None.
