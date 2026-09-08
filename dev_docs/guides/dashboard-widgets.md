# Dashboard widgets (contributed to `phoenix_kit_dashboards`)

The widget catalog this module contributes, the one-way discovery contract
behind it, and the conventions every widget component follows.

Rules for this live in [AGENTS.md](../../AGENTS.md) → Feature notes.

Projects contributes ten widgets to the dashboards module via the duck-typed
`PhoenixKitProjects.phoenix_kit_widgets/0` (delegates to
`PhoenixKitProjects.DashboardWidgets.all/0`) — a **one-way** contract: projects
has no dependency on `phoenix_kit_dashboards`; its Registry discovers the
plain-map list and gates visibility on the `"projects"` module + permission.

Each widget is a `Phoenix.LiveComponent` under `lib/phoenix_kit_projects/web/widgets/`
that the dashboards host renders with `settings` / `view` / `size` / `scope`
assigns and re-queries on the host's refresh tick (`refresh_interval`). The
widgets: `projects.board` (all projects, coloured by status — grid/counts),
`projects.workload` (workspace lifecycle + task counts — detailed/simple),
`projects.my_tasks` (the CURRENT USER's open assignments via the `scope` assign
→ staff person → `list_assignments_for_user/1`), `projects.deadlines` (running
projects by nearest weekend-aware `planned_end`, overdue flagged — built on
`project_summaries/1`), `projects.status` / `projects.schedule` (one project's
status / estimate — detailed/simple), `projects.tasks` (a project's ongoing
tasks — detailed/compact), and the Overview's own pieces, so a
dashboards-module board can carry them too: `projects.running` (the Running list in
`RunningTiers` order with tier + progress; compact/cards; `late_only`),
`projects.upcoming` (setup + scheduled / recently completed),
`projects.calendar` (the Tasks/Projects calendar: the same
`ScheduleLayout` walk + `CalendarDisplay` event builders + nested
`PhoenixLiveCalendar.CalendarComponent`, which pages months on its own and
keeps that across refresh ticks under its stable id; month/agenda;
`mode`/`only_mine`/`late_only`). The calendar widget has NO assignee panel,
day popup or click-to-open: a widget is a LiveComponent, and the calendar's
`on_*` callbacks message the parent LiveView — the dashboards host — so none
are wired (nesting a LiveView instead was rejected: refresh ticks
remount it, no socket for `live_render` in a component, no scope across the
session boundary). With `projects.my_tasks` and `projects.workload` (the
stat tiles), a system-scope dashboard can mirror the page. Every view
declares its own `min_size` (the improved dashboards widget API), and the
shared frame renders **compact** at a single row so minimum boxes fit
without scrollbars.

Conventions for these widget components:

- **Static root:** a stateful LiveComponent's `render/1` must return a single
  static HTML tag, so each wraps the shared `Helpers.frame/1` (a function
  component) in `<div class="contents">…</div>` — `contents` keeps the card
  filling the grid cell.
- Guard every data read behind `Helpers.available?/0` (projects loaded + enabled)
  and `Statuses.available?/0` (entities plugin) — render the `unavailable`/empty
  states otherwise; never crash the host dashboard.
- Single-project widgets pick their project from a **select of current
  projects** (`DashboardWidgets.project_options/0` → `{name, uuid}` tuples;
  blank = first running). The options are evaluated when the dashboards
  Registry builds its catalog, so a brand-new project appears in the select
  after a registry refresh; stored values (and stale ones) resolve leniently
  via `Helpers.resolve_project/1` (uuid / name / external id / substring).
- Reuse the projects badge components (`DerivedStatusBadge`,
  `AssignmentStatusBadge`) for consistent status colours.
- `DashboardWidgets` catalog metadata (names/descriptions) is plain English (the
  contract caches it), but widget CONTENT is gettext'd via `PhoenixKitProjects.Gettext`.
  `phoenix_kit_dashboards` translates provider strings through ITS OWN backend,
  so this module's backend cannot reach the catalog strings until that helper
  honours a provider backend.
