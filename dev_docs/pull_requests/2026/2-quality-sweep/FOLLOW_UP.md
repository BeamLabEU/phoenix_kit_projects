# Follow-up — PR #2 (quality sweep + re-validation)

**Date:** 2026-04-28
**Reviewer artifacts:** none — this is a self-driven post-Apr 2026
re-validation pass. The original quality sweep landed in commits
`a4b4612` (Phase 1 PR #1 follow-ups) + `2e70505` (Phase 2 sweep).
This document records what the re-validation added on top.

## Re-validation triage (Phase 1 PR #1 — re-verified)

`dev_docs/pull_requests/2026/1-initial-merge/FOLLOWUP.md` re-checked
against current code:

- **All Batch 1 fixes still in place** — verified via grep:
  `add_dependency/2` `:serializable` transaction at
  `lib/phoenix_kit_projects/projects.ex:765`, `assignment_status_counts/0`
  active filter at `:309`, `name_index_for/2` at
  `lib/.../schemas/project.ex:79`, `single_assignee_message/0` at
  `lib/.../schemas/assignment.ex:148`, `Activity.actor_uuid/1`
  consolidation across all 14 call sites in `project_show_live.ex`,
  `flash_for_template_deps/2` at `assignment_form_live.ex:334`.
- **Pre-existing 4-test failure on `assignments_test.exs`** (the
  `complete_assignment` paths needing real users) — already
  resolved by the original Phase 2 sweep's `real_user_uuid!/0`
  helper. 0 failures throughout this re-validation pass.

## Phase 2 — three C12 Explore agents (2026-04-28)

Run verbatim against the workspace AGENTS.md prompts. Each surfaced
gaps the original sweep predates:

- **Security + error + async UX** — 9 destructive `phx-click` sites
  in `project_show_live.ex` missing `phx-disable-with` (the residual
  surfaced in the original sweep entry of workspace AGENTS.md);
  2 secondary form buttons same; `enabled?/0` missing `catch :exit`;
  `Activity.log/2` rescue not in canonical post-Apr shape.
- **Translations + activity + tests** — `error_summary/2` raw
  validator messages (Phase 1 deferred #15); 8 LV handlers missing
  error-branch activity logging; all 5 LV catch-alls silent (no
  `Logger.debug`); edge-case test gaps.
- **PubSub + cleanliness + public API** — `~45+ public functions
  in projects.ex missing @spec`; `recompute_project_completion/1`
  check-then-act race (no transaction); pre-existing dialyzer
  warning on cross-module schema typespecs (staff Hex 0.1.0 lacks
  `@type t`).

C12.5 deep dive consolidated: agents covered the categories well
for a module of this size; no additional findings beyond what the
three agents surfaced.

## Fixed (Batch 2 — structural pipeline deltas, 2026-04-28)

Closes the post-Apr 2026 pipeline deltas the original sweep predates;
no functional change to the user-visible feature set.

- `enabled?/0` `catch :exit, _ -> false` — sandbox-shutdown trap
  (workspace AGENTS.md "Known flaky-test traps").
- `Activity.log/2` rescue widened to canonical post-Apr shape:
  `Postgrex.Error -> :ok` / `DBConnection.OwnershipError -> :ok` /
  `e -> Logger.warning` / `catch :exit, _ -> :ok`. Per
  publishing-Batch-5 trap.
- `handle_info` catch-all promoted from silent to `Logger.debug`
  on all 5 admin LVs. Each gained `require Logger`.
- `phx-disable-with` on every destructive `phx-click` site:
  `project_show_live.ex` × 9 (start_project ×2, start_task,
  complete, reopen, remove_assignment, toggle_tracking ×2,
  remove_dependency); `assignment_form_live.ex` × 2 (add /
  remove_assignment_dep); `task_form_live.ex` × 2 (add_dep /
  remove_dep).
- AGENTS.md "What this module does NOT have" canonical section
  pinning deliberate non-features.
- `mix.exs` `test_coverage [ignore_modules]` filter.
- 4 new test files (+22 tests, 73 → 95):
  `module_callbacks_test.exs`, `activity_log_rescue_test.exs`
  (async: false — DROPs activities table mid-tx),
  `handle_info_catchall_test.exs` (per-LV `Logger.debug` smoke;
  lifts `Logger.level` to `:debug` per test),
  `destructive_buttons_test.exs` (regex-pin every destructive
  click handler).

Commit: `02be6b3`.

## Fixed (Batch 3 — fix-everything pass, 2026-04-28)

Closes every remaining in-scope C12/C12.5 finding under default
"FIX EVERYTHING" authorisation per the post-Apr precedent.

- **Cross-module schema typespecs (dialyzer fix)** — `Task.t` /
  `Assignment.t` cross-module fields relaxed to `struct() | nil`
  (was `Team.t() | ...`; Hex `phoenix_kit_staff 0.1.0` doesn't ship
  `@type t`; tighten back when staff publishes 0.1.1). Inline
  comments at both call sites flag the pending tightening.
- **`error_summary/2` translates validator messages** — Phase 1
  deferred #15 closed. Routes through `translate_validator_error/1`
  using `Gettext.dgettext`/`dngettext` against the "errors" domain
  (Phoenix scaffolding canonical pattern). Renamed from
  `translate_error/1` to avoid shadowing
  `PhoenixKitWeb.Components.Core.Input.translate_error/1`. The
  defensive non-changeset clause was unreachable per dialyzer —
  removed.
- **`recompute_project_completion/1` transaction wrapper** —
  C12 agent #3 race fix. The read + check + update sequence now
  runs inside `repo().transaction(fn -> ... end)`, so two
  concurrent assignment status changes can't both observe the
  same pre-update project state and double-mark completed.
- **`Activity.log_failed/2` helper + 8 wired error-branch sites**
  — per publishing-Batch-3 / catalogue-Batch-4 precedent. New
  helper appends `metadata.db_pending = true` and routes through
  `log/2` (same rescue/catch shape). Wired into delete handlers
  in `projects_live` / `tasks_live` / `templates_live`,
  `update_assignment_with_activity` central helper in
  `project_show_live` (covers complete/start_task/reopen/
  update_progress), plus `remove_assignment` / `toggle_tracking` /
  `start_project` direct, plus `add_assignment_dep` /
  `remove_assignment_dep` in `assignment_form_live`. So a
  Drive/DB outage no longer erases admin clicks from the activity
  feed.
- **`@spec` backfill** on `Projects` context — 32 specs across
  the public API surface (CRUD + listings + summaries +
  dependencies + templates + state mutations). Plus shared
  `@type uuid :: String.t() | <<_::128>>` and
  `@type error_atom :: :not_found | :template_not_found | :task_not_found`.
- 2 new test files (+11 tests, 95 → 106):
  `activity_log_failed_test.exs` (`db_pending: true` invariant +
  user-supplied metadata preservation; uses canonical
  `assert_activity_logged/2`),
  `edge_cases_test.exs` (Project name Unicode CJK + emoji + RTL
  via `‮` / `‬` escapes — Elixir 1.18 rejects raw bidi
  in source — plus SQL metacharacter literal handling, 256-char
  rejection, blank-name rejection; Task title Unicode + SQL meta;
  3 `recompute_project_completion/1` transaction-wrapper tests).

Commit: `fdac48d`.

## Files touched (Batches 2 + 3)

| File | Change |
|---|---|
| `AGENTS.md` | "What this module does NOT have" canonical section |
| `lib/phoenix_kit_projects.ex` | `enabled?/0` `catch :exit` |
| `lib/phoenix_kit_projects/activity.ex` | rescue widening + `log_failed/2` helper |
| `lib/phoenix_kit_projects/projects.ex` | `@type uuid` + `@type error_atom`; ~32 `@spec`s; `recompute_project_completion/1` transaction wrapper |
| `lib/phoenix_kit_projects/schemas/task.ex` | cross-module `struct()` typespec relaxation |
| `lib/phoenix_kit_projects/schemas/assignment.ex` | same |
| `lib/phoenix_kit_projects/web/overview_live.ex` | `Logger.debug` catch-all |
| `lib/phoenix_kit_projects/web/projects_live.ex` | catch-all + `log_failed` on delete error |
| `lib/phoenix_kit_projects/web/tasks_live.ex` | catch-all + `log_failed` on delete error |
| `lib/phoenix_kit_projects/web/templates_live.ex` | catch-all + `log_failed` on delete error |
| `lib/phoenix_kit_projects/web/project_show_live.ex` | catch-all + 9 `phx-disable-with` + 4 `log_failed` sites + translated `error_summary` |
| `lib/phoenix_kit_projects/web/assignment_form_live.ex` | 2 `phx-disable-with` + 2 `log_failed` sites |
| `lib/phoenix_kit_projects/web/task_form_live.ex` | 2 `phx-disable-with` |
| `mix.exs` | `test_coverage [ignore_modules]` filter |
| `test/phoenix_kit_projects/module_callbacks_test.exs` | NEW — `enabled?/0` + module-callback contracts (+8) |
| `test/phoenix_kit_projects/activity_log_rescue_test.exs` | NEW — Postgrex.Error rescue (+2, async: false) |
| `test/phoenix_kit_projects/activity_log_failed_test.exs` | NEW — `db_pending` invariant (+2) |
| `test/phoenix_kit_projects/edge_cases_test.exs` | NEW — Unicode / SQL meta / 256-char (+9) |
| `test/phoenix_kit_projects/web/handle_info_catchall_test.exs` | NEW — per-LV `Logger.debug` smoke (+5) |
| `test/phoenix_kit_projects/web/destructive_buttons_test.exs` | NEW — `phx-disable-with` regex pin (+7) |

## Verification

- `mix compile --warnings-as-errors` — clean
- `mix format --check-formatted` — clean
- `mix credo --strict` — 0 issues (429 mods/funs)
- `mix dialyzer` — **0 errors** (was 6 pre-existing unknown-type
  warnings before Batch 3; closed by relaxing cross-module schema
  typespecs to `struct()` until staff publishes 0.1.1)
- `mix test` — **106 tests, 0 failures** (73 → 106, +33 over the
  original sweep baseline)
- 10/10 stable runs — no flakes
- Stale-ref grep sweep — `IO.inspect/puts/warn`, `# TODO/FIXME/HACK/XXX`,
  `{:error, "literal"}`, `changeset_errors`/`Gettext.gettext`/
  `String.capitalize`, commented-out `def`/`case`/`if` — all clean

## Fixed (Batch 4 — 2026-05-11 re-validation)

- ~~`phoenix_kit_staff` `@type t` follow-up~~ — `phoenix_kit_staff`
  0.2.0 shipped with `@type t` declarations on all four schemas
  (`Person`, `Department`, `Team`, `TeamMembership`). Tightened the
  cross-module fields in `task.ex` (`default_assigned_team` /
  `_department` / `_person`) and `assignment.ex` (`assigned_team` /
  `_department` / `_person`) from `struct() | NotLoaded.t() | nil`
  to the precise `Team.t()` / `Department.t()` / `Person.t()`
  variants. Inline placeholder comments removed.
- ~~Listing-helper `@spec` backfill~~ — verified all `list_*` and
  `count_*` in `projects.ex` already carry `@spec`; the original
  deferral was overtaken by the Phase 2 sweep itself.

## Open

None.

The previously-deferred behaviour-change items (mount → handle_params
refactor, OverviewLive event-debounce, status-helper extraction)
remain documented in `AGENTS.md` under "What this module does NOT
have" — they are non-features by design, not parking-lot TODOs. The
status-helper trigger ("third call site appears") has not fired —
duplication is between `OverviewLive` and `ProjectShowLive` only
(`ProjectsLive`'s `derived_status_*` helpers are a separate
project-state concern, not the assignment-status set).
