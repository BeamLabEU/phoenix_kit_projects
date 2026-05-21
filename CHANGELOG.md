# Changelog

## 0.5.0

AI-driven translation for projects, templates, and tasks — an Oban-backed worker plus an in-form translate UI — alongside a batch of field-report fixes (embedded-mount crash, partial-progress rollup, translatable templates, popup width).

### Added

- **AI translation** — `PhoenixKitProjects.Translations` public API (`enqueue/1`, `enqueue_all_missing/2`, AI endpoint/prompt resolution, and default-prompt provisioning) backed by `PhoenixKitProjects.Workers.TranslateResourceWorker`, an Oban worker that translates `Project` / `Template` / `Task` / `Assignment` translatable fields via `PhoenixKit.Modules.AI.Translation.translate_fields/6`. Deterministic failures discard instead of retrying (no token burn), and failure reasons are sanitized before logging / activity-metadata writes.
- **`<.ai_translate_bar>` + AI Translation modal** on the project / template / task form LVs — a compact trigger above the multilang tabs with endpoint/prompt selectors and a scope picker (missing-only / all-overwrite / current tab). Hidden when AI is unavailable or on `:new`. Status streams over scoped per-resource PubSub; completion patches **only** the `translations` field of the live changeset, so unsaved edits survive a job finishing mid-edit.
- **Translatable templates** — `TemplateFormLive` gains the multilang plumbing (tabs, language switcher, translatable name + description) already present on projects.
- **Partial-progress rollup** — overall project progress now averages each assignment's `progress_pct` instead of counting only `done`. Project auto-completion stays binary (flips to `:completed` only when every assignment is `done`).
- **`Projects.get_projects/1`** — batch `%{uuid => Project}` lookup so host list views can avoid a per-row N+1.
- **`session["modal_box_class"]`** — `PopupHostLive` accepts a host-supplied modal-box width (default `w-11/12 max-w-6xl`).

### Changed

- Minimum `phoenix_kit` is now `~> 1.7.117` — it ships `PhoenixKit.Modules.AI.Translation.translate_fields/6` (core PR #557) that the translation worker delegates to.
- Popup child frames now fill the modal box — `PopupHostLive` injects a full-width `wrapper_class` unless the host passes its own, fixing form LVs that stacked their standalone `max-w-xl` cap inside the popup.

### Fixed

- **Embedded `ProjectShowLive` comments-drawer crash** — switched bang-form `@phoenix_kit_current_scope` to bracket access, so off-router `live_render` mounts (which skip core's `on_mount`) no longer raise `KeyError` when the drawer opens.
- **AI unique-job window** — `TranslateResourceWorker` now sets `unique: [period: :infinity, …]`. The omitted period defaulted to 60s, which let a translation slower than a minute be enqueued a second time and burn tokens twice.
- **AI overwrite vs. open form** — the "all"/overwrite scope now overwrites translations in the open form too (mirroring the worker's persisted merge) instead of leaving stale values that a save would silently revert; missing/current scopes keep the blank-only edit protection.
- **AI mount cost + flash accuracy** — the five Settings/plugin lookups now run only on the connected mount (`mount/3` fires twice), and an empty-source completion flashes an accurate message instead of "Translated".

### Tests

- New `translations_test.exs` + `translate_resource_worker_test.exs` (argument validation, deterministic-failure discard, broadcast fan-out, merge + source-lang semantics, overwrite-flag propagation), `ai_translate_form_helpers_test.exs` + `ai_translate_bar_test.exs` (missing-language detection, merge policy, scope/visibility), and an `embedding_test.exs` regression that greps `lib/` for any `@phoenix_kit_*` bang-form reference.

## 0.4.0

Adopts phoenix_kit core PR #551 — shared utilities consolidated upstream — plus emit-mode review follow-ups and UX polish.

### Changed

- **Prefixless admin URLs** — `Paths.*` helpers now resolve to `/admin/projects/...` instead of `/en/admin/projects/...` for the default locale, tracking `Routes.admin_path/2` from phoenix_kit core PR #551. Hosts with hardcoded locale-prefixed paths to project routes should re-check them.
- **Migrated to `PhoenixKit.Utils.{Reorder,Values}`** — the projects-local reorder and value-coercion helpers were dropped in favour of the consolidated core utilities.
- **Dropped local `<.empty_state>`** — list views now use the `PhoenixKitWeb.Components.Core` `empty_state/1` component lifted into phoenix_kit core.
- Minimum `phoenix_kit` is now `~> 1.7.114` (ships `Utils.Reorder`, `Utils.Values`, `core/empty_state`, and prefixless `admin_path`).

### Added

- **`<.assignment_status_badge>` component** — shared assignment-status presentation (`color/1`, `badge_class/1`, `label/1`), extracted from `ProjectShowLive` + `OverviewLive`.
- **`session["max_stack_depth"]`** — `PopupHostLive` accepts a host-supplied modal-stack cap (integer `1..20`, default 5; out-of-band values reset to the default with a logged warning).
- **`<.popup_host>` loading feedback** — per-frame daisyUI spinner overlay that auto-fades; `<.smart_link>` buttons get `cursor-pointer` + `phx-click-loading` CSS feedback.

### Fixed

- **`<.smart_link>` / `<.smart_menu_link>` render-time crash vector** — emit-session JSON now encodes via the non-bang `Helpers.encode_emit_session/3`, falling back to an empty session on failure instead of crashing the whole view.
- **`ProjectShowLive` fail-closed mount** now inherits the host locale, so the "Project not found." flash is localized.
- **`emit_telemetry/2`** builds its payload outside the rescue and rescues only around `:telemetry.execute/3`, so a misbehaved host telemetry handler can't crash the embed flow while bugs in this module still surface.
- **`mix precommit`** — credo alias, dialyzer `pattern_match_cov` on the reorder LiveViews, and formatting.

### Removed

- Dead `:embed_close_on` assign / `"close_on"` session key — reserved-but-unused; can be reintroduced when per-frame close-event opt-in is genuinely needed.

### Tests

- New pure-changeset suites — `schemas/project_test.exs` (26 tests: required/length validation, `start_mode` enum, `derived_status/2` cascade, `planned_end_for/2` + `eta_from/3` branches) and `schemas/dependency_test.exs` (required validation, self-reference rejection).

## 0.3.0

Emit-mode navigation + PopupHostLive for embedded LiveViews, locale inheritance fixes, and UI polish.

### Added

- **Emit-mode contract** — embedded LVs can now broadcast UI-intent events (`:opened`, `:closed`, `:saved`, `:deleted`) on a host-supplied PubSub topic instead of calling top-level `push_navigate`. Pass `session["mode"] => "emit"` + `session["pubsub_topic"]` to any embedded LV. `session["redirect_to"]` from PR #6 stays supported in navigate mode (default).
- **`PopupHostLive`** — opinionated daisyUI modal-stack host for embedded LVs. Renders a root view inline, pushes follow-up views into `<dialog>` frames, and handles ESC / backdrop / race-safe pop via `frame_ref`.
- **`PhoenixKitProjects.Web.Helpers` embed utilities** — `assign_embed_state/2`, `attach_open_embed_hook/1`, `navigate_or_open/2`, `close_or_navigate/2`, `navigate_after_save/3`, `notify_deleted_or_navigate/4`, `notify_deleted/3`.
- **`<.smart_link>` + `<.smart_menu_link>` components** — render real `<a>` tags in navigate mode and `<button phx-click="open_embed">` in emit mode, with whitelist validation against `Helpers.embeddable_lvs/0`.
- **`<.popup_host>` component** — function-component wrapper for PopupHostLive session generation.
- **`dev_docs/embedding_emit.md`** — full emit-mode contract reference for host authors.

### Changed

- **Embedded LV locale inheritance** — `session["locale"]` is now threaded through PopupHostLive and restored in every stacked frame so translations stay consistent across modal opens.
- **Full-width default wrappers** — list and show LVs now default to `w-full` instead of `max-w-*` when embedded, giving hosts more layout control.
- **Project show header layout** — title + description are stacked; Edit / Archive actions moved into a kebab menu. Row actions in the assignment timeline converted to kebab menus for cleaner visuals.
- **Dependency upgrades** — `phoenix_live_view`, `phoenix_kit`, `phoenix_kit_staff`, and transitive deps updated to latest compatible versions.

### Fixed

- **Dialyzer warnings** — silenced pre-existing opaque-type warnings on `PopupHostLive` and `Helpers` via targeted `@dialyzer` annotations and `.dialyzer_ignore.exs` entries.
- **Duplicate alias** — removed a duplicate `Helpers` alias left by a rebase in `AssignmentFormLive`.

### Tests

- **Emit-mode regression gate** — `embedding_emit_test.exs` (53 tests) + `popup_host_live_test.exs` (27 tests) covering mount, event round-trips, `frame_ref` stamping, race-safe pops, stack-depth caps, and `next:` chaining.
- **Helper embed tests** — `helpers_embed_test.exs` (15 tests) covering `safe_internal_path?/1`, `assign_embed_state/2`, and emit-vs-navigate branching.

## 0.2.2

Dialyzer clean-up + version sync.

### Fixed

- **`permission_metadata/0` callback type mismatch** — removed `gettext_backend`
  and `gettext_domain` keys that were not part of the `PhoenixKit.Module`
  `permission_meta()` type, which Dialyzer flagged as a `callback_type_mismatch`.
- **Gettext.Backend opaque warnings** — added `@dialyzer {:no_opaque, []}` to
  `PhoenixKitProjects.Gettext` and a `.dialyzer_ignore.exs` entry for the four
  `call_without_opaque` false positives generated by `Gettext.Backend` in
  gettext ≥ 0.26.
- **Version drift** — `def version/0` was returning `"0.2.0"` while `mix.exs`
  already declared `0.2.1`. Aligned both to the declared version.

## 0.2.1

Embed support + ETA refactor + Phase 2 re-validation sweep (PR #6) plus
post-merge follow-up (review under
`dev_docs/pull_requests/2026/6-embed-and-quality/FOLLOWUP.md`).

### Added

- **Embeddable LiveViews** — all 9 LVs in the module can now be nested
  inside a host LiveView via `live_render/3` (issue #5). Each LV
  accepts a `:not_mounted_at_router` mount path, a session-overridable
  `wrapper_class`, and (for form LVs) a session-overridable
  `redirect_to`. Host apps can drop the module's own UI into their own
  workflow instead of re-implementing it against the contexts.
- **Shared embed plumbing in `PhoenixKitProjects.Web.Helpers`** —
  `resolve_live_action/3`, `resolve_action_params/2`, and
  `navigate_after_save/2` provide a single source of truth for the
  router-vs-embed mount path.
- **Open-redirect guard on `navigate_after_save/2`** —
  `session["redirect_to"]` is validated as a relative internal path
  (starts with `/`, not protocol-relative, no `://`) before any
  `push_navigate`. Protects embedders that naively forward an
  unvalidated `params["return_to"]` from a request query string.
- **Remaining + ETA stat** — `ProjectShowLive` now displays
  `Remaining: Xh · ETA: <datetime> at planned pace` in place of the
  previous Planned/Projected date pair. Anchored on `now` and the sum
  of remaining task hours rather than velocity. New `Project.eta_from/3`
  public API mirrors `planned_end_for/2` but accepts an arbitrary
  anchor datetime.
- **`dev_docs/embedding_audit.md`** — per-LV diagnosis of the three
  embed-blocker patterns (router-shaped `mount/3`, `handle_params/3`
  export, hardcoded wrapper class) and the test convention
  (`live_isolated/3` in `test/phoenix_kit_projects/web/embedding_test.exs`)
  that stops them from being re-introduced. 28 new contract tests.

### Changed

- **`handle_params/3` removed from list, show, and form LVs.** Phoenix
  LiveView refuses to mount a LV exporting `handle_params/3` outside a
  router live route, which would block `live_render` embedding. The
  bodies were folded into the tail of `mount/3`. (Reverses the 0.2.0
  refactor that had moved queries the other direction.)
- **`TasksLive` view toggle** moved from URL-driven `?view=list|groups`
  to `phx-click set_view`. The toggle is UI state, not a real route
  arg — making it a URL param required `handle_params/3` (now
  removed for embedability) and meant deep links could collide with
  per-user preference.
- **Empty-content pop-in eliminated on first paint** for Tier 1/2 LVs
  (`OverviewLive`, `ProjectsLive`, `TemplatesLive`, `TasksLive`) by
  dropping the `connected?(socket)` gate around data loading in
  `mount/3`. First HTTP response now contains content rather than a
  skeleton that the WebSocket-connected mount then replaces.
- **`mix precommit` auto-formats before checking** — `format` prepended
  to the alias so unformatted files are rewritten before
  `quality.ci`'s `format --check-formatted` verifies. `quality.ci`
  keeps the check-only variant for CI.

### Fixed

- **Dead `archived` key in PubSub broadcast payload** — `project_payload/1`
  was building `archived: not is_nil(p.archived_at)` but every
  subscriber pattern-matched on `{:projects, event, _payload}` and
  re-fetched via `get_project/1` when archived state mattered.
  Removed.
- **Unreachable `safe_internal_path?/1` catch-all** in
  `Web.Helpers` — the second clause was dead code because the only
  caller already narrows the value to a non-empty binary; Dialyzer
  flagged it as unreachable.
- **PR #4 follow-up** — docstring symmetry on reorder helpers (Phase 1
  triage of `CLAUDE_REVIEW.md`).

## 0.2.0

### Added

- **Multilang content** — project name/description, task title/description, and
  assignment description are now translatable via core's Languages module.
  Forms auto-render `<.multilang_tabs>` when 2+ languages are enabled; primary
  values stay in their columns, overrides live in a `translations JSONB`.
- **Task groups view** — task templates can be grouped by dependency tree in the
  task-library UI, with visual `→ X` badges showing outgoing edges.
- **Drag-and-drop reorder** — projects, templates, and tasks can be reordered
  via sortable tables with `phx-reorder` events. Dedup logic guarantees
  last-write-wins on duplicate UUIDs.
- **Closure-pull cascade** — adding a task to a project can optionally pull in
  its entire upstream dependency closure with automatic `Dependency` wiring and
  execution-order position assignment.
- **Slide-in comments drawer** — `ProjectShowLive` now supports a per-resource
  comments side-panel with live count badges.
- **Running dashboard prioritization** — the Overview tab now surfaces late and
  near-done projects first, with tier pills (`:late`, `:near_done`, `:on_track`).
- **Derived status + soft-hide archive** — replaced the string `status` column
  with `archived_at` timestamp. `Project.derived_status/2` returns `:running`,
  `:completed`, `:overdue`, `:scheduled`, `:setup`, `:archived`, or `:template`.
  `Projects.archive_project/1` / `unarchive_project/1` are the public API.
- **Reusable UI components** — extracted `<.derived_status_badge>`,
  `<.empty_state>`, `<.page_header>`, `<.running_card>`, `<.sortable_table>`,
  `<.stat_tile>`, `<.tabs_strip>`, and `<.tier_pill>` from the large LiveViews
  into individual `PhoenixKitProjects.Web.Components.*` modules.
- **`handle_params/3` refactor** — all list, show, and form LiveViews moved their
  initial DB queries from `mount/3` to `handle_params/3` so HTTP render and
  WebSocket connect share a single query path.
- **Translations JSONB validation** — schema changesets now validate the shape
  of incoming `translations` maps to prevent malformed JSONB inserts.

### Changed

- `build_group_tree/4` and `build_closure_tree/3` switched from `cond do` with
  a single non-`true` clause to `if/else` (credo compliance).
- `wire_closure_dependencies/3` nesting reduced by extracting
  `wire_child_dependency/4` and `wire_assignment_dependency/2`.
- `is_template_attr?/1` renamed to `template_attr?/1` per Elixir naming
  conventions.

### Fixed

- **Diamond-dependency skip in closure pull** — a task reachable via both an
  excluded and a non-excluded parent is now correctly emitted once when the
  non-excluded branch reaches it.
- **O(n²) topo append eliminated** — `topological_insertion_order/2` now builds
  the list in reverse and flips once at the end.
- **Duration editor prefill** — the inline duration editor in `ProjectShowLive`
  now falls back to the task template's default values when the assignment has
  no explicit duration.
- **Inline duration editor UX** — improved hover contrast, control sizing, and
  input prefill behavior.
- **Precommit hygiene** — resolved all credo strict issues and suppressed a
  Dialyzer false-positive on recursive `MapSet` opacity.

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
