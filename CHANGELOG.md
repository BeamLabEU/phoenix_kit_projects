# Changelog

## 0.1.1

Quality sweep + re-validation pass (PR #2) plus post-merge follow-up
fixes (PR #2 review).

### Added

- `Activity.log_failed/2` helper that tags `metadata.db_pending = true`
  so audit-feed readers can distinguish attempted-but-failed mutations
  from completed ones during a DB outage.
- `@spec` declarations across the public `Projects` context API
  (~32 functions) plus shared `@type uuid` and `@type error_atom`.
- `error_summary/2` translates Ecto validator messages via
  `Gettext.dgettext`/`dngettext` against the `errors` domain, and
  humanizes field names in the cross-field flash summary.
- Test infrastructure: full LiveView smoke-test stack
  (`PhoenixKitProjects.LiveCase`, `Test.Endpoint`, `Test.Router`,
  `assign_scope` hook, `assert_activity_logged/2`), self-contained
  setup migration under `test/support/postgres/migrations/`, and
  `test.setup` / `test.reset` mix aliases.

### Changed

- `Activity.log/2` rescue widened to the canonical post-Apr shape
  (`Postgrex.Error -> :ok`, `DBConnection.OwnershipError -> :ok`,
  `e -> Logger.warning`, `catch :exit, _ -> :ok`).
- `enabled?/0` gained `catch :exit, _ -> false` for sandbox-shutdown
  resilience.
- `recompute_project_completion/1` now wraps the read + check + update
  in a transaction so two concurrent assignment status changes can't
  double-mark a project completed.
- `add_dependency/2` runs the cycle check + insert in a `:serializable`
  transaction; concurrent edge inserts that would close a cycle now
  fail with a friendly retry-hint changeset error.
- `create_project_from_template/2` opens its outer transaction at
  `:serializable` so the cycle-race protection inside `add_dependency/2`
  actually applies on the template-cloning path (Postgres ignores
  isolation level on nested transactions).
- All 5 admin LiveViews emit `Logger.debug` on `handle_info` catch-alls
  (was silent).
- `phx-disable-with` on every destructive `phx-click` site
  (`project_show_live` × 9, `assignment_form_live` × 3, `task_form_live` × 2,
  delete buttons in `projects_live` / `tasks_live` / `templates_live`).
- `Project.changeset/2` `name_index_for/2` picks the partial-index
  constraint name based on `is_template`, so a template and a project
  can share a name freely. Coercion accepts the full set of truthy
  forms (`true`, `"true"`, `"1"`, `1`, `"on"`).
- Cross-module schema typespecs relaxed to `struct() | nil` until
  `phoenix_kit_staff` 0.1.1 ships `@type t` declarations
  (tracking: `BeamLabEU/phoenix_kit_staff#3`).

### Fixed

- `add_dependency/2` was TOCTOU under concurrent inserts (PR #1
  review #2).
- `assignment_status_counts/0` was filtering on `is_template == false`
  but not `status == "active"`, inflating the dashboard's todo /
  in_progress / done totals with archived projects' assignments
  (PR #1 review #4).
- Template + project name unique-constraint collision via core's
  V105 partial-index split (PR #1 review #5).
- `apply_template_dependencies/1` rollback no longer silently
  swallowed — surfaces a `:warning` flash + Logger.warning
  (PR #1 review #6).
- `do_update_progress/3`, `save_duration`, and `remove_dependency`
  in `ProjectShowLive` now route their error branches through
  `Activity.log_failed/2`, closing the `db_pending: true` invariant
  gap surfaced by the PR #2 review.
- `test_helper.exs` no longer hard-fails when `psql` is missing —
  the reachability probe falls through to the connect-attempt path,
  matching the AGENTS.md "never hard-fail on a missing DB" contract.

### Coverage / quality

- Test count: 56 → 355 (+299), 0 flakes across 10/10 stable runs.
- Line coverage: 37.02% → 91.80%.
- Dialyzer: 6 pre-existing unknown-type warnings → 0 errors.
- Credo `--strict`: 0 issues.

## 0.1.0

- Initial release: project + task management with polymorphic assignees
  (team / department / person), per-project and template-level dependencies
  with cycle detection, atomic template cloning, weekday-aware schedule math,
  PubSub broadcasts, and activity logging.
