# AGENTS.md

Guidance for AI agents working on `phoenix_kit_projects`.

## Overview

A PhoenixKit plugin module for project and task management. It implements the
`PhoenixKit.Module` behaviour and provides a reusable task library, projects
that pull tasks in as assignments (with team/department/person assignees),
dependency chains within a project, sub-projects, workflow statuses, a
per-project extension hub (files, whiteboards, events, discussions, a public
portal), dashboard widgets and a public issue portal.

- **Depends on:** `phoenix_kit` `>= 2.54.0 and < 3.0.0` (Hex — the release
  that carries `<.table_default fit>`'s column fitting, on top of `activity_list/1`, `Storage.ResourceFolders`,
  `PhoenixKitWeb.Actor`, `Activity.log/3`, `TableColumns` and the
  `form_actions` / `bulk_actions_toolbar` / `form_section` attrs and slots
  the LiveViews use; the compound form keeps the ceiling open across later 2.x
  minors and `core_pin_conformance_test.exs` guards it),
  `phoenix_kit_ai` `~> 0.18` (hard — the AI-translation pipeline),
  `phoenix_kit_comments` `~> 0.3` (hard — `ProjectShowLive` does
  `use PhoenixKitComments.Embed`), `phoenix_kit_staff` `~> 0.8` (**optional** —
  the People seam; all reads go through `PhoenixKitProjects.People`),
  `phoenix_kit_entities` `~> 0.3` (**optional** — the workflow-status catalog;
  `Statuses.available?/0` gates every call), plus `phoenix_live_gantt` `~> 0.4`
  (Timeline) and `phoenix_live_calendar` `~> 0.3` (Calendar).
- **Consumed by:** `phoenix_kit_dashboards` discovers `phoenix_kit_widgets/0`
  duck-typed (one-way — projects has no dependency on it). `phoenix_kit_ai`
  calls `handle_ai_usage/1` the same way. Core consumes `resource_links/0`,
  `notification_types/0`, `before_user_delete/1`, `migrate_legacy/0`,
  `css_sources/0` and `js_sources/0`.
- **Admin surface:** one `Projects` tab whose **landing page is the project
  list** (`/admin/projects`), with subtabs Projects, Templates, Tasks and
  Overview (last), plus hidden subtabs for every project/task/template/
  assignment page. A settings tab at `/admin/settings/projects`
  (`settings_tabs/0`), a user-dashboard tab `My Projects` at
  `/dashboard/projects` (`user_dashboard_tabs/0`, membership-gated, no admin
  permission), and the public portal at `/portal/:slug` (`route_module/0`).
- **Module key** `"projects"`; settings prefix `projects_`.

## What this module does NOT do

- **No tenant scoping on PubSub topics** — `projects:all` / `projects:tasks` /
  `projects:templates` fan out to every subscriber. Per-tenant scoping is a
  framework-wide gap (no other feature module partitions PubSub by tenant
  either); the right shape is to thread an org/tenant key through every topic
  when core grows that capability. The per-project topic
  (`projects:project:<uuid>`) is already safe — you need the UUID to subscribe.
- **No `handle_params/3` on `ProjectShowLive`** — initial DB reads happen at
  the tail of `mount/3`. LiveView refuses to mount any LV exporting
  `handle_params/3` outside a router live route, which blocks embedding via
  `live_render`. The same constraint applies to any sibling LV that must be
  embeddable: drop `handle_params/3` and move its body into the mount tail.
- **No event-debounce / minimal-delta on `OverviewLive`'s `handle_info`** —
  every `{:projects, _, _}` broadcast triggers a full dashboard reload.
- **No status-helper extraction** — `status_color/1` / `status_badge_class/1` /
  `status_label/1` are duplicated between `OverviewLive` and `ProjectShowLive`.
  Cosmetic; extract when a third call site appears.
- **No HTTP boundary** — the context calls only PostgreSQL via Ecto and reads
  core's settings; no `Req.get` / `:httpc.request` / external service. So no
  SSRF guard and no `Req.Test`-via-app-config stub pattern.
- **No HTTP backend for translations** — they live in this repo's
  `priv/gettext/` and in core's for the shared strings (see Conventions →
  Gettext).
- **No Errors module for HTTP error shapes** — `Errors.message/1` covers
  `:not_found` / `:template_not_found` / `:task_not_found` plus a generic
  fallback. Add a branch when a context function introduces a new
  `{:error, atom}` shape.
- **No direct `PhoenixKitStaff.*` calls** — staff is optional; the People
  doorway is the only sanctioned path (see Conventions).
- **No plain-POST fallback for the public portal** — `/portal/:slug/report` is
  a `live` route, so submitting needs JS. A real no-JS fallback means a
  controller action doing its own honeypot / fill-time / rate-limit pass, i.e.
  a second abuse-exposed entry point; build it deliberately or not at all.

## Commands

```bash
mix deps.get
createdb phoenix_kit_projects_test          # once; DB-backed tests are tagged :integration and auto-skip without it
mix test
mix precommit                # compile --warnings-as-errors + format + credo --strict + dialyzer; run before every commit
```

`phoenix_kit*` deps resolve from Hex. To run against a local checkout, export
`<APP>_PATH` (the dep's app name upper-cased plus `_PATH`); `pk_dep/3` in
`mix.exs` swaps the Hex pin for a `path:` dep at resolve time. Unset means the
Hex pin, so `mix hex.publish` is unaffected. Run `mix deps.get` with the var
exported before the first `mix test` (a stale lock aborts on the optional
`igniter` dep), and never commit a hand-edited `path:` tuple.

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix deps.get && PHOENIX_KIT_PATH=../phoenix_kit mix test
PHOENIX_KIT_AI_PATH=../phoenix_kit_ai mix test
PHOENIX_KIT_STAFF_PATH=../phoenix_kit_staff mix test
PHOENIX_KIT_COMMENTS_PATH=../phoenix_kit_comments mix test
PHOENIX_KIT_ENTITIES_PATH=../phoenix_kit_entities mix test
PHOENIX_LIVE_GANTT_PATH=../phoenix_live_gantt mix test
PHOENIX_LIVE_CALENDAR_PATH=../phoenix_live_calendar mix test
```

The staff-optional seam has its own compile gate, which must stay green:

```bash
WITHOUT_STAFF=1 mix deps.get && WITHOUT_STAFF=1 mix compile --warnings-as-errors
```

`WITHOUT_STAFF=1` makes `pk_dep/3` drop the dep entirely, so a stray
`PhoenixKitStaff.*` reference fails the compile. `optional: true` governs a
consumer's dependency closure only — it does not remove the dep from this
package's own build, which is how two direct references to staff schemas once
got in and broke group grants on staff-less installs. The contract and
functional proofs live in
`test/phoenix_kit_projects/integration/people_seam_test.exs`.

Repo-local aliases:

- `mix quality` — `format` + `credo --strict` + `dialyzer` (applies formatting).
- `mix quality.ci` — `format --check-formatted` + `credo --strict` + `dialyzer`: it CHECKS formatting rather than applying it, so run `mix format` first.
- `mix test.reset` — drops the test database and recreates it.
- `mix test.setup` — `ecto.create` on the test repo, the alias equivalent of `createdb`.

## Conventions

- **Module key / tab ids / URL segments.** Module key `"projects"`; tab ids are
  `:admin_projects*`, `:dashboard_projects`, `:admin_settings_projects`;
  settings keys are prefixed `projects_`. URL segments are lowercase words;
  a multi-word segment uses hyphens.
- **Paths**: `PhoenixKitProjects.Paths.*` only — never hardcode an admin path.
- **Routing**: admin, user-dashboard and settings routes are auto-generated
  from `admin_tabs/0` / `user_dashboard_tabs/0` / `settings_tabs/0` via each
  tab's `live_view:`. `route_module/0` (`Web.Routes.generate/1`) adds ONLY the
  public portal, spliced at router top level before the `/:locale` public
  surface, so its path uses a literal first segment (`/portal/...`) and carries
  no locale segment. Never hand-register a plugin route in a host router.
  **Declaration order is route order**: literal siblings and the legacy
  redirects come before `projects/:id`, `new` before `:id`, and the
  `projects/:id/:tab` extension catch-all is declared LAST; `landing_test.exs`
  pins it.
- **LiveView layout**: `use PhoenixKitWeb, :live_view` (from
  `phoenix_kit_web.ex`) injects `layout: PhoenixKit.LayoutConfig.get_layout()`
  automatically. Do NOT wrap templates in
  `<PhoenixKitWeb.Components.LayoutWrapper.app_layout>` — that wrapper is for
  LiveViews served outside the admin live_session, and no LV here uses it.
- **JS hooks** ship as prebuilt bundles declared by `js_sources/0` under a
  namespaced global (`PhoenixLiveGanttHooks`, `PhoenixLiveCalendarHooks`),
  which core's `:phoenix_kit_js_sources` compiler wires into the host. Never
  register a hook from an inline `<script>` — morphdom does not execute
  inserted script tags, so the hook vanishes on LiveView navigation. There is
  no `@impl PhoenixKit.Module` on `js_sources/0` while the core behaviour does
  not declare the callback (annotating it warns, and warnings are errors).
  `css_sources/0` names `:phoenix_live_gantt` and `:phoenix_live_calendar` too,
  so the host's Tailwind scans their classes with no manual `@source`.
- **`enabled?/0` rescues and catches `:exit`, returning `false`**, so missing
  settings tables can't crash module discovery.
- **Activity logging** goes through the `PhoenixKitProjects.Activity` wrapper
  and happens at the **LiveView layer**, never inside `PhoenixKitProjects.Projects`.
  LiveViews read the actor with `Activity.actor_uuid/1` (core's
  `PhoenixKitWeb.Actor`: the scope first, then the bare current user) and
  know the user's intent; contexts stay pure, returning
  `{:ok, record} | {:error, changeset}`. Core's `PhoenixKit.Activity.log/3`
  never raises — logging never crashes a mutation.
  Activity metadata captures the **primary** column value
  (`metadata.name = project.name`), not the localized one: audit trails are
  locale-agnostic.
  - In an embedded (`:not_mounted_at_router`) mount core's
    `:phoenix_kit_ensure_admin` `on_mount` never runs, so the actor comes from
    `WebHelpers.assign_embed_user/2` reconstructing it from
    `session["current_user_uuid"]`. Without that key embedded mutations log
    `actor_uuid: nil` by design; `Activity.actor_uuid/1` tolerates a missing
    assign.
  - **Sugar helpers don't log on their own:** `complete_assignment/2` and
    `reopen_assignment/1` delegate to the server-trusted
    `update_assignment_status/2`, emit the same PubSub broadcast, and log
    nothing. A caller wanting `projects.assignment_completed` /
    `_reopened` recorded must log it explicitly.
  - The two `_display_changed` actions are **coalesced per field**: a slider
    drag emits a debounced `phx-change` per step but only ONE audit row — the
    settled value — flushes after ~1s of quiet (`@display_log_flush_ms`; a
    reset supersedes still-queued change rows, and `terminate/2`
    best-effort-flushes on navigation). Discrete controls log immediately.
- **Mass-assignment guard**: `Assignment.changeset/2` (used by
  `create_assignment/1` and `update_assignment_form/2`) does NOT cast
  `completed_by_uuid` or `completed_at` — those are server-owned and reachable
  only through `Assignment.status_changeset/2` via `update_assignment_status/2`.
  The `_form` suffix on the public function is a deliberate smell: reaching for
  it from non-form code should trigger a second look. `current_status_slug` is
  server-owned the same way (`Project.current_status_changeset/2` only).
- **Cross-module people lookups**: NEVER call `PhoenixKitStaff.*` directly
  (staff is optional) — go through `PhoenixKitProjects.People`, read-only
  shadow schemas over the CORE-owned staff tables, trashed-excluded by default,
  staff-parity label semantics. The doorway's reads rescue to safe defaults;
  the only sanctioned staff reference is `People.staff_admin_available?/0`'s
  guarded probe, which gates admin-UI affordances only.
- **Soft-hide is a timestamp, not a status enum.** `projects.archived_at`
  follows the workspace `trashed_at` convention: null = visible, non-null =
  hidden + audit-friendly. Public API `Projects.archive_project/1` /
  `unarchive_project/1`; dashboard buckets and `list_projects/1` filter on
  `is_nil(archived_at)`, and `list_projects/1` takes an `:archived` opt —
  `false` (default), `true` (archived only), `:all`. `Project.derived_status/2`
  returns `:archived` as the highest-priority bucket, so an archived project is
  always labeled archived regardless of its other timestamps.
- **The legacy `status` string column is kept and unused.** Still in
  `phoenix_kit_projects`, no longer cast by the changeset, never read, surfaced
  nowhere; the archive migration backfilled `archived_at = updated_at` for rows
  that were `status = 'archived'`. Preserved deliberately so a future string
  lifecycle state (`"paused"`, `"blocked"`, `"on_hold"`) can reuse the slot
  without a migration. Wiring that means: re-introduce `status` to
  `Project.@optional` + `Project.changeset/2`; add a fresh
  `validate_inclusion(:status, …)`; update `Project.derived_status/2`'s
  priority order if the new state should outrank the existing buckets; decide
  whether to backfill existing rows.
- **Duration units and conversion** are centralized in `Schemas.Task`
  (`to_hours/3`, `format_duration/2`).
- **Gettext is a hybrid over two backends.**
  - **Module-domain strings** (project / task / template / assignment /
    dependency UI — the bulk) live in `PhoenixKitProjects.Gettext` with `.po`
    files in `priv/gettext/` (de, es, et, fr, it, pl, ru). Files declare
    `use Gettext, backend: PhoenixKitProjects.Gettext` and call `gettext/1` /
    `ngettext/3` normally. Refresh with
    `mix gettext.extract && mix gettext.merge priv/gettext --no-fuzzy` from
    this repo.
  - **Common/generic strings** (date/month formatting in
    `PhoenixKitProjects.L10n`, generic table chrome) stay on core's
    `PhoenixKitWeb.Gettext` backend. Their msgids ship in core's
    `lib/phoenix_kit_web/projects_gettext_manifest.ex` (extraction target,
    never called at runtime), mirroring the `legal_gettext_manifest.ex`
    pattern. `Web.GettextManifest` in this repo does the same job for the
    static `%Tab{}` labels and `permission_metadata/0` strings, which core's
    dashboard renderer translates at display time through
    `gettext_backend: PhoenixKitProjects.Gettext`. Add or rename a Tab label
    and you must update that manifest, or the sidebar renders raw English.
  - Both backends share the same locale via `Gettext.put_locale/1`
    (process-global), so a `/ru/...` URL prefix translates both surfaces.
  - See `dev_docs/i18n_triage.md` for the per-file bucket assignments.
  - **Catalog DATA is translated at render, and registered where it is
    declared.** Extension names/descriptions and flag labels
    (`phoenix_kit_project_extensions/0`), category labels
    (`Extensions.Registry`), the form's flag groups and the starting-point
    cards (`Archetypes`) are plain strings in maps — the `gettext/1` macro
    cannot see them, so each literal is wrapped in `gettext_noop/1` (registers
    the msgid, returns it unchanged) and every render site goes through
    `Web.Helpers.translate_catalog/1` (the runtime `Gettext.gettext/2`).
    Without the noop the string exists in NO catalogue and every locale shows
    English while every count says "complete". A sibling module's contributed
    strings pass through unless it registers them in THIS backend.
  - **Completeness is a code-vs-catalogue diff, never a count.** After every
    extract/merge, diff the new msgids against the pre-merge `.po` and fill
    them in every locale; review each `fuzzy` the merge produced — its guesses
    have been wrong every time ("Off — no task list" → "no late marker").
- **No per-item reads on a hot path.** A page mount, a PubSub re-render, a
  dashboard widget's refresh tick — anything that runs per viewer and again on
  every change — must not map a list through a function that queries per
  element. The grouped forms to reach for, each with a
  `test/phoenix_kit_projects/batched_*_test.exs` pinning "the count does not
  grow with the input" through `PhoenixKitProjects.QueryCounter`:
  `Projects.assignments_by_project/1` (a whole sub-project forest, one read per
  depth level; feeds `project_tree_summaries/1` and `ScheduleLayout.trees/1`),
  `Projects.list_all_dependencies/1` on a LIST, `Extensions.enabled_map/1` +
  `Features.gates/1` / `flags/1` (one context read), `Portal.review_details_for/1`,
  `Attachments.download_urls/1`, `Grants.subject_reaches/1`, `ListMetrics.load/3`
  (the projects list's columns, one family of reads per column group) and
  `Extensions.project_columns/2`. Ecto preloads are
  statements too, so assert N-independence, never an exact count. Known and
  left (low weight, one-off or a handful of rows): `Web.Crumbs`' per-ancestor
  `Authz.can?` for non-admins, `PortalLinks`' per-slug `Portal.resolve/2` in
  comment rendering, `Grants.subject_reach("role", …)` per role (core has no
  batched form).
- **Embedding: identity ≠ authorization.** The `permission: "projects"` gate
  lives in core's `:phoenix_kit_ensure_admin` `on_mount`, which runs only for
  router-mounted admin pages — never for an off-router `live_render`. Embedded
  mutation handlers are therefore NOT role-gated;
  `session["current_user_uuid"]` reconstructs the viewer for audit and the
  comments composer only. The **host** must gate the embedding page to
  projects-authorized users and source the uuid from its own trusted
  server-side scope, never request params. Pass a string UUID, never a `%User{}`
  struct — a struct serializes the password hash into the client-readable
  signed session.
- **Client-supplied embed sessions are sanitized.** `phx-value-session` on an
  `open_embed` button is client-editable; `sanitize_session_overrides/1` drops
  the host-owned keys (`current_user_uuid`, `mode`, `pubsub_topic`,
  `frame_ref`) at both ends — the emitter's handler and `PopupHostLive` before
  it stamps a frame's session — so a crafted payload cannot open a form as
  another user or re-route its events. Never `put_new` an identity key from a
  wire session.
- **Reorder strategy whitelist (load-bearing).** Consumer LVs MUST map
  `apply_reorder`'s strategy string to an atom through a hardcoded
  `%{"name_asc" => :name_asc, …}` map, never `String.to_existing_atom/1` on the
  param — a crafted payload otherwise either raises or leaks the BEAM atom slot.
- **`captured_uuids` collapse rule.** `open_reorder_modal` collapses
  0–1-element selection lists to `:all` (single-row reorder is a no-op, and the
  toolbar reads "Reorder all"). Apply the same rule in any new bulk-action
  handler.
- **Web components.** LVs `use PhoenixKitProjects.Web.Components` to pull in
  every reusable component in one line; components live in
  `web/components/*.ex` as individual `Phoenix.Component` modules and the
  aggregator only `import`s them, so adding one is "add file → add import".
  They are deliberately scoped to this module's namespace, not core's
  `PhoenixKitWeb.Components.*`; promoting one to core is mechanical (copy,
  rename, drop the import, let the consumer fall through). Use the CORE
  component where one exists — `<.input>`, `<.select>`, `<.textarea>`,
  `<.checkbox>`, `<.icon>`, `<.multilang_tabs>`, `<.translatable_field>`,
  `<.stat_card>` (core's takes title + subtitle + icon; for a minimal
  "label + value" tile use this module's `<.stat_tile>`) — and core's whole
  list-LV toolkit (see core's AGENTS.md → "Core List-UI Components").
  `ProjectsLive` / `TasksLive` / `TemplatesLive` are the canonical consumers —
  never re-roll a list LV without reading them first.
- **Create buttons sit in the list's toolbar, never the admin header.** A list
  page's primary action goes in the bulk toolbar's `:primary` slot (core
  `bulk_actions_toolbar`), the far-right corner beside the selection actions;
  `page_action` stays unset on list pages.
- **Embeddable pages namespace their DOM ids.** Every LV in `@embeddable_lvs`
  can render twice on one page (a `PopupHostLive` stack, a host embedding two
  frames), so a dialog, form or field id carries the record it belongs to —
  `id={"project-health-#{@project.uuid}"}`, never a bare string. A static id
  silently breaks the dialog hook and label `for=` wiring of the second copy.
- **A dialog's close event is never feature-gated.** Closing changes nothing;
  gating it in `@gated_events` means a feature switched off in another
  session while its dialog is open traps the dialog (Cancel, Escape and the
  backdrop all refused). Gate the open and the write, not the close.

### Landmines

- **An LV that exports `handle_params/3` cannot be embedded.** LiveView refuses
  to mount it outside a router live route, so `live_render` blows up. Symptom:
  a new LV works in admin and crashes in a host embed. Fix: move the body into
  the mount tail.
- **Native form validation gates `phx-submit`.** `step` / `min` / `max` on an
  input block Enter until the value is valid, and `LiveViewTest` cannot see it
  (the test passes, the browser does nothing). Use `novalidate` where the
  server owns clamping.
- **Admin tabs match independently — there is no longest-prefix arbitration.**
  A plain `match: :prefix` on `projects` lights the Projects subtab on
  `tasks`/`templates`/`hours`/`overview` too. The subtab uses a `{:regex, …}`
  matcher that excludes the literal siblings; keep it in sync when a sibling is
  added.
- **Route declaration order is match order.** `projects/:id/:tab` is the
  extension catch-all and must stay LAST — after `templates/*`, whose first
  segment would otherwise read as an id. Extension tab keys must not reuse a
  literal sibling (`edit`, `files`, `members`, `modules`, `activity`, `board`,
  `gantt`, `calendar`, `tasks`, `comments`).
- **Tests that drive the project page's drawer need a REAL user in the page
  scope** — `fake_scope(user_uuid: embed_user_uuid!())`. The sheet's form
  mounts off-router and rebuilds identity from the page's
  `current_user_uuid`; a synthetic uuid degrades it to anonymous and the sheet
  closes itself.
- **A host that adds this module's tabs can hold a stale router.** If new
  admin routes 404 after deploying, the route table was not regenerated:
  `mix compile --force`.

## Architecture

```
lib/phoenix_kit_projects.ex        # PhoenixKit.Module: tabs, permissions, extensions
                                   # catalog, notification types, js/css sources
lib/phoenix_kit_projects/
├── projects.ex              # THE context: tasks, projects, assignments, deps, schedule, cloning
├── people.ex + people/*.ex  # THE doorway to staff data + read-only shadow schemas
├── authz.ex                 # Authorization vocabulary + the single resolver
├── extensions.ex + extensions/*.ex, features.ex, archetypes.ex, list_controls.ex
│                            # Per-project capabilities, flags, starting points, list controls
├── members.ex, grants.ex, health.ex, labels.ex, ledger.ex, invoicing.ex,
│   project_events.ex, whiteboards.ex, attachments.ex, portal.ex, portal_links.ex
│                            # The hub's per-project surfaces
├── hours.ex + hours/*.ex    # The ledger READ back: filters, grouped summaries, the
│                            # timesheet; Period, Format, Report (pure)
├── statuses.ex              # Workflow statuses (entities-backed, cement-at-start)
├── schedule_layout.ex, running_tiers.ex, assignees.ex
│                            # Durations→dates walk, tiering, effective-assignee resolution
├── calendar_display.ex, gantt_display.ex   # The two display-settings customizers
├── refs.ex, project_move.ex # Short names (key / `KEY-42`); moving a project in the tree
├── activity.ex, pub_sub.ex, resource_links.ex, errors.ex, paths.ex
├── gettext.ex, l10n.ex      # Own backend + content-locale helpers
├── ai_translatable.ex, ai_translate_binding.ex, dashboard_widgets.ex
│                            # Duck-typed seams to phoenix_kit_ai / phoenix_kit_dashboards
├── migrations/schema.ex     # The module-owned versioned chain
├── schemas/                 # See the table map below
└── web/
    ├── components.ex + components/*.ex  # `use` aggregator + one module per component
    ├── crumbs.ex        # page_section / page_crumbs / page_title
    ├── helpers.ex       # embed identity, translate_catalog/1, smart-link glue
    ├── list_ui.ex       # column visibility, search coercion, client haystacks
    ├── project_list_columns.ex  # the projects list's columns as data: families, sorts, filters
    ├── routes.ex        # the public portal routes (route_module/0)
    ├── *_live.ex        # the LiveViews (below)
    └── widgets/*.ex     # the dashboards LiveComponents
```

**LiveViews** (all under `PhoenixKitProjects.Web.*`): `OverviewLive`;
`ProjectsLive`, `ProjectFormLive`, `ProjectShowLive`; `TasksLive`,
`TaskFormLive`; `TemplatesLive`, `TemplateFormLive`; `AssignmentFormLive`;
`ProjectGanttLive` / `ProjectCalendarLive` (the show page's Timeline /
Calendar tabs, read-only, nested via `live_render`); the project chrome pages
`ProjectFilesLive`, `ProjectMembersLive`, `ProjectModulesLive`,
`ProjectActivityLive`, `ProjectWhiteboardsLive`, `ProjectEventsLive`;
`ProjectHoursLive` (a project's Hours tab AND the site-wide
`/admin/projects/hours` page);
`PopupHostLive` (the emit-mode dialog stack); `MemberProjectsLive` (the user
dashboard); `PortalLive` (public); `ProjectsSettingsLive`; `ListRedirectLive`
(legacy `projects/list/…`).

### Concepts

- **Task** — a reusable library entry (title, description, estimated duration
  with unit, optional default assignee, optional default dependencies on other
  tasks). A one-off (`ad_hoc`) task is one minted for a single project.
- **Project** — a container for assignments. Has a start mode (`immediate` or
  `scheduled`), an optional `counts_weekends` flag, an `is_template` flag
  (templates are cloned into real projects) and completion tracking
  (`completed_at`).
- **Assignment** — a task instance within a project. Copies
  description/duration from the library entry at creation, but is independently
  editable. Optionally assigned to a Department/Team/Person. An assignment
  pointing at a child project instead of a task is a **sub-project**.
- **Dependency** — "assignment A must finish before B", scoped to one project.
- **TaskDependency** — a default dependency between two library tasks,
  auto-applied when both are in the same project.
- **Extension / feature flag** — a per-project capability (`tasks`, `files`,
  `whiteboards`, `events`, `discussions`, `portal`) and the flags inside it.
  Declared in `phoenix_kit_project_extensions/0`; resolved through
  `Extensions.enabled?/3` and `Features.on?/2`. A flag is dead while any of
  its `requires` is off.

### Data model

| Schema | Table |
|---|---|
| `Schemas.Project` | `phoenix_kit_projects` |
| `Schemas.Task` | `phoenix_kit_project_tasks` |
| `Schemas.Assignment` | `phoenix_kit_project_assignments` |
| `Schemas.Dependency` | `phoenix_kit_project_dependencies` |
| `Schemas.TaskDependency` | `phoenix_kit_project_task_dependencies` |
| `Schemas.ProjectStatus` | `phoenix_kit_project_statuses` |
| `Schemas.ProjectModule` | `phoenix_kit_project_modules` |
| `Schemas.ProjectMember` | `phoenix_kit_project_members` |
| `Schemas.ProjectSubjectGrant` | `phoenix_kit_project_subject_grants` |
| `Schemas.WorkEntry` | `phoenix_kit_project_work_entries` |
| `Schemas.Whiteboard` | `phoenix_kit_project_whiteboards` |
| `Schemas.ProjectEvent` | `phoenix_kit_project_events` |
| `Schemas.Label` | `phoenix_kit_project_labels` |
| `Schemas.Portal` | `phoenix_kit_project_portals` |
| `Schemas.PortalSubmission` | `phoenix_kit_project_portal_submissions` |
| `Schemas.ApiKey` | `phoenix_kit_project_api_keys` (V17 — the credentials of `Web.Api`; since V24 `project_uuid` is the key's HOME project, nullable, `ON DELETE SET NULL`) |
| `Schemas.ApiKeyGrant` | `phoenix_kit_project_api_key_grants` (V24 — what a key may do in one project: scopes, role cap, `inherit`; see "API keys across projects") |
| `Schemas.ApiIdempotency` | `phoenix_kit_project_api_idempotency` (V17 — stored API responses, by key + `Idempotency-Key`; a status-0 row is a reservation; who holds it is a Postgres session advisory lock pinned for the request, so a live holder is 409 `in_progress` and a dead one's row is taken over — see `ApiKeys.idempotent/3`) |
| (no schema modules) | `phoenix_kit_project_keys` (V22 — every key a project has had; trigger-maintained) and `phoenix_kit_project_task_counters` (V22 — the last task number handed out per project) |
| (join table, no schema module) | `phoenix_kit_project_task_interactions` (V20 — task ↔ CRM interaction link, written by `Projects.link_interaction/4`) |
| `People.{Person,Team,Department,TeamMembership}` | `phoenix_kit_staff_*` (read-only shadows over core-owned tables) |

All UUIDv7 PKs; every table-backed schema applies `use PhoenixKit.SchemaPrefix`
(`schema_prefix_conformance_test.exs` pins it).

Schema-level invariants: `Assignment` enforces a single assignee and the
task-XOR-child-project rule; `Dependency` rejects a self-reference;
`TaskDependency` is the library-level default pair.
`Projects.create_project_from_template/2` clones inside one
`Ecto.Repo.transaction`, and `project_summaries/1` is the batch query that
keeps the dashboard off an N+1 per project.

### PubSub topics

Messages are `{:projects, event_atom, payload_map}` tuples.

| Topic | Scope |
|---|---|
| `projects:all` | any project/template/task/assignment mutation |
| `projects:tasks` | task-library mutations |
| `projects:templates` | template-project mutations |
| `projects:project:<uuid>` | one project (safe against cross-tenant fan-out — you need the uuid) |
| `projects:popup:<socket id>` | one router-mounted project page's private frame topic; UI-intent verbs only, never content verbs |

`{:projects, :assignment_status_changed, %{uuid, project_uuid, from, to}}` goes
to `projects:all` and the project's topic from every path that changes an
assignment's status, and only when the status really moved:
`update_assignment_status/2`, `update_assignment_form/3`, a sub-project row's
rollup, and the rows the completion rules tick or reopen (`Outline.settle/3`,
`settle_tree/2`). `from` is the status the ROW had for the two public update
functions: when a write changes the status they read the old one from the row
(locked `FOR NO KEY UPDATE` in the same transaction), so a caller holding a
stale struct never makes up a transition. A sub-project rollup reads its link
row fresh, and the cascade rows carry the status `shape/1` read under the
project lock. Rows born with a
status (a template clone, the typed list's new lines) are creations, not
changes.

- The form paths send it beside `:assignment_updated` and honour
  `broadcast: false` for their own row. The cascade rows are different: they get
  this event (and the page one `:assignment_reordered`), never
  `:assignment_updated`, and `broadcast: false` does not silence them.
- The cascade rows are collected in the process dictionary (key
  `:projects_outline_status_events`, like `RefText`'s writer) by
  `Outline.reopen`/`mark_done` and announced by `Outline.with_project_lock/2`
  after its transaction commits; a rollback or an exception drops them, a lock
  nested in another hands them to the outer one. A caller that wraps the lock in
  its own `Repo.transaction` gets them when the lock returns, before that
  transaction commits. `settle_tree/2` / `settle_placed/1` outside a lock send
  them at once and leave no key behind.
- The module's own LiveViews (projects list, overview, project page, calendar,
  Gantt) ignore it (their reload follows `:assignment_updated`); a cascade of N rows is N+1 messages on `projects:all`.

### Permissions

`permission: "projects"` on every tab; mount guards, and events trust the mount
check. The base key means **"may enter the module"**; the `projects.admin_all`
sub-permission means **"administer projects you are not a member of"** — before
the split, granting a role the module handed it every project on the site,
because the resolver short-circuited on module access before membership was
consulted. `migrate_legacy/0` carries every pre-split role holding the base key
across, once, behind `projects_admin_all_backfilled`; a repeat on every boot
would fight an Owner's revoke.

`Authz.can?/5` resolves `site permission ∧ project role ∧ relationship grant`;
extension/flag gating composes at the call site (`Extensions.enabled?/3` +
`Features.on?/2` answer "is this capability present on this project", which is
orthogonal to "may this caller use it"). Roles are ordered
`:owner > :manager > :member > :viewer`. Actions: `:view`, `:create_tasks`,
`:edit_tasks`, `:delete_tasks`, `:assign_tasks`, `:update_status`, `:log_time`,
`:comment`, `:upload_files`, `:manage_members`, `:manage_modules`,
`:edit_settings`, `:set_health`, `:archive_project`, `:delete_project`, plus
whatever an extension declares in `permission_actions`. Unknown actions resolve
fail-closed for non-admin callers. `opts[:context]` is `:admin` (default) or
`:public`; the admin override does NOT apply under `:public` — a site admin
browsing the public portal is a visitor.

### Settings keys

- `projects_enabled` — boolean, read by `PhoenixKitProjects.enabled?/0`,
  toggled via **Admin > Modules**.
- `projects_cal_*` — the Overview-calendar customizer
  (`/admin/settings/projects`): grid appearance (`show_weekends`,
  `show_week_numbers`, `fixed_weeks`, `max_events`, `max_multiday`) and the
  overdue/late markers (`overdue_*`, `late_marker`). Every read and write goes
  through `CalendarDisplay.read/0` + `put/2` + `put_flag/2`, which validate and
  clamp on both ends — that module is the authority on ranges and defaults.
  The first weekday is NOT here: the calendars honour core's site-wide
  `week_start_day`.
- `projects_gantt_*` — the Timeline-chart customizer (`GanttDisplay`), same page.
- `projects_list_columns` / `projects_tasks_columns` /
  `projects_templates_columns` — RETIRED: the list pages' visible columns
  were one comma-joined site-wide row each; they are now each viewer's own
  choice in core's `ViewPrefs` (keys `projects.list` / `projects.tasks` /
  `projects.templates`, via `PhoenixKitWeb.TableColumns`). The rows are no
  longer read or written; an install that still has them can delete them.
- `projects_list_controls_mode` / `projects_list_controls_threshold` — when the
  task list's lens + sort render (`auto` | `always` | `never`; default
  threshold 10).
- `projects_default_status_entity_uuid` — the global default status list.
- `projects_use_status_translations` — global default for showing translated
  status titles (per-project tri-state override in the project's `settings`).
- `projects_default_preset`, `projects_new_form_top_blocks` — new-project form
  defaults.
- `projects_admin_all_backfilled`, `projects_checklist_flags_backfilled` —
  one-time `migrate_legacy/0` flags. One-way and one-time on purpose:
  re-deciding on every boot would hand back a revoked permission or re-disable
  a feature the Owner turned on.

### Activity actions

`projects.<resource>_<verb>`:

- `projects.project_created/updated/deleted/started/completed/reopened`
- `projects.project_archived/unarchived`
- `projects.template_created/updated/deleted`, `projects.project_created_from_template`
- `projects.task_created/updated/deleted`, `projects.task_promoted`
- `projects.api_key_created/rotated/revoked` (resource: the project); `projects.project_status_changed`
  (the workflow status set over the API). Every entry the API writes carries
  `metadata.via = "api"`, `metadata.api_key` and `metadata.api_key_name`, with the
  key's minter as `actor_uuid`.
- `projects.task_dependency_added/removed`, `projects.dependency_added/removed`
- `projects.assignment_created/updated/started/completed/reopened/removed`
- `projects.assignment_progress_updated`, `projects.assignment_duration_changed`,
  `projects.assignment_tracking_toggled`
- `projects.subproject_created/linked/detached`
- `projects.project_status_changed` (show page)
- `projects.gantt_display_changed/reset`, `projects.calendar_display_changed/reset`
  (settings page; `resource_type: "projects_settings"`)
- `projects.status_entity_provisioned` (`metadata.scope` = `"shared"` |
  `"global_default"`), `projects.default_status_entity_set`,
  `projects.status_translations_toggled`
- `projects.member_added/role_changed/removed`, `projects.health_updated`,
  `projects.event_created/updated/deleted` — the four notification sub-types
  fan out through core's activity→notification bridge whenever their entries
  carry a `target_uuid` (the affected user).

## Database & migrations

Owns a versioned chain: `PhoenixKitProjects.Migrations.Schema` via
`migration_module/0`, marker `pkp_schema:<N>` as a `COMMENT ON TABLE` on
`phoenix_kit_projects`, currently **V22**. `mix phoenix_kit.update` applies it
in hosts by comparing `current_version/0` against
`migrated_version_runtime/1`; tests run it through
`PhoenixKitProjects.Test.SchemaMigration`, keyed on
`Schema.current_version()` so a chain bump re-runs automatically.

The chain is **adoptive**. The project tables were historically created by
core's chain, which stays authoritative for installs migrating through it —
**this chain requires core ≥ V128** and takes over from that composed shape:

- **V1 is a baseline**: an idempotent (`IF NOT EXISTS`) restatement of the
  exact table shape core's chain produces. On a core-migrated install every
  statement no-ops and the marker is simply stamped.
  `migrated_version_runtime/1` treats a marker-less-but-present
  `phoenix_kit_projects` table as already at V1, so existing installs never
  regenerate a pointless migration. **Never edit V1** — a shape change is V2+,
  and one that touches a core-created table needs core's `ExpectedSchema`
  exclusion first.
- **V2+** hold the hub-rework tables (extension enablement, members, work
  entries, whiteboards, events, priorities/labels, portal, grants, …) and never
  ship through core.

Every statement in every version guards itself, so `up/1` always runs the whole
chain start-to-finish and re-running is safe — which is also how the baseline's
idempotency is proved on every test boot. `down/1` exists for protocol
completeness only: on installs whose tables core created, a module-level down
is NOT supported (core's marker still claims the tables); it drops data and is
meant for scratch schemas.

Add a new version as the next `vNN_*` step in `up/1` plus its
`if target < NN` block in `down/1`. UUIDv7 PKs throughout; every table-backed
schema uses `PhoenixKit.SchemaPrefix`.

A schema change that must live in core (a column on a core-owned table) still
ships as a core migration first, then a core release, then a pin bump here.
While iterating ahead of that, develop and test via
`PHOENIX_KIT_PATH=../phoenix_kit`.

## Testing

Test DB `phoenix_kit_projects_test` (override with `PGDATABASE`). Three levels:

- **Unit tests** in `test/phoenix_kit_projects/` — schemas, changesets, pure
  helpers (duration math, the `Errors` atom dispatcher). Always run.
- **Integration tests** in `test/phoenix_kit_projects/integration/` — a real
  PostgreSQL via the Ecto sandbox, through `PhoenixKitProjects.DataCase`
  (which tags them `:integration`).
- **LiveView smoke tests** in `test/phoenix_kit_projects/web/` — drive LVs via
  `Phoenix.LiveViewTest.live/2` against the test Endpoint + Router, through
  `PhoenixKitProjects.LiveCase`.

Integration tests are auto-excluded when the DB is unreachable; `mix test`
never hard-fails on a missing DB. Unit tests run regardless
(`mix test --exclude integration` forces that).

`test_helper.exs` builds the schema the way a host does: it starts the repo,
runs core's versioned migrations via
`PhoenixKit.Migration.ensure_current(TestRepo, log: false)` — **not** the
`Ecto.Migrator.run(TestRepo, [{0, PhoenixKit.Migration}], …)` pattern, which
goes silently stale — then runs the module's own chain through
`Ecto.Migrator.run/4` keyed on `Schema.current_version()`. It also starts
`PhoenixKit.PubSub.Manager`, `PhoenixKit.Users.RateLimiter.Backend` (staff
placeholder registration reaches core's Hammer-backed limiter), pins the URL
prefix to `/` (so `Paths.*` matches the test router's `/en/admin/projects`
scope), and starts `PhoenixKitProjects.Test.Endpoint` (`server: false`).

Support modules in `test/support/`:

| Module | What it is |
|---|---|
| `Test.Repo` | the test repo |
| `Test.Endpoint` | minimal `Phoenix.Endpoint` for LV tests; no port opened |
| `Test.Router` | minimal router whose paths match `Paths.*` (base scope `/en/admin/projects`) |
| `Test.Layouts` | root + app layouts; `app/1` renders `#flash-info` / `#flash-error` / `#flash-warning` so smoke tests can assert flash via `render(view) =~ "Saved."`, and renders `page_crumbs` as `data-crumb` anchors |
| `Test.Hooks` | `:assign_scope` `on_mount` reading `"phoenix_kit_test_scope"` from the session |
| `Test.SchemaMigration` | wraps the module chain for `Ecto.Migrator` |
| `DataCase` | `:integration` tag + SQL Sandbox; hosts `fixture_task/1`, `fixture_project/1`, `fixture_template/1`, `errors_on/1` |
| `LiveCase` | `fake_scope/1` + `put_test_scope/2` for a real `%PhoenixKit.Users.Auth.Scope{}`; reuses `DataCase` fixtures |
| `ActivityLogAssertions` | `assert_activity_logged/2`, `refute_activity_logged/2` |
| `QueryCounter` | statement counting for the batched-read tests |
| `StatusFixtures` | workflow-status catalog fixtures |

Env vars honoured: `PGUSER` / `PGPASSWORD` / `PGHOST` / `PGDATABASE` /
`PGPOOL` (a positive integer; the default `schedulers_online() * 2` opens
dozens of connections). On a Mac whose Postgres role is not `postgres`, run
`PGUSER=<role> mix test` — the default is `postgres` and a missing role
surfaces as a pool timeout that reads like flakiness.
`config :phoenix_kit_projects, :display_log_flush_ms, 30` shrinks the
slider-audit coalescing window (runtime default 1s) so tests can wait it out.

## Feature notes

### The JSON API (`/api/projects/v1`)

The surface an outside agent drives projects with — `dev_docs/guides/api.md`
is the full account. In short: API keys (`ApiKeys`, made on Projects → API
keys; one key can reach several projects, each through its own grant — see
"API keys across projects (V24)") are their own principal — per project a
role of their own, never owner, plus scopes — authorised by `Authz.can_role?/3` (the project's floors
and overrides, nothing else) and the project's feature gates; `Web.Api.Auth`
is the bearer plug, `Web.Api.Json` the shared checks and shapes, the
controllers call the same context functions the LiveViews do. The agent-facing
contract is generated from `Web.Api.Docs.endpoints/0` as `llms.txt` and
`openapi.json`; **never add an endpoint the table does not list**. Ledger
appends require an `Idempotency-Key` (`ApiKeys.idempotent/3`); an agent's
minutes are `kind: "time"` by an `ai_agent` actor, never billable, summed as
`ai_minutes`, and both appends take an optional `occurred_at` (stored as the
entry's `ended_at`; `inserted_at` stays the receipt time). Every key has a
rate limit (`Web.Api.RateLimit`, a bucket per key on core's Hammer backend,
`config :phoenix_kit_projects, :api_rate_limit, limit: 300, window_ms: 60_000`;
`limit: nil` turns it off) applied in the auth plug, so a 429 is never stored
as an idempotent reply. The routes come from `Web.Routes.generate/1` and are
mirrored in `test/support/test_router.ex`; the test endpoint parses JSON for
them.

### API keys across projects (V24, 2026-10-16)

Max, 2026-10-15/16: keys move out of the single project onto **Projects → API
keys**, and "every setting that we already have in the project should also be
for the api permissions" — per project, per area, none / read / write.

- **Grants.** `phoenix_kit_project_api_key_grants` (`Schemas.ApiKeyGrant`):
  `api_key_uuid`, `project_uuid`, `scopes`, `role` (the cap), `inherit`
  (covers sub-projects); unique on key + project. The key's own
  `project_uuid` is its HOME — where a call without `project` acts
  (`ApiKeys.set_home/2` needs a grant there) — and its FK is now `ON DELETE
  SET NULL`: deleting the home project no longer deletes a key that holds
  other grants.
- **Areas** (`ApiAccess`): `project`, `tasks`, `status` (write only: start /
  complete / reopen / transition), `notes`, `comments`, `time`, `usage`,
  `events` (read), `people` (read), then each extension API provider's pair
  (`interactions:read` / `:write` for the CRM). Write includes read;
  `ApiAccess.grid/1` and `scopes/1` convert, `presets/0` only fills the grid.
  Which scope each endpoint needs is the `scope` column of
  `Web.Api.Docs.endpoints/0` — keep it equal to the controller's
  `require_scope` (the briefing is `tasks:read`, `/subprojects` `tasks:write`).
- **`ApiKeys.access_for/2`** — the NEAREST grant up the project's tree
  decides; a grant above with `inherit: false`, or a nearest grant with empty
  scopes ("no access"), is no access — nothing further up is consulted. The
  role: a shared key gets the grant's cap; a personal key the weakest of the
  cap, the person's role on the GRANT's project (sub-projects usually have no
  members) and manager. A person off that project is `:membership_ended`.
  `list_reaching/1` (a project's pages) and `reachable/1` (`GET /me`'s
  `projects`, with `access` per area and `source`) are built on it.
- **Per-request rescoping.** `Json.rescope/2` swaps `pk_api_key` for
  `ApiKeys.view/2` — the key with THAT project's role and scopes — whenever a
  request moves to another project (`scope_project/2` for `project=`,
  `TasksController.fetch/2` for a task ref). `Json.require_scope/2` records
  each scope in `pk_required`, and `Json.still_allowed/1` re-checks them all
  after the move. **The order rule:** select the project first
  (`scope_project` / `fetch`), THEN `require_scope` — checked the other way
  round, the home project's access would authorise a call in another
  project. `still_allowed` is the backstop, not the plan.
- **Idempotency is per project**: the stored key is sha256 of
  `project_uuid:Idempotency-Key`, so the same header in two projects is two
  requests.
- **Leaving a project** deletes only that project's grant
  (`ApiKeys.revoke_for_user/3` → `delete_grant/3`); the key and its other
  grants live on.
- **The migration** gave every existing key exactly the grant it had, with
  its old scopes translated so every token works as before: `tasks:read` →
  also `project/notes/time/usage/events/people:read`; `tasks:write` → also
  `status:write`, `notes:write`; `time:write` → `time:read`; `usage:write` →
  `usage:read`; `project:write` → `project:read`.
- **Pages.** Keys are made, rotated, revoked and granted only on Projects →
  API keys (`Web.ApiKeysLive`). A project's "Your API key" page
  (`Web.ProjectApiLive`) is a read-only list of the viewer's own keys that
  reach it; Modules & Features' "API access" is a read-only list of every
  key that does. Both link to the API keys page (`?project=<uuid>`
  preselects the project). `ApiKeyPanel.setup_prompt/3` names the home
  project and tells the agent to start with `GET /me` and pass `project=`.
- **Comments over the API** (`CommentsController`): `GET` / `POST
  /tasks/{id}/comments`, `comments:read` / `comments:write`, the `:view` /
  `:comment` floors and the comments module switched on; a post needs an
  `Idempotency-Key` and `content` (optional `parent`), and is written as the
  person the key acts for (else its maker), labelled with the key's name.

### What the first agent on the API asked for (2026-10-05) — built, as settings

The 3D-editor session's Claude read the guide, ran 27 calls on ANDI Manager
and reviewed the API from the agent's seat. Max: *"go ahead and build
everything that the other AI needs… make sure that everything is
controllable via settings. We want projects to be very flexible."* A
three-seat panel (grok, zai, codex) converged on the shape; chain **V19**
carries the columns. What landed:

- **`completion`** on a project (`settings["completion"]`: `auto` | `manual`,
  `Project.completion/1`, `ongoing?/1`): ongoing work never completes on its
  own — `decide_completion/1` leaves it, every task done is **caught up**
  (`Projects.caught_up?/1`; the rollup row reads 100% but not done, so an
  ongoing child never completes its parent). Copied onto a sub-project at
  creation (`create_subproject/2`, the form, `POST /subprojects completion`).
  The project form's "Ends" select; the sub-project form's too; "Ongoing" /
  "All caught up" badges in the header.
- **`agents` policy** (`settings["agents"]`, `Project.agent_policy/1` with
  defaults): `take_started_task` (false), `edit_foreign_text` (false),
  `delete_tasks` (`none` | `own` | `any`), `amend_own_ledger` (true). The
  project form's "What an AI agent may do here" card; `/me` and `/project`
  carry `agent_policy`. Enforced in the API: 409 `already_started`, 403
  `foreign_text`, 403 `delete_not_allowed`, 403 `amend_not_allowed`.
- **Provenance** on a task: `created_by_uuid` / `created_by_key_uuid`,
  `started_by_uuid` / `started_by_key_uuid` (server-only fields,
  `Projects.stamp_assignment/2`; the form and the API stamp them).
- **`waiting_on`**, **`origin`** (`source` was taken — it means internal vs
  portal); form fields and row badges. *(A `checklist` column lived here
  from V19 to V22; V23 turned every item into a subtask and dropped it —
  see "Tasks under tasks" below.)*
- **Labels by name** on the API (`Labels.ensure_by_names/3`, creates the
  missing ones when the flag is on); `position: "top"` on create
  (`Projects.top_assignment_position/1`); `updated_since` on `GET /tasks`
  (strict, with `now` in the answer; index on `(project_uuid, updated_at)`).
- **Project notes**: `TaskNotes.create_for_project/3`, `list_for_project/2`
  on the comments anchor `project_notes` (registered in `ResourceLinks.types`);
  `POST /notes`, `GET /notes?since=`.
- **`GET /briefing`**: project + policy, open tasks (≤ 50, priority then
  position, `truncated`) with direction / last outcome / latest note / who
  started / waiting / subtask counts (was checklist counts until V23), sub-projects one line each, project
  notes since. **Ledger corrections**: `PATCH /entries/{id}` (minutes),
  `DELETE /entries/{id}`. **`DELETE /tasks/{id}`** under the policy.

Not built, by choice: a fourth lifecycle status (waiting is a badge), typed
file refs, ETags (an
`updated_since` poll is enough), a claim history (the current holder only).

**The second sweep (2026-10-05, same agent, three reports):** `estimated`
echoed on every entry (`Json.entry/1`: actor, note_uuid, model, estimated)
and kept through a note's usage; `GET /entries` and `GET /tasks/{id}/entries`
(the read behind a correction); `/me.features` is the whole gates map;
`subproject` (`{completion, caught_up, completed_at}`) on a nested row;
`GET /events`, `GET /events/{id}` (`Web.Api.EventsController`, needs the
events extension); the briefing carries `client.interactions` (the Client
extension's provider, `since`-narrowed) and `events` (the next five).
**Task ↔ interaction**: first as a mention token appended to the
description, then (V20, below) as a join table with the token kept in step —
`interaction: <uuid>` on `POST`/`PATCH /tasks` (the provider's `get/2`
supplies the label), `tasks: [<uuid>]` on the CRM's interaction create/update
(`ProjectsLink.link_task/3`), `interactions: [uuid]` on a task, `tasks:
[{uuid, title}]` on an interaction. An extension's `api:`
may now be a LIST of providers (`Extension.normalize_api/2`); the CRM adds
`PhoenixKitCRM.CompanyApi` (`/ext/companies`, the client and its people, on
the interactions scopes). The UI: no progress bar on an ongoing project; a
nested ongoing row says Ongoing / All caught up.

**The panel's sweep of all that (2026-10-05, grok + zai on the surface,
codex on the repo) and what changed — chain V20:** wording ownership follows
the LAST human edit, not creation (`words_by_key_uuid`: the key that wrote
the title/description last, nil for a person's; the form's save clears it,
the API's text edits stamp it; `Json.may_edit_text?/3`); the task ↔
interaction link is a table (`phoenix_kit_project_task_interactions`,
`Projects.link_interaction/4`, `unlink_interaction/2`, `interactions_of/1`,
`tasks_for_interaction/1`; `POST`/`DELETE /tasks/{id}/interactions/{uuid}`)
and the token in the text is kept in step with it (`ensure_interaction_tokens/3`
after an API description rewrite; the token lives on the one-off TASK's
description, on the assignment's — with a copy of the library text — for a
shared task); claims hold for every move out of `in_progress` by another
actor, not only the start; every task-level API action rescopes to the
task's project BEFORE its feature and role gates (codex: a child's floors
were checked against the root); a checklist tick was one row-locked update
(gone with the checklist in V23); `ResourceLinks.visible_resource_uuids/2`
climbs the whole ancestry (a grandchild's records were invisible to a root
member); ledger reads say `limit`/`truncated`, task entries are queried by
`assignment_uuid`, amendments name the key in the trace, tokens/cost entries
take `amount` (`Ledger.update_amount/3`), a billable row is never removed
over the API (403 `billable_entry`); `updated_since` is inclusive; the
briefing orders mine → ready → waiting with `counts`, a `resume` pointer
(this key's latest note), `done_today`, `caught_up_since`, and summarises
children in one pass. Not done: a batched "latest note per task" (50 open
tasks = 50 comment reads; acceptable at one briefing per reset).

**Round four (2026-10-05, the agent's third report):** the interaction
lookup for a task in a sub-project walks up the parent chain within the
key's reach to the project that holds the client (`interaction_label/2` in
`TasksController`), and `POST /tasks` checks the interaction BEFORE creating
the task (404, never a 201 without the link); `now` is floored to whole
seconds wherever a poll reads it back (`updated_at` has no microseconds);
`Json.entry/1` says `billable`; the briefing's client lines drop the bodies.
**A deploy trap:** the extension registry is cached — after a provider
change lands on dev, `Extensions.Registry.refresh()` over the node (the
`/ext/companies` rows vanished from the guide until it ran; the CRM extension
declares `api: [ProjectApi, CompanyApi]` and the stale list held one). The
"events" extension was off on ANDI Manager although it had a planned event —
switched on by hand.

The earlier list, for the record:

- **Sub-items**: a `parent_uuid` on a task or a checklist — a sub-project per
  client question is too heavy (its own workflow status and ledger).
  *(First answered with the checklist; since V23 with real subtasks.)*
- **Project-level notes**: `POST /notes` beside `/time` and `/usage` — half a
  day's report is not about a task (decisions, research, the in-flight block).
- **A briefing read**: `GET /notes?since=` or one call returning the open tasks
  with `direction` and `latest_agent_note` — recovery after a context reset is
  one GET per task today; `last_outcome` and a direction flag on list rows.
- **A waiting state** for a task blocked on someone else (`outcome: blocked`
  on a note is only a claim).
- **Claiming**: `/start` could record the key that started a task and the row
  show it — two sessions can start the same task.
- **Wording protection**: record who created a task; let an agent edit only
  its own titles (the key carries the person's role, so PATCH can reword a
  person's text).
- **Corrections**: a manager's reversing ledger entry (append-only with no
  void leaves a wrong row forever).
- **Polling**: `updated_since` or an ETag on `GET /tasks`; `position` on
  `POST /tasks`; tags and a `source` ("from the client"); file refs beyond
  URLs; no API delete (test rows are cleaned up in the UI).
- **The completion climb**: completing the only task of a test sub-project
  completed the client project (the parent's own rows were all done). The UI
  does the same; whether an API completion should stop at the sub-project, or
  whether a project with no open rows of its own should complete at all, is
  the open question. Documented in the guide for now.

### Tasks under tasks — the API (V23, 2026-10-14)

Max, 2026-10-14: *"let's make proper subtasks because we want flexibility"*.
A task (`Assignment`) may sit under another task of the same project
(`parent_uuid`, any depth; a trigger refuses another project's task and a
loop). `position` stays ONE depth-first order for the project. The V19
checklist is gone: V23 converted every item into a subtask of its task and
dropped the column; its API went with it, no compatibility layer (the
agent guide was rewritten instead). `PhoenixKitProjects.Outline` holds the
shape, the tick rules and the writes; `PhoenixKitProjects.Outline.Api` what
the HTTP layer needs (`info/1` — one read of the shape per list, so
`Json.task/5` can say where each row sits; `batch_create/4`).

- **On every task's JSON**: `parent_task` (the parent's ref or null —
  `parent_ref` keeps its old meaning, a sub-project row's own place),
  `depth`, `subtasks: {done, total}` over the LEAVES of its branch;
  `subtask_refs` (direct children, in order) on the detail.
- **Writes**: `parent` on `POST`/`PATCH /tasks` (a ref or uuid of an
  accepted task row of the same project — never a sub-project row, 409;
  null moves to the top level; through `Outline.move/3`, so the branch moves
  with it); `POST /tasks/{id}/move` `{parent?, after?}` (absent parent =
  stay, null = top; absent after = last, null = first; 409 `cycle`);
  `POST /tasks/batch` `{lines, parent?}` — ≤ 500 lines, strings or
  `{text, depth?, done?}`, one transaction under the project lock, one
  broadcast, an activity row per task; `DELETE /tasks/{id}` answers 409
  `has_subtasks` (with the count) unless `cascade=true`, refuses when a
  sub-project row is under it, and applies the `delete_tasks` policy to
  every row it would take.
- **Reads**: `GET /tasks?parent=none|<ref>`; the briefing lists TOP-LEVEL
  open tasks (each with `subtasks`) plus whatever this key has in hand at
  any depth, so one parent with thirty subtasks cannot fill the cap;
  `open_with_subtasks` counts every open row.
- **Transitions** report `also_changed` — how many OTHER rows the tick rules
  moved (`Outline.Api.statuses/1` before and after; cheap, one select each).

### Tasks under tasks — the model and the typed list (V23, 2026-10-14)

The boss's ask, in Max's words: *"when he creates a simple to-do, he doesn't
even need to go through the add task pop-up… basically a text field that he
can just hit enter… and that would be a new task"*; then *"let's make proper
subtasks because we want flexibility"*. Decided with Max and a codex/zai/grok
panel the same night (answers in Max's review folder, `subtasks-plan-*`).

**The model** (`PhoenixKitProjects.Outline`):

- `parent_uuid` on a task row; same project, never its own ancestor — a
  trigger (`pkp_assignment_parent_check`) holds both, so no insert path can
  skip them. A subtask is a whole task (number, owner, dates, hours).
- `position` stays ONE order per project, written **depth first**: a parent
  is followed by everything under it. Readers that only sort by position
  stay sensible; readers that need the shape call `Outline.walk/1`. Every
  write of the shape goes through `Outline.write_order/2` (it clears changed
  parents before setting them, so a swap never passes through a cycle).
- **Counts count leaves** (`Outline.leaves/1`, `Projects.leaves_only/1` in
  SQL): a task with subtasks is the sum of them, never a unit itself.
- **Tick rules** (`Outline.settle/3`, called from `update_assignment_status/2`
  and `update_assignment_form/3`, so every path gets them): ticking a task
  ticks everything open under it (a sub-project row is left to its project);
  the last subtask ticked ticks its parent unless
  `settings["outline"]["complete_parent"] == false`; reopening a subtask
  reopens every done ancestor (to `in_progress`); unticking a parent touches
  nothing below. The page asks first when the tick would close other
  people's subtasks (`complete_or_ask/3`).
- **Held tasks**: `review_status: "removed"`. A line taken out of the typed
  list whose task carries something (`Outline.protected?/2`: hours, notes,
  discussion, description, owner, dates, estimate, dependency, begun, from
  the portal, a library task) is held, out of every list and count like a
  pending request, and shown under the list with Restore / Delete. A plain
  one-off task is deleted outright. A held row whose id comes back in a
  line is revived in place — that is how cut-and-paste MOVES a task.
- Deleting a task deletes what is under it (`Projects.delete_assignment/1`,
  deepest first, so a sub-project row tears its project down and portal
  files go).
- The V19 checklist is gone: V23 converted every item to a subtask.

**The list** (`Web.OutlineList`, hooks in `priv/static/assets/phoenix_kit_projects.js`,
shipped through `js_sources/0` as `PhoenixKitProjectsHooks`):

- **Text face** (`PkpOutline`): the whole list is one contenteditable; every
  line element carries its task's uuid. The browser only edits text INSIDE a
  line — every structural edit (Enter, Backspace at a line start, a deletion
  across lines, paste, cut, Tab, Alt+arrows, undo) is done by the hook on
  the elements, so an id can only move with its line. After a pause the whole
  list goes to the server as `outline_sync` (lines + every id the browser has
  been shown); `Outline.sync/4` creates, renames, revives, deletes or holds,
  and rewrites the order. Only a task the browser KNEW and no longer lists is
  taken as removed. Server pushes (`pkp_outline:lines`) are applied when the
  browser is idle. Cut/copy put plain indented text on the clipboard plus an
  `application/x-pkp-outline` payload with the ids.
- **Cards**: the old rows, nested by depth, foldable, a "3/7" count, titles
  typed in place (`PkpTitle`: Enter adds the next task, Tab nests, Backspace
  on a fresh empty one drops it, a multi-line paste adds a task per line).
- **Which face**: `settings["outline"]["style"]` — `auto` (text while no row
  feature is on — in_progress, assignees, priorities, labels, estimates,
  progress, dependencies, scheduling, ledger — and no sub-project row),
  `text`, `cards`. `settings["outline"]["row"]` keeps chosen features off the
  cards (they stay in the form). A template is always cards.
- The board shows top-level tasks only, each with its subtask count; the
  timeline nests; calendars show a subtask only when it has its own date.
- Feature flag `subtasks` (default on): off, Tab does nothing; existing
  subtasks keep their place.
- **Known limit**: two browsers typing at once — a task deleted in one can
  come back as a NEW task if the other was mid-typing when the delete
  arrived and still has the line (its id is no longer the project's, so the
  line reads as new). Low odds; the alternative (refusing unknown ids)
  breaks undo of a delete.

### Short names: a project's key, a task's ref (V22, 2026-10-10)

The boss, via Max: *"everything uses the UUID, which is very not user
friendly. Ideally, we'd have better internal structures, kind of like Jira
style."* The plan went to codex, grok, zai and gemini first; what they
agreed on is what is built, and where they corrected it is marked.

- **A project has a `key`** (`ANDI`, 2–10 of `A-Z0-9` with a letter) and
  **a task a `number`** in its project; `ANDI-42` is the task's **ref**
  (`PhoenixKitProjects.Refs`: the shape, the one strict parser — a uuid, a
  key or `KEY-number`, nothing looser — and the key a name suggests). The
  uuid stays the identity of every row and valid everywhere; code that
  STORES a pointer stores the uuid.
- **Refs in text** (`PhoenixKitProjects.RefText`; Max, 2026-10-11: *"in the
  text you would be able to use something like #test-001 instead of
  #555-66-66…"*). The stored form of a link stays core's mention token
  (it points at the uuid, so a renamed key or a moved project breaks
  nothing); what changed is the edit box. `expand/1` turns a typed
  `#KEY-42` / `#KEY` that names a real task or project into its token,
  labelled with the ref only, and runs as a `prepare_changes` of the three
  description changesets (`expand_on_write/2`: `Task`, `Assignment`,
  `Project`, their `translations` too) and on a note's body — on the WRITE,
  never on a form's validate, so the text does not change under the cursor.
  A ref resolves only for a DECLARED writer (`RefText.put_writer/1`, in the
  process dictionary): `Web.Helpers.assign_embed_user/2` declares the
  viewer's scope for every LiveView, `Web.Api.Auth` the key's reach; a
  process that declared nobody (the public portal, a job) expands nothing,
  and tests that write fixtures directly declare `:all`. Without this a
  typed `#SECRET-7` said whether it exists (codex, 2026-10-13).
  `collapse/1` shows project and task tokens as refs again; the forms hold
  the record collapsed (`collapse_fields/2`), so an untouched description
  is no change. `Web.Mentions` replaces `use PhoenixKit.Mentions.Live` in
  the two forms: the same typeahead, but a picked project or task inserts
  `#KEY-42`. Neither direction asks who is looking — see the moduledoc for
  why that leaks nothing. A comment typed in the comments module's own box
  does not pass through here and keeps the long token.
- **One key per project, sub-projects included** (all four seats): a
  sub-project can be moved out or under another project, and its refs must
  not change when it does. A sub-project's row on the parent's list is
  called by the CHILD's key (`Assignment.ref/1`); its own place in that
  list is `row_ref/1` (grok: an agent handed the row's number would log
  work against the linking row).
- **The database owns both rules** (codex, grok, gemini: the next insert
  path will not call the context function). `phoenix_kit_project_keys` is
  every key any project has had; a trigger on the projects table registers
  a key when it is set and refuses another project's, raising the
  registry's primary-key name so `Project.changeset/2` reports it as a
  unique violation. A row outlives its project: a renamed-from key keeps
  resolving (`Projects.project_by_key/1`, `former_keys/1`) and neither it
  nor a deleted project's key is ever handed on. A second trigger numbers
  every new assignment from `phoenix_kit_project_task_counters` — its own
  table (grok), so numbering never locks the project row a form is saving.
  Numbers are never reused.
- **Where a key comes from.** `Projects.create_project/2` suggests one from
  the name for a real project (`ANDI Manager` → `ANDI`, `3D editor` →
  `3DE`, `PhoenixKit` → `PK`, `Kitchen` → `KIT`, a taken one → `KIT2`); the
  form shows the suggestion and takes a typed one; a project inserted with
  none gets a placeholder from a sequence (`P7`, and `TPL7` for a template,
  which therefore never squats a key a project would want — the panel's
  answer to "should templates have keys"). An emptied key field never
  renames a keyed project (`keep_key_when_blank/1`).
- **Lookups take either.** `Projects.get_project/1` and `get_assignment/1`
  answer for a uuid or a ref and `nil` for anything else (they used to
  raise on a non-uuid), so every page's `:id` segment and every API path
  param resolves both. Resolve first, then authorize: a foreign ref is the
  same not-found as an unknown one.
- **Where it shows.** `Paths.*` take a project struct and then spell the
  key (`/admin/projects/ANDI/tasks?task=ANDI-42`); the project page mirrors
  that address into the bar; `<.ref_chip>` on task rows, board cards, the
  sub-project row, the page header and the task drawer; the `#` search
  finds a typed ref; a link to a task carries it. The API answers `key`,
  `ref`, `number`, `parent_ref` and its guide has a "Short names" section.
- **Is a key free?** `Projects.key_taken?/1` — true for a key a live project
  holds or the registry remembers (renamed away from, or its project
  deleted); normalised like `Refs.normalize_key/1`. A host that builds keys of
  its own checks it before `create_project/2`; check-then-create is still a
  race, and the changeset's `constraint: :unique` error stays the authority.
- **Tests that create projects by name are not async.** Two sandboxed
  transactions inserting the same suggested key wait on each other at the
  registry and deadlock once each creates a second project;
  `fixture_project/1` passes a key of its own (`DataCase.unique_key/0`).
- **Not built, on purpose:** a ref for anything but projects and tasks
  (the panel: notes, ledger rows and events are quoted as their task);
  moving a task between projects (when it comes: a new number in the
  destination and the old ref kept as an alias, never a renumber);
  releasing a key on archive.

### Moving a project in the tree (2026-10-10)

Max could not find how to take the "3D editor" sub-project out of its
parent: the only way was "Make standalone" in the row menu of the PARENT's
task list, and it left the project with no members, none of the parent's
modules and its agent's key behind.

- `Projects.move_project/2` — to the top level or under another project,
  in one transaction under the sub-project link lock (from one parent to
  another in one step; a refusal rolls the old link back).
- `PhoenixKitProjects.ProjectMove` — `preview/2` says what the old parent
  has that the project does not (members, module rows, the live keys of
  its ancestors, which reach it only while it is nested there) and where
  it could go; `run/4` checks the mover (`:edit_settings` on the project,
  `:edit_tasks` on a new parent) and carries what was ticked, each thing
  only where the mover may grant it. `ApiKeys.move/3` points a key at the
  project and keeps its token. `preview.links` counts the task ↔
  interaction links that point at an interaction logged OUTSIDE the
  project (the interactions provider's optional `projects_of/1` says
  where); the dialog says they keep opening while the project has the same
  client, and warns when it would be left with none. The CRM side of that
  rule: a project reads what other projects logged with its client company
  (`Interactions.list_for_project/2` `client:`), and writes only its own.
- `Web.Components.MoveProject` — the dialog, in `ConfirmAction`'s shape
  (one modal, one event clause per page): on the project's own ⋮ menu, on
  a sub-project's row ("Move out…") and on a row of the projects list.

- **Host move lock.** `config :phoenix_kit_projects, move_lock: {Mod, :fun}`;
  `Mod.fun/1` gets a LIST of `%Project{}` and returns `%{project_uuid => reason}`
  for the ones that must stay where they are (reason: a string shown to the
  user). One call per page load — `PhoenixKitProjects.MoveLock.reasons/1` — and
  the pages keep the answer in a `:move_locks` assign, so the hook can answer
  with one query and HEEX never calls it per row. Unset = nothing locked. A hook
  that raises, exits or returns a non-map fails OPEN (nothing locked,
  `Logger.warning`), like the other host hooks. Enforced in
  `ProjectMove.run/4` (`{:error, {:locked, reason}}`), by `MoveProject`'s
  `move_project_open` (no dialog, a flash with the reason), and by the «Project
  to nest» picker in `AssignmentFormLive` (locked projects are not offered and
  `save_subproject` re-checks), and by the `detach_subproject` event ("Make
  standalone" — no menu entry renders it any more, but the handler is alive). The
  hook runs on every reload of the list and the project page, so it must be fast
  (one query for the whole list). A config value that is not `{Module, :function}`
  is ignored with one warning. The three «Move…» entries render
  `MoveProject.locked_menu_item/1` — a greyed `<li aria-disabled="true">`
  with the reason as `title` and no `phx-click`. `Projects.move_project/2` and
  `link_subproject/2` stay policy-free: the lock is a rule of the screens and of
  `ProjectMove`, not of the context.

### A task's own dates (V21, 2026-10-06)

Max: *"build a start date and an end date."* Until V21 a task's days were
only ever computed — duration plus its place in the order, walked from the
project's start by `ScheduleLayout` — and an ongoing project has no start
to walk from, so nothing there could carry a date.

- **Two optional columns on the assignment**, `start_date` and `end_date`
  (`DATE`: a day, no time and no zone — "by Thursday" is Thursday wherever
  the reader sits). Either may stand alone; a check constraint and
  `Assignment.validate_dates/1` keep the end from preceding the start.
  They are ordinary form fields (cast in `changeset/2`), ungated like
  `waiting_on`: blank costs nothing on the row.
- **`Assignment.overdue?/2`**: the end date has passed and the task is not
  done. The row's date badge turns red on it; the API answers it as
  `overdue` and counts it in the briefing.
- **The schedule honours them** (`ScheduleLayout.pin_dates/2`): a dated
  task sits on its days instead of where the walk put it — both dates:
  that range; only a start: its computed length from that day, one day at
  least; only an end: that one day. The walk itself is not moved (the
  order still says what follows what), and every ancestor sub-project's
  span is widened to cover it. A pinned span carries `pinned: {from, to}`;
  `CalendarDisplay.task_events/4` draws those days as they are rather than
  converting the instants into the viewer's zone (which added a day east
  of UTC and lost one west of it — the test walks four offsets).
- **API**: `start_date` / `end_date` on create and PATCH (`YYYY-MM-DD`;
  null or empty clears; anything else, or an end before the start, is a
  422 before any write), both plus `overdue` on every task row and in the
  briefing, `counts.overdue` there, and `GET /tasks?due_before=<day>`.
- **Assignee over the API (2026-10-07)**: `Web.Api.Assignee` reads
  (`to_json/1`), sets (`attrs/2` from a request's `assignee`: `me`, a
  person's uuid, `{"team"|"department": uuid}`, null) and filters
  (`filter/3`); `GET /people` lists who a task can be for, names only.
  The feature and the `assign_tasks` action are checked only when the
  field is sent. Nothing is assigned by default.
- **A link to a task opens it (2026-10-07)**: `ResourceLinks` resolves a
  task to `<project>/tasks?task=<uuid>#task-<uuid>`; `ProjectShowLive`
  rings the row (`focus_task/2`, widening the lens if it hid the row) and
  hands `PopupHostLive` an `"open"` session entry, which it sends itself
  as an `:opened` once subscribed (no race with the page's own broadcast).
- **Ongoing on the start bar (2026-10-07)**: the Ongoing / All caught up
  badges sit on the start bar, which for an unstarted ongoing project is
  only the Start button (no "set up tasks, then start"); the header keeps
  them only when the project has no lifecycle. The list's connector rail
  needs two rows: through a lone sub-project it read as a dependency.
- Not done: dates on a sub-project's row (its span is its children's), a
  date on a library task (a template has no calendar), and a "due this
  week" view in the UI — the calendar and the badge are the view for now.

### Task notes: the long record, apart from the discussion (2026-10-05)

Max: an agent "would want to write as much information as possible … but
it becomes something a human would never read"; keep the description the
TLDR, fold the long record away, keep a running token total per task, and
track the handoffs ("the boss says no, that's wrong; the second person
redoes it") so the next worker reads the original reasoning AND the new
direction. `TaskNotes` is that record: comments on the anchor type
`project_task_notes` (the discussion stays on `assignment`), one note
profile validated in the context and nowhere else — `kind` (`agent_note`
via the API, `note` by a person, `redirect` by a person only), a required
one-line `summary` on agent notes and redirects, `outcome` (a claim about
the attempt, never the task's status), `refs` (`{type, id, url?, label?}`
per note — shape-validated, never fetched, free slug type), `next_steps`,
and `usage` whose figures are LEDGER rows written in the same transaction
(`metadata.note_uuid` on the rows, `usage.entries` on the note; totals are
sums over the ledger, never over the note). The note's author is the
key's accountable person with the key's name pinned as display name. The
API: `GET/POST /tasks/:id/notes`; `GET /tasks/:id` leads with `direction`
(the latest redirect), `last_outcome`, `latest_agent_note`,
`display_summary` (description → redirect → agent summary) and `totals`.
On the page: a second drawer button on the task row (cpu-chip icon, note
count, tokens), the comments component on the notes anchor with the
usage / outcome / redirect lines as decorations, a "Change the direction"
form (a redirect) and "Use as description" (adopts the latest summary,
logged as machine-made when it was an agent's). Panel (grok, zai, codex,
2026-10-05) shaped it: summary required, refs per note not per task, a
typed redirect the task surfaces first, usage never stored as a second
total. Known gaps, deliberate: the idempotency record is stored after
the transaction (a crash in between can double-count on retry); a note's
author may edit or delete it through the comments UI (the ledger rows
stay); Summarize through the AI module is not built — `display_summary`
and "Use as description" are the honest TLDR until it is.

### An extension's record on the API (`/ext/:resource`, 2026-10-05)

Max: "make sure that all the stuff is editable via the API because my AI
knows stuff about the meeting". A meeting is the CRM's row, and this
module never names a CRM function — so an extension may put ONE of its
records on this API by declaring `api: Module` in its
`phoenix_kit_project_extensions/0` map; the module follows
`Extensions.ApiProvider` (`resource/0`, `scopes/0`, `action/0`, `list/2`,
`get/2`, `create/2`, `update/3`, `docs/0`). `Web.Api.ExtController` serves
`GET/POST /ext/<resource>` and `GET/PATCH /ext/<resource>/:id` with the
usual three checks first — the provider's scope (its scopes join
`ApiKey.scopes/0`, so the key panel offers them), the extension enabled on
the project (else 403 `feature_disabled` naming the extension key), the
key's role at the provider's action (an action an installed extension
declares in `permission_actions` floors at member — `Authz.floor_for/2`'s
"future refinement", done) — then `apply/3` into the provider with a
`ctx` (project, key, accountable person, agent actor). The provider's
`docs/0` rows join `Docs.endpoints/0`, so `llms.txt` and `openapi.json`
carry the resource. `Extensions.config/3` is what a provider reads to know
the project's client. The CRM's `PhoenixKitCRM.ProjectApi` is the first:
`/ext/interactions`. `test/phoenix_kit_projects/web/api_ext_test.exs`
proves the mechanism with a fake provider registered through
`config :phoenix_kit_projects, :extension_providers`.

### Tasks and `#` mentions

A task's description goes through core's mentions (`<.translatable_field
… mentions>` in the form, `<.mention_text>` on the page) and — since the
CRM's meetings asked (2026-10-05) — is INDEXED too: the assignment form
(`sync_task_mentions/3`) and the API's create/update call
`PhoenixKit.Mentions.sync("project_task", assignment_uuid, description)`,
so a task whose text carries `#[crm_interaction:…|…]` is listed on the
meeting through `Mentions.list_backlinks/3`. Before that only sub-project
and project descriptions were synced; a `#` in a task rendered as a chip
and was never a backlink. `AssignmentFormLive` `:new` takes a
`description` param next to `title` for exactly this (the CRM's "Add task"
pre-fills the chip). The link is the text: edit the chip out and the
backlink goes with it (panel 2:1 against an extra origin field).

Idea, not built (2026-10-05, Max: skip for now): **webhooks** on task events,
so an agent is handed a task instead of polling — the module already
broadcasts every task change on `PhoenixKitProjects.PubSub`, so a webhook
would be a subscriber that POSTs to a URL stored on the key (with a signing
secret, retries with backoff, and a delivery log). Until then an agent polls
`GET /tasks?status=open` no more than once a minute.


| Feature | The constraint that must hold | Guide |
|---|---|---|
| Embedding via `live_render` | Every LV is embeddable and must stay so — an LV that exports `handle_params/3` cannot mount off-router. The host passes identity, the host authorizes. | [`dev_docs/guides/embedding.md`](dev_docs/guides/embedding.md), [`dev_docs/embedding_audit.md`](dev_docs/embedding_audit.md), [`dev_docs/embedding_emit.md`](dev_docs/embedding_emit.md) |
| The project page, list pages, breadcrumbs | Every tab target is validated against the feature map / contributed tab list — a forged `switch_tab` lands on the list, never on a gated tab. Timeline and Calendar render the SAME `ScheduleLayout` walk, so they can never disagree about a date. | [`dev_docs/guides/project-page.md`](dev_docs/guides/project-page.md) |
| Quick-add and the add-task sheet | The write is ONE transaction that locks the project row (`FOR UPDATE`) and does nothing else — broadcasts fire after commit, the activity log stays with the LiveView. The full form calls the same helper, so the two paths cannot drift. | [`dev_docs/guides/quick-add.md`](dev_docs/guides/quick-add.md) |
| Workflow statuses | Statuses cement at `started_at` and the source freezes with them: `save(:edit)` runs `Statuses.lock_status_source/2` server-side, so a crafted submit past the disabled control cannot change a started project's source. | [`dev_docs/guides/workflow-statuses.md`](dev_docs/guides/workflow-statuses.md) |
| Sub-projects | The child project is the source of truth; the parent's linking assignment carries denormalized rollup so every existing read site works unchanged. Exactly one of `task_uuid` / `child_project_uuid` (DB CHECK + changeset), at most one parent (partial unique index), `ON DELETE RESTRICT`. | [`dev_docs/guides/sub-projects.md`](dev_docs/guides/sub-projects.md) |
| Multilang user-input content | Non-translatable fields must be siblings OUTSIDE `<.multilang_fields_wrapper>` — the wrapper keys its id on `@current_lang`, so morphdom re-mounts everything inside on a tab switch and their state is lost. An `:edit` form opens on the viewing language (`mount_multilang(open_on: :viewing_language)`); `:new` opens on the main language, which holds the required fields. | [`dev_docs/guides/multilang-content.md`](dev_docs/guides/multilang-content.md) |
| Whiteboards | A board's shapes are core annotations anchored by `target_type: "projects_whiteboard"` + `target_uuid`; `file_uuid` stays nullable so file-backed boards keep rendering through the file viewer. | [`dev_docs/guides/whiteboards.md`](dev_docs/guides/whiteboards.md) |
| Dashboard widgets | One-way contract: this module never depends on `phoenix_kit_dashboards`. Every widget guards its reads behind `Helpers.available?/0` and `Statuses.available?/0` and renders an empty state rather than crashing the host board; a stateful LiveComponent's `render/1` returns a single static root. | [`dev_docs/guides/dashboard-widgets.md`](dev_docs/guides/dashboard-widgets.md) |
| Schedule math and completion | Durations normalize to hours through `Task.to_hours/3` only; per-task `counts_weekends` overrides the project setting. `recompute_project_completion/1` runs after every assignment status/progress/removal change. | [`dev_docs/guides/schedule-math.md`](dev_docs/guides/schedule-math.md) |

### Embedding host contract

The three tables a host app depends on. Full prose in
[`dev_docs/guides/embedding.md`](dev_docs/guides/embedding.md).

`live_render` session keys — all optional unless noted:

| Key | Applies to | Meaning |
|---|---|---|
| `"id"` | `ProjectShowLive`, `ProjectGanttLive`, `ProjectCalendarLive`, form LVs on `:edit` | **Required.** String UUID of the record |
| `"project_id"` | `AssignmentFormLive` (`:new` and `:edit`) | **Required.** Owning project UUID |
| `"live_action"` | form LVs | `"new"` \| `"edit"`; defaults `:new`, resolved via `String.to_existing_atom/1` so unknown values fall back |
| `"template"` | `ProjectFormLive` `:new` | Template UUID that prefills the picker |
| `"view"` | `TasksLive` | `"list"` \| `"groups"`; defaults `"list"` |
| `"headless"` | `ProjectGanttLive`, `ProjectCalendarLive` | Drops the back-link when nested as a tab |
| `"wrapper_class"` | all | Overrides the outermost `<div>` class (default is the standalone-admin class) |
| `"locale"` | all | Restores both Gettext backends inside the embedded mount; absent is a no-op |
| `"current_user_uuid"` | all | The viewer's UUID **as a string, never a `%User{}`**. Absent/unknown/inactive degrades to anonymous, never crashes |
| `"redirect_to"` | form LVs | Path `push_navigate`d on save / mount-error instead of the admin default |
| `"tab_url_sync"` | `ProjectShowLive` | Real boolean; **defaults `false`** in embeds — an embed must not rewrite the host's address bar |
| `"mode"` | all | `"navigate"` (default) \| `"emit"` \| `"popup"` |
| `"pubsub_topic"` | all | **Required** when `mode` is `"emit"` or `"popup"` |
| `"frame_ref"` | all | Race-safe pop identity, inherited from PopupHost |
| `"close_on"` | all | Subset of `["closed", "saved", "deleted"]`; defaults `["closed"]` |
| `"project_uuid"` | contributed extension tabs | The project being viewed. Takes the place of `"id"` for a contributed tab — the only key it needs |
| `"ext_key"` | contributed extension tabs | The `key` of the extension entry that contributed the tab |
| `"instance_key"` | contributed extension tabs | Which enablement row this render is; always `"default"` |
| `"config"` | contributed extension tabs | The project's stored values for the extension's `config_schema`; `%{}` when none |
| `"can_write"` | contributed extension tabs | Boolean the hub resolved for the viewer against the extension's write action (its first `permission_actions` entry other than `:view`); `false` when it declares none or the viewer is unidentified. The tab's only write authorization — it has no scope |
| `"host_paths"` | contributed extension tabs | `%{"new_task" => path}` — where the hub's own pages are, so a tab (the CRM's "add a task from this meeting") can send someone there without naming this module's routes |

Emit-mode event vocabulary (UI-intent verbs, deliberately disjoint from
`PhoenixKitProjects.PubSub`'s content verbs so `handle_info` clauses never
collide):

```elixir
{:projects, :opened,  %{lv, session, frame_ref}}
{:projects, :closed,  %{frame_ref}}
{:projects, :saved,   %{kind, action, record, close, next, frame_ref}}
{:projects, :deleted, %{kind, uuid, close, frame_ref}}
{:projects, :dirty,   %{frame_ref, dirty}}   # unsaved edits ⇒ host makes the frame un-closeable
```

`record` on `:saved` is **`%{uuid: ...}` only**, never the full Ecto struct —
the payload rides a host-supplied topic that may be relayed over the
client-readable wire, and a preloaded record would leak PII. `close:` is
emitter-controlled and `PopupHostLive` pops iff `close: true` AND `frame_ref`
matches the top frame.

`PopupHostLive`'s own session keys:

| Key | Default | Notes |
|---|---|---|
| `"root_view"` | `nil` | The LV rendered as the host's base frame |
| `"placement"` | `"center"` | `"end"` renders every frame as a full-height right-hand sheet |
| `"max_width"` | `6xl` centered, `2xl` as a drawer | any core `max_width` value (`sm` … `7xl`, `full`) |

`PopupHostLive` forwards `current_user_uuid` and `locale` into every child
session, so a popup-host integration passes the viewer's uuid once.

## Versioning & releases

SemVer. The version is single-sourced in `mix.exs` (`@version`); `version/0`
reads it at compile time and the behaviour test asserts against
`Mix.Project.config()[:version]`, so nothing else needs bumping.

Release procedure (the steps the maintainer runs):

1. Bump `@version` in `mix.exs`; add a `CHANGELOG.md` entry headed `## x.y.z - YYYY-MM-DD`.
2. `mix precommit` clean.
3. Commit (`"Bump version to x.y.z"`) and push; verify the push landed.
4. `mix hex.publish`.
5. Tag, matching the form of the newest existing tag (`git tag --sort=-creatordate | head -1` shows it), and push the tag.
6. GitHub release via `gh release create` if the repo does those (`gh release list` shows whether it does).

Tags are immutable pointers: never tag before the commit is pushed and the
publish has succeeded.

`priv/media/` is RUNTIME OUTPUT — the Storage module's local bucket writes
uploads there and a test run fills it. Hex resolves `files:` against the
working directory, not git, so gitignoring is not enough; `mix.exs` carries an
`exclude_patterns` entry for it. Run the suite before publishing and check.

## Pull requests & commits

- Commit messages start with an action verb (`Add`, `Update`, `Fix`, `Remove`, `Merge`). No AI attribution and no `Co-Authored-By` trailers.
- Version bumps and CHANGELOG entries land with the release commit on upstream, not in feature PRs.
- Review files live in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md`, one file per reviewing agent, never edited by another agent; `FOLLOW_UP.md` records how each finding was resolved. Severities: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.

Module-local additions to that convention:

- `{pr_number}` is the bare PR number (`35-public-portal-review-queue`, not
  `projects35-…`) — the path is already scoped to this repo, and a prefix
  breaks the numeric sort. `{slug}` is short, lowercase, hyphenated, and
  describes the change rather than the review.
- Name a review for its author, not its stage: `phase1.md` tells a later reader
  nothing about who wrote it or whether to trust it. Put the phase in the
  document's heading instead. `REVIEW.md` is a review with no agent behind it;
  `AGGREGATED_REVIEW.md` is a synthesis sitting beside the originals rather
  than replacing them; `README.md` is the PR's own summary, not a review.
- Nothing review-shaped belongs at the repo root. Work that never was a PR
  still gets a folder here, keyed to whatever does identify it (a commit sha,
  or a plain name whose first paragraph states that it is not a PR folder).
- Commit the review folder. An uncommitted review is one `git clean` from gone.

### An extension's dated things on the Calendar tab (2026-10-10)

The CRM's plan for a client meeting stopped being a project event (CRM V9:
a plan is an interaction with `status: "planned"`), so it would have left
the project's Calendar tab. An extension declaration may now carry
`calendar: {module, fun}` (`fun.(project_uuid, from, until)` →
`%{items, truncated}`; item shape in `Extensions.Extension`'s moduledoc).
`Extensions.calendar_items/3` collects from the project's ENABLED
extensions, rescued per provider; `ProjectEventsLive` draws the items
beside the project's own events (grid id `"ext:<source>:<id>"`, accent
colour, a cancelled one greyed with ✕), lists the planned ones under
Upcoming, and opens one read-only with a link to the extension's own tab.
Nothing is copied: the tab asks on load, on a month change and when the
extension calls `Extensions.calendar_changed/1`
(`{:projects, :project_calendar_changed, _}` on the project topic). The
briefing gained `client.planned` (the provider's list with
`status=planned`); `GET /events` stays the project's own events.

## Hours (2026-10-10)

`Ledger` writes, `Hours` reads. `PhoenixKitProjects.Hours` takes one filter
map (`filters/1`: projects or `:all`, a period, workers, a task, billable, the
viewer's offset) and answers `list/2` (a page of entries with who / task /
project resolved for the page), `summary/2` (totals, by worker / task /
project / day and the worker × day matrix — six grouped reads whatever the
size, pinned in `hours_test.exs` with `QueryCounter`), `timesheet/1`,
`workers/1` and `task_options/2`. Things worth knowing before touching it:

- **An entry counts on the day the work was done**: `ended_at`, else
  `started_at`, else `inserted_at` (`Hours.work_at/1`). The API's `occurred_at`
  is stored as `ended_at`, so a batch reported the morning after lands on its
  own day.
- **One person, one line.** A staff record linked to a user account folds
  into that user (`worker_index/1` answers the CANONICAL key), and a filter
  on either identity finds both (`expand_workers/1`). An agent is named after
  its API key, else the `api_key_name` its entries carry.
- **`minutes` is people's time, `ai_minutes` an agent's** — the split
  `Ledger.totals_for_project/1` makes.
- **Days are cut with ONE offset per read** (`Hours.Period.offset_seconds/2`),
  so a period across a daylight-saving switch has its days an hour off on one
  side; totals are unaffected. Core's per-instant `TimeZone` helpers are newer
  than this module's core floor.
- **Ask `Authz.can?/5` with the project STRUCT.** With a bare uuid the resolver
  cannot read the project's own "who can do what" floors and judges by the
  defaults; `Hours.projects_by_uuid/1` is the batched read the page uses.

`Web.ProjectHoursLive` is ONE LiveView in two places: the project's **Hours
tab** — a tab the Tasks extension contributes with `requires_flag: "ledger"`
(a tab-level key `Extension` keeps and `ProjectShowLive.ext_tabs_for/3`
honours through `Features.on?/2`), mounted with the extension-tab session —
and the admin subtab `projects/hours`, over `Hours.visible_project_uuids/1`
(`:all` for `projects.admin_all`, else memberships / grants / open projects
plus what is nested under them). Filters ride core's `UrlState` in `:history`
mode; only the routed page renders the sync hook, a tab leaving the address
bar to its host. Logging one's own time needs `:log_time`; logging for
somebody else, or changing another person's entry, `:edit_tasks`; an entry
already on an invoice (`Invoicing.invoiced_entry_uuids/1`) is shown and never
changed there. The chart is server-rendered boxes (no JS, no new hook); its
colours are eight CSS variables on `.pk-hours-viz`. The report replaces the
page's content rather than opening a dialog (a dialog prints as its box):
`Hours.Report` builds the text and the CSV (formula-leading cells written as
text), the print rules hide everything but `.pk-hours-report`. On the API,
`GET /hours` is the same read (`Web.Api.HoursController`).

Not built: a running timer; editing an entry's day, note or person (the
ledger amends minutes and the billable flag only); a saved or scheduled
report; a true PDF file (the browser's print makes one).

## TODOs

- **Drop the embed-user core-helper fallback.** `Web.Helpers.assign_embed_user/2`
  delegates to core's `PhoenixKitWeb.Users.Auth.assign_embedded_current_user/2`
  only when the running `phoenix_kit` exports it (a `function_exported?`/`apply`
  forward-compat guard), and otherwise falls back to a local copy
  (`local_assign_embed_user/2` + `resolve_embed_identity/1`) so a Hex-pinned
  build stays green against older cores. The two paths are behaviourally
  identical. **Trigger:** once the `phoenix_kit` floor in `mix.exs` includes the
  release shipping `assign_embedded_current_user/2`, remove the guard, the
  fallback and `resolve_embed_identity/1`, and call the core helper directly.
- **Per-task "count as work hours" toggle + per-user work schedule.** The
  planned replacement for `planned_end_for/2`'s weekday-only approximation;
  design, migration scope and out-of-scope list are in
  [`dev_docs/guides/schedule-math.md`](dev_docs/guides/schedule-math.md).
  **Trigger:** the staff-side `Person.work_schedule` column ships in the same
  wave; neither side has landed, and they must ship together.
- **Drop the legacy `status` column** on `phoenix_kit_projects` in a future
  chain version if no string-lifecycle feature claims the slot (see
  Conventions).
- **Dashboards catalog strings are untranslatable from here.**
  `phoenix_kit_dashboards` translates provider strings through its own backend.
  **Trigger:** that helper honouring a provider backend.

## The projects list: columns, sorts and filters (2026-10-10)

The boss asked for "way more columns" on the projects list — the client,
task counts — and to filter and sort by them. Three pieces:

- **`ListMetrics.load(projects, families, opts)`** reads what the columns
  show for a whole page of projects. Columns are grouped into FAMILIES
  (`:tasks`, `:due`, `:events`, `:members`, `:assignee`, `:ledger`,
  `:activity`, `:creators`, `:parents`, `:ext`); only the families behind
  the visible columns, the active sort and the set filters are read, each
  in a fixed number of statements (`batched_list_metrics_test.exs`).
  Progress and task counts come from the TREE summary (a done task is 100
  whatever its slider says, a sub-project rolls into its parent) — the flat
  `project_summaries/1` sums the raw sliders and disagrees with the project
  page for a task completed without moving its slider.
- **`Web.ProjectListColumns`** is the roster as data: a column's label,
  family, sort and alignment (`specs/0`), the in-memory `sort/5` (nil last
  whichever way, ties by name) and `filter/4`. **To add a column:** one
  entry in `specs/0`, a `sort_value/4` clause if it sorts, a
  `column_cell/3` clause in `ProjectsLive`, and a `ListUi.column_priority/1`
  line if "dropped first" is wrong for it. A row-menu item goes in
  `render_projects_table/3`'s `<.table_row_menu>`.
- **Extension columns.** An extension declaration may carry
  `project_columns: {module, fun}`; `fun.(project_uuids)` answers
  `[%{key, label, values: %{project_uuid => %{text, url | nil}}}]`.
  `Extensions.project_columns/2` calls each provider once per load, drops
  the values of projects the extension is off on (one read of the
  enablement rows), hides a sibling module's column from a viewer without
  that module's permission, and rescues a failing provider to nothing. The
  list offers each as column `ext:<ext_key>:<key>` — shown by default,
  sortable by its text, filterable by its distinct values. The CRM's Client
  is the first (`PhoenixKitCRM.ProjectColumns`).

**Two shapes of load.** The four database sorts (`position`, `name`,
`inserted_at`, `updated_at`) with no panel filter keep the old behaviour:
everything rendered at or below 100 projects, SQL search + load-more above.
Any other sort, or any panel filter, loads the whole visible set (searched
in SQL past the threshold), reads the families the sort and the filters
need, filters and sorts in memory and slices to the load-more cap. Fine at
tens to hundreds of projects; if a site ever holds thousands, the answer is
SQL aggregates per sort, not a bigger slice.

**State lives in the URL** through `UrlState` in `:history` mode (the list
is embeddable — no `handle_params/3`): `sort`, `dir`, `sortx` (which
extension column `sort=ext` means), `state`, `who` (`mine` or a user uuid),
`overdue`, `mode`, `archived` (`no`/`all`/`only`), `subs` (sub-projects
listed flat, each prefixed with its parent), `xcol` + `xval` (one extension
column's value). Open-ended values (`who`, `sortx`, `xcol`, `xval`) are
only ever compared against what was loaded — never turned into atoms or
queries. Drag-reorder stays on only for the manual sort with no search, no
filter, no archived view and no sub-projects, as before.

The viewer scope is applied in the database query before anything else, so
no sort, filter or listing switch can show a non-admin a project they do
not hold (`projects_list_columns_live_test.exs`, "scoping").
