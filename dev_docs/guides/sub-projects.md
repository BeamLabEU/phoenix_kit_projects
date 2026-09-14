# Sub-projects (project-as-task)

The data model, rollup, context API, UI and linking guards behind a project
nested inside another project's task timeline. Also covers the project-level
assignee, which sub-projects inherit by being projects.

Rules for this live in [AGENTS.md](../../AGENTS.md) → Feature notes.

A **sub-project** is a project embedded inside another project's task
timeline. The model is an `Assignment` that points at a child `Project`
via a nullable `child_project_uuid` **instead of** a task template — so a
sub-project gets dependencies and drag-reorder *for free* (both are already
assignment-level and project-scoped, no changes there).

## Data model

- `phoenix_kit_project_assignments.child_project_uuid` → FK
  `phoenix_kit_projects(uuid) ON DELETE RESTRICT`. `task_uuid` lost
  its `NOT NULL`; a DB `CHECK ((task_uuid IS NOT NULL) <> (child_project_uuid
  IS NOT NULL))` enforces **exactly one** of task/child-project (mirrored by
  `Assignment.validate_task_xor_child/1`). A partial **unique** index on
  `child_project_uuid` makes a project the child of **at most one** parent.
- `RESTRICT` (not `CASCADE`) is deliberate: a stray child-project delete
  fails loudly instead of silently mutating a parent's task list. Recursive
  teardown is orchestrated in the context (in a transaction), not by the DB.

## Source of truth + rollup (denormalized, NOT computed-on-read)

The **child project is the source of truth**; the parent's linking
assignment carries **denormalized rollup fields** (`status` /
`progress_pct` / `estimated_duration` / `completed_at`) synced whenever the
child changes. So every existing read site (schedule math,
`recompute_project_completion`, dashboards, sorting, `project_summaries`)
keeps working **unchanged** — no per-read polymorphic branch.

- `child_project_rollup/1` snapshots the child's summary into the shape
  `Assignment.subproject_changeset/2` casts. Hours are stored in **minutes**
  (`round(total_hours * 60)`, unit `"minutes"`) so sub-hour child totals
  survive the integer `estimated_duration` column. A **completed** sub-project
  reads as 100% (the module's `progress_pct` is the slider average, and
  completing a task doesn't move its slider).
- **Upward propagation:** `recompute_project_completion/2` tail-calls
  `propagate_rollup_to_parent/2` — after a child settles, it refreshes the
  parent's linking row and recomputes the parent, climbing the tree one level
  at a time. Bounded by `@max_rollup_depth` (64) as a fail-closed guard; the
  tree is acyclic by construction (single-parent unique index + inline-only
  creation).
- `batched_planned_hours/2` uses a **LEFT** join to `:task` so sub-project
  rows (no task) aren't dropped; their hours come from the denormalized
  `estimated_duration`.

## Context API

- `create_subproject/2` — one transaction: creates the child project
  (immediate-start, not a template) + the linking assignment. Rejects
  template parents (`:template_subproject_unsupported`) and unknown parents
  (`:parent_not_found`).
- `delete_assignment/1` — for a sub-project row, deletes the child project
  subtree (linking row first, then the tree) in a transaction.
- `delete_project/1` — recursive over sub-project descendants
  (`delete_project_tree_in_tx/1`); broadcasts `:project_deleted` per node.
- `list_projects/1` + dashboard buckets + `count_projects/1` **exclude**
  projects that are someone's child (`exclude_subprojects/1`, a self-correcting
  `NOT IN` subquery) — sub-projects are reached by drilling into the parent,
  never shown as standalone rows. `assignment_status_counts/0` excludes the
  rollup-placeholder linking rows (`is_nil(child_project_uuid)`).
- `Assignment.label/2` — single locale-aware display helper (child name OR
  task title); used by every render site (timeline, dependency badge, comment
  header, remove-confirm, activity metadata) so none dereferences a nil task.

## Templates

Sub-projects work on templates too: `create_subproject/2` makes the child
inherit the parent's `is_template` flag, so a sub-project added to a template is
itself a **sub-template**. `create_project_from_template/2` **deep-clones** the
whole sub-project subtree — `clone_subproject_assignment_in_tx/2` →
`deep_clone_project_in_tx/2` recursively copies each child template into a fresh
real project and re-links it (the single-parent unique index forbids two parents
sharing a child, so the deep copy is mandatory, not optional). Sub-templates are
hidden from `list_templates/0` / `count_templates/0` via `exclude_subprojects/1`,
same as sub-projects are hidden from the projects list.

## Dashboard (hierarchical, `OverviewLive` + `RunningCard`)

`Projects.project_tree_summary/1` returns a recursive node (per-level task
breakdown + nested children); the Running card renders it as an indented
outline — top summary (`N tasks · M sub-projects`) + status breakdown
(`X done · Y in progress · Z todo`) + each sub-project nested with its own
summary/breakdown, all the way down. **Empty sub-projects are neutral in the
progress average** (excluded from both `project_summaries/1`'s `progress_pct`
and the tree node's) so they don't drag a parent's % down before they have
tasks. The top node still carries `total` / `progress_pct` / `planned_end`, so
the tier + sort helpers read it like the old flat summary.

## UI (`ProjectShowLive`)

- **Add/edit via the same form tasks use** — "Add sub-project" (on projects
  **and** templates) links to `AssignmentFormLive` with `?kind=subproject`
  (carried through emit via `resolve_action_params`'s `"kind"`); the sub-project
  row's Actions → "Edit" opens `AssignmentFormLive(:edit)` on the linking row.
  In sub-project mode the form is a top-level render branch (`@kind ==
  "subproject"`, the task form path untouched): name + description + assignee
  (a `%Project{}`/child changeset as `@sp_form`, `as: :subproject`) plus the
  **standard dependency section** — pending deps on `:new`, live add/remove on
  `:edit`, reusing the existing `add_pending_dep`/`add_assignment_dep` handlers.
  `save_subproject` → `create_subproject/2` + `flush_pending_deps` (new) or
  `update_project/2` (edit). **No bespoke inline dependency picker, no modal** —
  a sub-project's dependencies live on its add/edit page like any task's.
- **Create new vs. nest existing** — on `:new` the sub-project form shows a
  `<.nav_tabs on_change="set_sp_mode">` ("Create new" / "Nest existing"). "Nest
  existing" swaps the create-new fields for a single `link_child_uuid` picker of
  `available_projects_to_link/1` (standalone, same `is_template`, not the parent
  or an ancestor); submit routes to `link_subproject/2` instead of
  `create_subproject/2`. The picker form renders **no** `subproject[...]` inputs,
  so `validate_subproject`/`save_subproject` have catch-all clauses for the
  no-`"subproject"`-key payload. The inverse is the sub-project row's Actions →
  **"Make standalone"** (`detach_subproject` on the show LV) which deletes only
  the linking assignment (`data-confirm`), leaving the child + its subtree as a
  top-level project. Both emit `projects.subproject_linked` /
  `projects.subproject_detached`.
- The sub-project row is a read-only variant (child name + "Sub-project" badge +
  rolled-up tasks/hours/progress). A chevron toggles a slide-down panel
  (`toggle_subproject`) revealing the child's tasks **rendered with the same
  `task_body/1` component as the top-level timeline, just inset**
  (`draggable={false}`); nested sub-projects show as a compact link. Child-task
  events work because `scoped_assignment/2` accepts any displayed assignment and
  `recompute_owning_subproject/2` recomputes the child's project so the rollup
  climbs. There's an "Open sub-project" link to the child's full page.
  Dependencies render and can be added/removed on the row (`add_subproject_dep`
  reuses `available_dependencies` + `add_dependency`). Drag-reorder works
  unchanged (the row is a `sortable-item`).
- Activity: `projects.subproject_created` / the existing
  `projects.assignment_removed` on teardown.

## Assignee on projects + sub-projects

A project carries the same polymorphic assignee as a task — `assigned_team_uuid`
/ `assigned_department_uuid` / `assigned_person_uuid` on `phoenix_kit_projects`,
one-of via a `num_nonnulls(...) <= 1` CHECK + `Project.validate_single_assignee/1`.
Because a sub-project IS a project, this one set of columns covers assigning a
sub-project too (its assignee lives on the child project row). `ProjectFormLive`
gains the team/department/person picker (mirrors `AssignmentFormLive` —
`assign_type` + `clear_other_assignees/2`); the **Add sub-project** modal carries
the same picker so you can assign at creation (`subproject_assignee_attrs/1` →
`create_subproject/2`). Display reuses the show LV's `assignee_type/1` +
`assignee_label/1` (they already work on any record with the assignee fields) on
the project header and each sub-project row; `get_project_with_assignee/1` +
the deep child preload in `@assignment_preloads` load the names.

## Linking guards (cycle-safe)

`link_subproject/2` is the "nest an existing project" path. It validates before
assigning `child_project_uuid`: `:self_link` (parent == child), `:kind_mismatch`
(`is_template` differ), `:would_create_cycle` (`child.uuid in
project_ancestor_uuids(parent.uuid)` — `walk_ancestors/2` climbs linking rows),
and `:already_subproject` (the partial unique index on `child_project_uuid`,
caught at insert and mapped). The depth-capped propagation still fails closed on
corrupt data as a backstop.

## Cross-repo schema dependency

The columns behind sub-projects and the project-level assignee live in **core
`phoenix_kit`**, well below this module's current core floor, so the features
run against any core the pin admits. The pattern still applies to the *next*
cross-repo schema change: a migration this module needs can't run until core
releases it and the `mix.exs` pin is bumped. While iterating ahead of a core
release, develop/test locally via `PHOENIX_KIT_PATH=../phoenix_kit` (see
`pk_dep/3` in `mix.exs`). Tests:
`test/phoenix_kit_projects/integration/subprojects_test.exs` (context) +
`test/phoenix_kit_projects/web/project_show_subprojects_test.exs` (LV render).
