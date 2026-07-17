# PhoenixKitProjects

A [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit) plugin for **project + task management**: a reusable task library, projects that pull tasks in as assignments, per-project and per-template dependencies, schedule math with weekday/calendar awareness, and assignees sourced from [`phoenix_kit_staff`](https://github.com/BeamLabEU/phoenix_kit_staff).

## Features

- **Task library** — reusable task templates with description, estimated duration, default assignee
- **Projects** — containers with `immediate` or `scheduled` start mode, completion auto-detection
- **Assignments** — task instances inside a project; editable independently of the template
- **Dependencies** — per-project ("A must finish before B") with multi-hop cycle detection
- **Template dependencies** — declared on the task template, auto-applied when both tasks are in the same project
- **Templates** — project templates cloned into real projects inside a single transaction
- **Polymorphic assignees** — team _or_ department _or_ person (at-most-one, enforced at DB + changeset layer)
- **Schedule math** — planned vs. projected end with velocity tracking; per-task `counts_weekends` override
- **Timeline & Calendar views** — every project has List/Timeline/Calendar tabs over one shared schedule walk (`ScheduleLayout`); the Overview calendar shows every task across all projects (Google-style per-day caps + whole-day popup) or one line per project with a configurable overdue marker
- **Assignee filters** — a Filters panel on both calendars: multi-person typeahead (DB-paged), Unassigned lens, personal-only and overdue-only refinements, with inherited team/department semantics (`Assignees`)
- **Dashboard widgets** — seven widgets for `phoenix_kit_dashboards` (board, workload, my tasks, deadlines, per-project status/schedule/tasks), duck-typed and crash-isolated
- **Mass-assignment guard** — `completed_by_uuid` / `completed_at` can only be set through the server-trusted `status_changeset/2`
- Real-time updates via `PhoenixKit.PubSub.Manager`
- Activity logging for every mutation
- Admin pages under `/admin/projects/*`

## Installation

Add to your parent PhoenixKit app's `mix.exs`:

```elixir
{:phoenix_kit_staff, "~> 0.1"},
{:phoenix_kit_projects, "~> 0.5"}
```

(For local development inside the PhoenixKit workspace, use the path-dep form instead: `{:phoenix_kit_projects, path: "../phoenix_kit_projects"}`.)

`phoenix_kit_staff` is a **hard dependency** — assignment and task schemas reference staff tables for the polymorphic assignee.

Also add both apps to `extra_applications` so `PhoenixKit.ModuleDiscovery` finds them:

```elixir
def application do
  [extra_applications: [:logger, :phoenix_kit, :phoenix_kit_staff, :phoenix_kit_projects]]
end
```

Run `mix deps.get`, then toggle the module on from **Admin > Modules**.

## Database

Tables are created by the **V101** versioned migration inside `phoenix_kit` core. V101 depends on V100 (staff tables). Run via `mix phoenix_kit.install` / `mix phoenix_kit.update` in the parent app.

Tables created:

- `phoenix_kit_project_tasks` (reusable library)
- `phoenix_kit_project_task_dependencies` (template-level)
- `phoenix_kit_projects`
- `phoenix_kit_project_assignments` (with `CHECK` that at most one assignee is set)
- `phoenix_kit_project_dependencies` (per-project)

All tables use UUIDv7 primary keys.

## Public API

See `PhoenixKitProjects.Projects` — the single context module covers tasks, projects, templates, assignments, dependencies, and schedule/summary computation. Highlights:

```elixir
# Projects
Projects.list_projects/1          # :status, :include_templates
Projects.project_summaries/1      # batch query — no N+1
Projects.recompute_project_completion/1

# Tasks
Projects.list_tasks/0
Projects.create_task/1

# Assignments (form-facing vs. server-trusted split)
Projects.create_assignment/1
Projects.update_assignment_form/2    # safe: mass-assignment guard
Projects.update_assignment_status/2  # server-trusted: completion fields
Projects.complete_assignment/2
Projects.reopen_assignment/1

# Dependencies
Projects.add_dependency/2   # refuses cycles
Projects.dependencies_met?/1
Projects.available_dependencies/2

# Templates
Projects.list_templates/0
Projects.create_project_from_template/2  # atomic clone
```

## Development

See [`AGENTS.md`](AGENTS.md) for development conventions, test setup, and the pre-commit workflow.

## License

MIT
