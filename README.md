# PhoenixKitProjects

A [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit) plugin for **project + task management**: a reusable task library, projects that pull tasks in as assignments, per-project and per-template dependencies, schedule math with weekday/calendar awareness, and assignees sourced from [`phoenix_kit_staff`](https://github.com/BeamLabEU/phoenix_kit_staff).

## Features

- **Task library** — reusable tasks with description, estimated duration, default assignee ("template" is reserved for project templates)
- **Projects** — containers with `immediate` or `scheduled` start mode, completion auto-detection
- **Assignments** — task instances inside a project; editable independently of the template
- **Dependencies** — per-project ("A must finish before B") with multi-hop cycle detection
- **Default dependencies** — declared on the library task, auto-applied when both tasks are in the same project
- **Templates** — project templates cloned into real projects inside a single transaction
- **Assignees** — any number of people, teams and departments on a task, a project (a sub-project too) and a library task, all equal (`AssigneeSet`)
- **Sub-projects** — a task row can be a whole project of its own, nested to eight levels, rolled up into its parent
- **Subtasks and the typed list** — tasks under tasks at any depth; a project's list can be typed like a to-do list
- **Schedule math** — planned vs. projected end with velocity tracking; per-task `counts_weekends` override
- **Timeline & Calendar views** — every project has List/Timeline/Calendar tabs over one shared schedule walk (`ScheduleLayout`)
- **Quick-add** — "Add a task" under a project's task list opens the add-task sheet with the cursor in the title: Enter adds and closes, Shift+Enter adds and starts the next task on a fresh form, Esc closes; new tasks are one-off unless "Add to the task library" is ticked
- **Forms in a drawer** — on a project page every form (add/edit task, sub-project, edit project) opens as a right-hand sheet over the plan instead of a separate page; a save closes it and the plan updates, an edited form guards against a stray Esc/backdrop, and the same pages still answer at their own URLs for deep links
- **Overview & dashboards** — the landing page is the project list, the Overview (running projects, calendar, my tasks) is the last subtab, and the same pieces are available as widgets for `phoenix_kit_dashboards` boards
- **Assignee filters** — a Filters panel on both calendars: multi-person typeahead (DB-paged), Unassigned lens, personal-only and overdue-only refinements, with inherited team/department semantics (`Assignees`)
- **Dashboard widgets** — ten widgets for `phoenix_kit_dashboards` (board, workload, my tasks, ongoing tasks, running, upcoming, deadlines, calendar, per-project status and schedule), duck-typed, crash-isolated and scoped to what the reader may open
- **Per-project hub** — files, whiteboards, events, discussions, an Hours tab and a public issue portal, each switched per project; feature flags inside each
- **JSON API** (`/api/projects/v1`) — API keys with per-project access for agents and integrations; the contract is generated as `llms.txt` and `openapi.json` (see `dev_docs/guides/api.md`)
- **Hours and Time** — the work ledger read back by person, task, project and day, with a printable report; the Time page sets each task's plan against what really happened
- **Mass-assignment guard** — `completed_by_uuid` / `completed_at` can only be set through the server-trusted `status_changeset/2`
- Real-time updates via `PhoenixKit.PubSub.Manager`
- Activity logging for every mutation
- Admin pages under `/admin/projects/*`

## Installation

Add to your parent PhoenixKit app's `mix.exs`:

```elixir
{:phoenix_kit_projects, "~> 0.33"}
```

(For local development inside the PhoenixKit workspace, use the path-dep form instead: `{:phoenix_kit_projects, path: "../phoenix_kit_projects"}`.)

`phoenix_kit_staff` and `phoenix_kit_entities` come with it as dependencies: this module's migrations reference their tables, so their migrations run first. This module maps its own read-only shadow schemas over staff's tables for the polymorphic assignee.

Also add the apps to `extra_applications` so `PhoenixKit.ModuleDiscovery` finds them:

```elixir
def application do
  [extra_applications: [:logger, :phoenix_kit, :phoenix_kit_projects]]
end
```

Run `mix deps.get`, then toggle the module on from **Admin > Modules**.

## Database

Tables are created by this module's own versioned chain, `PhoenixKitProjects.Migrations.Schema`, which runs staff's and entities' chains first. Run via `mix phoenix_kit.install` / `mix phoenix_kit.update` in the parent app.

The core tables are `phoenix_kit_projects`, `phoenix_kit_project_tasks` (the
reusable library), `phoenix_kit_project_assignments` (a task in a project),
`phoenix_kit_project_dependencies` and `phoenix_kit_project_task_dependencies`;
around them the chain adds members, group grants, extensions, the work ledger,
labels, whiteboards, events, the portal, API keys, task files and the assignee
sets — the full list is in [`AGENTS.md`](AGENTS.md) → "Data model". All tables
use UUIDv7 primary keys.

## Public API

See `PhoenixKitProjects.Projects` — the single context module covers tasks, projects, templates, assignments, dependencies, and schedule/summary computation. Highlights:

```elixir
# Projects
Projects.list_projects/1          # :archived, :include_templates, :viewer
Projects.create_project/2         # a key suggested from the name; presets
Projects.project_summaries/1      # batch query — no N+1
Projects.recompute_project_completion/1

# Tasks (the library)
Projects.list_tasks/1
Projects.create_task/1

# Assignments (form-facing vs. server-trusted split)
Projects.create_assignment/2
Projects.update_assignment_form/3    # safe: mass-assignment guard
Projects.update_assignment_status/3  # server-trusted: completion fields; `expect:`
Projects.complete_assignment/2
Projects.reopen_assignment/1

# Dependencies
Projects.add_dependency/3   # refuses cycles and cross-project pairs
Projects.available_dependencies/2

# Templates
Projects.list_templates/1
Projects.create_project_from_template/3  # atomic clone
```

## Development

See [`AGENTS.md`](AGENTS.md) for development conventions, test setup, and the pre-commit workflow.

## License

MIT
