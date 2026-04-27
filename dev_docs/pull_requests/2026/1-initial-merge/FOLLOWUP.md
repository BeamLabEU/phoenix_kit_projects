# Follow-up — PR #1 (initial merge) review items

**Date:** 2026-04-27
**Reviewer artifact:** `CLAUDE_REVIEW.md` (Claude)

Phase 1 triage of the Claude review on PR #1 (initial merge —
schemas, context, LiveViews, scaffolding, +6,297 / −1). Findings
re-verified against `main` (`5cafb65`).

## Fixed (Batch 1 — 2026-04-27)

### Test infra prerequisite — local setup migration

The original `test_helper.exs` defined `PhoenixKitProjects.Test.SetupMigration`
inline and called `Ecto.Migrator.up/4` on a wrapper that delegated to
`PhoenixKit.Migrations.up()`. That delegate only knows about the V's
bundled inside the resolved `phoenix_kit` package — Hex `1.7.95`
reaches V96 today, so on a fresh `phoenix_kit_projects_test` DB the
migration created V01..V96 tables but stopped before V100 (staff) +
V101 (projects), breaking every integration test at table-create
time.

Switched to the workspace-standard pattern (locations / hello_world):

- New `test/support/postgres/migrations/20260427000000_setup_phoenix_kit.exs`
  — calls `PhoenixKit.Migrations.up()` for V01..V96 prereqs, then
  inlines V100 staff DDL and V101 projects DDL verbatim from
  core. Wrapped in `IF NOT EXISTS` so once core publishes a release
  containing V100 + V101, the inline blocks become no-ops.
- `config/test.exs` — adds `priv: "test/support/postgres"`.
- `mix.exs` — adds `test.setup` / `test.reset` aliases and a `cli`
  block with `preferred_envs: [test.setup: :test, test.reset: :test]`.
- `test_helper.exs` — drastically simplified (removed inline
  migration + Ecto.Migrator dispatch; added Hammer's
  `RateLimiter.Backend.start_link/1` to mirror core).

After this, `mix test` runs cleanly against the Hex `phoenix_kit ~> 1.7`
dep — no temp `path:` override required. First-time setup is
`createdb phoenix_kit_projects_test && mix test.setup`; subsequent
`mix test` just runs.

### BUG - HIGH

- **#2 — `would_create_cycle?` was TOCTOU** —
  `lib/phoenix_kit_projects/projects.ex` `add_dependency/2`. Two
  concurrent `add_dependency(A, B)` and `add_dependency(B, A)`
  requests could each read an acyclic graph, both pass the cycle
  check, both insert, and produce a cycle (the unique pair index
  doesn't catch this — only identical duplicate edges). Fixed by
  wrapping the cycle check + insert in a `:serializable` transaction
  via `repo().transaction(fn -> ... end, isolation: :serializable)`,
  with a `Postgrex.Error` rescue translating the `:serialization_failure`
  SQLSTATE 40001 into a friendly changeset error
  (`gettext("conflicting dependency change in flight, please retry")`)
  so the LV can surface it. Documented the rationale in the function's
  `@doc`.

- **#3 — PubSub topics not tenant-scoped** — *deferred via doc note*.
  `lib/phoenix_kit_projects/pub_sub.ex` `@moduledoc` now spells out
  that topics are global today because PhoenixKit core does not
  expose a per-tenant scope, no other feature module
  (`locations`/`staff`/`sync`/...) does multi-tenant PubSub
  partitioning, and the right framework-wide shape would be to thread
  org/tenant keys through every topic when core grows that capability.
  Per `feedback_quality_sweep_scope.md` — quality sweeps refactor
  existing paths, they don't add missing features — so this remains
  deferred until core does. Caller-side `:project:<uuid>` topic is
  already safe (need the UUID to subscribe).

### BUG - MEDIUM

- **#4 — `assignment_status_counts/0` ignored `status` filter** —
  `lib/phoenix_kit_projects/projects.ex:296-306`. Query selected
  `is_template == false` but did not narrow on `status == "active"`,
  so archived projects' assignments inflated the dashboard's
  todo/in_progress/done totals. Fixed by adding the active filter to
  match `list_active_projects/0`'s intent. Updated `@doc` to spell
  out the rationale.

- **#6 — `apply_template_dependencies/1` failure was silently
  swallowed** — `lib/phoenix_kit_projects/web/assignment_form_live.ex:259-278, 296-318`.
  Both call sites discarded the return value and unconditionally
  flashed success even when the transaction rolled back, so the user
  saw "Task created" but template-default deps never landed. Fixed
  by extracting `flash_for_template_deps/2` which inspects the
  return shape (`:ok | {:ok, _} | {:error, _}`), logs a warning on
  rollback, and returns a `:warning` flash distinguishing partial
  success ("Task added, but applying default dependencies failed").
  The assignment is still created — only the deps roll back — so
  `:warning` is the right kind, not `:error`.

### IMPROVEMENT - MEDIUM

- **#8 — dead `count_assignments/1` removed** —
  `lib/phoenix_kit_projects/projects.ex:669-674`. No callers in
  `lib/` or `test/`. Deleted.

- **#11 — local `actor_uuid/1` consolidated onto
  `Activity.actor_uuid/1`** —
  `lib/phoenix_kit_projects/web/project_show_live.ex:181-186`. The
  same case-on-assigns body was duplicated in three places
  (overview/projects already used the shared helper; only
  project_show held its own copy). Replaced all 14 internal
  references and removed the local helper.

### NITPICK

- **#14 — duplicate `single_assignee` error message extracted to a
  private helper** —
  `lib/phoenix_kit_projects/schemas/assignment.ex:96, 114`. The
  `gettext("only one of team, department, or person can be assigned")`
  literal lived twice (validator + check_constraint). Extracted to
  `single_assignee_message/0`; both call sites now reference it. The
  gettext extractor still sees the literal at the helper definition,
  so translations stay extractable.

- **#17 — `@doc` line added to `list_assignments_for_user/1`
  flagging the rescue as intentional** —
  `lib/phoenix_kit_projects/projects.ex:308-318`. The
  `rescue [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError]`
  exists because Staff is a hard dep that shouldn't be allowed to
  take down the Projects dashboard during install/test/transient-drop
  scenarios. Documented so future maintainers don't "clean it up".

## Fixed (pre-existing — verified, no Batch-1 work needed)

- **#13 — scaffolding files** — `LICENSE`, `CHANGELOG.md`,
  `.credo.exs`, and `.gitignore` are present (commit `2b025e7`,
  "Add release scaffolding and prep 0.1.0"). `mix.exs`
  `package.files` lists `README.md` and `CHANGELOG.md` per
  PINCER-style template. No further work.

## Deferred to Phase 2 quality sweep (with rationale)

These are real findings but they're sweep-shaped (C-step territory)
rather than PR-followup-shaped, and bundling them into Phase 1 would
expand scope past one logical commit.

- **#1 — mount queries fire twice (HTTP render + WS connect)** —
  every LV (`overview`, `projects`, `tasks`, `templates`,
  `project_show`, all 4 form LVs) does DB work in `mount/3` instead
  of `handle_params/3`. ~10–14 queries per dashboard visit on
  `OverviewLive` alone. **Phase 2 C5 (async UX)** is the natural
  home: refactoring `mount → handle_params` is per-LV work that
  should land alongside the rest of the C5 deltas (phx-disable-with,
  validate `:action`, etc.). Tracked here so it doesn't get lost.

- **#7 — `OverviewLive.handle_info({:projects, _, _})` reloads the
  entire dashboard on every event** — refires ~10 queries on any
  mutation anywhere, even a task rename in a distant project.
  N-by-M amplification with multiple admins. **Phase 2 C5/C6** —
  needs per-event-type minimal-delta logic plus a debounce.

- **#9 — redundant `unique_constraint` field-list + named-name in
  `Dependency`/`TaskDependency`** —
  `lib/phoenix_kit_projects/schemas/dependency.ex:32-35`,
  `task_dependency.ex:32-35`. Cosmetic; **Phase 2 C6 cleanup**.

- **#10 — `test_helper.exs` shells out to `psql`** — same shape as
  staff and core. Reviewer's suggestion (drop the `psql` check, rely
  purely on `try TestRepo.start_link/0` rescue) is reasonable but
  changes the cross-module convention. **Phase 2 C7 (test infra)**.

- **#12 — `remove_dependency` event hits `scoped_assignment/2`
  twice** — `lib/phoenix_kit_projects/web/project_show_live.ex:384-402`.
  Two round-trips where one combined query suffices.
  **Phase 2 C6 cleanup**.

- **#15 — `error_summary/2` renders raw validator messages without
  gettext** — `lib/phoenix_kit_projects/web/project_show_live.ex:137-147`.
  Strings like `"is invalid"` / `"must be greater than 0"` render
  in English regardless of locale. Properly fixed when the module
  gains an Errors atom dispatcher in **Phase 2 C3**.

- **#16 — `Project.counts_weekends` optional-but-defaults-to-`false`** —
  `lib/phoenix_kit_projects/schemas/project.ex:25, 37`. Reviewer
  flagged that the cast allows `nil` even though the schema default
  is `false`. Currently no caller observes this since `clone_template`
  passes the bool via `to_string/1`. `validate_required/2` would
  make intent honest. **Phase 2 C6**.

### #5 — Template name + project name share one unique index

`lib/phoenix_kit_projects/schemas/project.ex:47-50` and the V101
migration. `phoenix_kit_projects_name_index` was a single global
unique constraint over the `phoenix_kit_projects` table, so a
template named "Onboarding" and a real project named "Onboarding"
couldn't coexist — and `create_project_from_template/2` doesn't
auto-mangle names, so cloning failed unless the caller renamed.

**Fixed via Option A (partial indexes via new core migration).**

- **`phoenix_kit/lib/phoenix_kit/migrations/postgres/v105.ex`** —
  NEW (uncommitted upstream — boss-only release work). Drops the
  single `phoenix_kit_projects_name_index` and creates two partial
  unique indexes:
  `phoenix_kit_projects_name_template_index UNIQUE (lower(name)) WHERE is_template = true`
  and the symmetric `..._name_project_index WHERE is_template = false`.
  `phoenix_kit/lib/phoenix_kit/migrations/postgres.ex` `@current_version`
  bumped from 104 → 105.
- **`lib/phoenix_kit_projects/schemas/project.ex`** — `changeset/2`
  no longer hard-codes `name: :phoenix_kit_projects_name_index`. New
  private `name_index_for/2` helper picks the partial-index name that
  matches the row's `is_template` value (reads from `attrs`,
  falling back to the existing struct), so Ecto attaches the
  uniqueness error to the correct field on collision.
- **`test/support/postgres/migrations/20260427000000_setup_phoenix_kit.exs`** —
  added Stage 4 mirroring V105: `DROP INDEX IF EXISTS` + the two
  partial `CREATE UNIQUE INDEX IF NOT EXISTS`. Idempotent against
  any future Hex release containing V105.
- **`test/phoenix_kit_projects/integration/template_clone_test.exs`** —
  added 3 regression tests pinning the new behavior:
  template + real project can share a name; two templates with the
  same name still collide; two real projects with the same name
  still collide.

After the next `phoenix_kit` Hex release that includes V97–V105,
host apps that already had the single global index will auto-migrate
on first deploy. Hosts that haven't migrated past V101 yet will get
V105 as part of the V01..V105 chain on first run.

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_projects/projects.ex` | #2 wrap `add_dependency/2` cycle check + insert in `:serializable` transaction with `Postgrex.Error` rescue for SQLSTATE 40001; #4 add `status == "active"` filter to `assignment_status_counts/0`; #8 delete `count_assignments/1`; #17 expand `@doc` on `list_assignments_for_user/1` flagging the rescue as intentional |
| `lib/phoenix_kit_projects/pub_sub.ex` | #3 expand `@moduledoc` with the deferred-tenant-scoping rationale and the future shape |
| `lib/phoenix_kit_projects/schemas/project.ex` | #5 `changeset/2` picks the V105 partial-index constraint name via new `name_index_for/2` helper based on `is_template` |
| `lib/phoenix_kit_projects/schemas/assignment.ex` | #14 extract `single_assignee_message/0`, replace duplicate gettext literals at validator + check_constraint |
| `test/phoenix_kit_projects/integration/template_clone_test.exs` | #5 new `describe "V105 partial-index name uniqueness"` block with 3 tests |
| `test/support/postgres/migrations/20260427000000_setup_phoenix_kit.exs` | #5 added Stage 4 inlining V105 partial-index conversion (drop single global, create two partials) |
| `lib/phoenix_kit_projects/web/project_show_live.ex` | #11 replace local `actor_uuid/1` with `Activity.actor_uuid(socket)` (14 call sites + helper deletion) |
| `lib/phoenix_kit_projects/web/assignment_form_live.ex` | #6 capture `apply_template_dependencies/1` return, surface rollback via `:warning` flash + Logger.warning; new `flash_for_template_deps/2` helper |
| `test/test_helper.exs` | start `PhoenixKit.Users.RateLimiter.Backend`; remove inline `SetupMigration` + `Ecto.Migrator.up` dispatch |
| `test/support/postgres/migrations/20260427000000_setup_phoenix_kit.exs` | NEW — V01..V96 prereqs + V100 staff DDL + V101 projects DDL inlined for test-only schema setup |
| `config/test.exs` | add `priv: "test/support/postgres"` to repo config |
| `mix.exs` | add `cli/0` with `preferred_envs:` for `test.setup`/`test.reset`; add `test.setup`/`test.reset` aliases |

## Verification

- `mix format` — clean.
- `mix compile --warnings-as-errors` — clean.
- **`mix test` against the Hex `phoenix_kit ~> 1.7` + `phoenix_kit_staff ~> 0.1`
  deps (no path override)** — **56 tests, 4 failures**. +3 tests over the
  53-test pre-edit baseline (the new `V105 partial-index name uniqueness`
  describe block — all pass). The 4 failures match the pre-existing
  baseline; no regressions introduced. Pre-existing failure details
  below in "Open".

## Open

### Pre-existing test failures (not introduced by this batch)

`test/phoenix_kit_projects/integration/assignments_test.exs` —
**4 of 53 tests fail on `main`** (without my changes), all in
`AssignmentsTest`:
- `complete_assignment/2 + reopen_assignment/1 complete sets status and completion fields` (line 95)
- `complete_assignment/2 + reopen_assignment/1 reopen clears completion fields`
- `mass-assignment guard update_assignment_status DOES apply completed_by_uuid/completed_at`
- `PubSub broadcast complete_assignment fires the same broadcast (sugar helper parity)`

Same root cause: each passes a fake `actor` `%User{uuid: "..."}` to
`Projects.complete_assignment/2`, but the V100 schema added a
`completed_by_uuid` FK referencing `phoenix_kit_users(uuid)`. The
test fixture never seeds the user, so the UPDATE raises
`Ecto.ConstraintError`. Phase 2 C8 territory — needs a real-user
fixture before calling `complete_assignment`. Confirmed pre-existing
by stashing my edits and re-running.
