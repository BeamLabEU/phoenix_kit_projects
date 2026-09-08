# AGENTS.md

Guidance for AI agents working on `phoenix_kit_projects`.

## Overview

A PhoenixKit plugin module for project and task management. It implements the
`PhoenixKit.Module` behaviour and provides a reusable task library, projects
that pull tasks in as assignments (with team/department/person assignees),
dependency chains within a project, sub-projects, workflow statuses, a
per-project extension hub (files, whiteboards, events, discussions, a public
portal), dashboard widgets and a public issue portal.

- **Depends on:** `phoenix_kit` `~> 2.0` (Hex; the real floor is documented in
  `mix.exs` next to the pin — a two-segment `~>` is deliberate so core minors
  stay compatible and `core_pin_conformance_test.exs` guards it),
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
  LiveViews have `actor_uuid` via `socket.assigns[:phoenix_kit_current_user]`
  and know the user's intent; contexts stay pure, returning
  `{:ok, record} | {:error, changeset}`. Every call is guarded with
  `Code.ensure_loaded?/1` + rescue — logging never crashes a mutation.
  Activity metadata captures the **primary** column value
  (`metadata.name = project.name`), not the localized one: audit trails are
  locale-agnostic.
  - In an embedded (`:not_mounted_at_router`) mount core's
    `:phoenix_kit_ensure_admin` `on_mount` never runs, so the actor comes from
    `WebHelpers.assign_embed_user/2` reconstructing it from
    `session["current_user_uuid"]`. Without that key embedded mutations log
    `actor_uuid: nil` by design; `Activity.actor_uuid/1` reads the assign with
    bracket access so a missing key is tolerated.
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
  `Attachments.download_urls/1`, `Grants.subject_reaches/1`. Ecto preloads are
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
  `tasks`/`templates`/`overview` too. The subtab uses a `{:regex, …}` matcher
  that excludes the literal siblings; keep it in sync when a sibling is added.
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
├── statuses.ex              # Workflow statuses (entities-backed, cement-at-start)
├── schedule_layout.ex, running_tiers.ex, assignees.ex
│                            # Durations→dates walk, tiering, effective-assignee resolution
├── calendar_display.ex, gantt_display.ex   # The two display-settings customizers
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
  `projects_templates_columns` — comma-joined visible-column sets per list page.
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
`phoenix_kit_projects`, currently **V16**. `mix phoenix_kit.update` applies it
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

| Feature | The constraint that must hold | Guide |
|---|---|---|
| Embedding via `live_render` | Every LV is embeddable and must stay so — an LV that exports `handle_params/3` cannot mount off-router. The host passes identity, the host authorizes. | [`dev_docs/guides/embedding.md`](dev_docs/guides/embedding.md), [`dev_docs/embedding_audit.md`](dev_docs/embedding_audit.md), [`dev_docs/embedding_emit.md`](dev_docs/embedding_emit.md) |
| The project page, list pages, breadcrumbs | Every tab target is validated against the feature map / contributed tab list — a forged `switch_tab` lands on the list, never on a gated tab. Timeline and Calendar render the SAME `ScheduleLayout` walk, so they can never disagree about a date. | [`dev_docs/guides/project-page.md`](dev_docs/guides/project-page.md) |
| Quick-add and the add-task sheet | The write is ONE transaction that locks the project row (`FOR UPDATE`) and does nothing else — broadcasts fire after commit, the activity log stays with the LiveView. The full form calls the same helper, so the two paths cannot drift. | [`dev_docs/guides/quick-add.md`](dev_docs/guides/quick-add.md) |
| Workflow statuses | Statuses cement at `started_at` and the source freezes with them: `save(:edit)` runs `Statuses.lock_status_source/2` server-side, so a crafted submit past the disabled control cannot change a started project's source. | [`dev_docs/guides/workflow-statuses.md`](dev_docs/guides/workflow-statuses.md) |
| Sub-projects | The child project is the source of truth; the parent's linking assignment carries denormalized rollup so every existing read site works unchanged. Exactly one of `task_uuid` / `child_project_uuid` (DB CHECK + changeset), at most one parent (partial unique index), `ON DELETE RESTRICT`. | [`dev_docs/guides/sub-projects.md`](dev_docs/guides/sub-projects.md) |
| Multilang user-input content | Non-translatable fields must be siblings OUTSIDE `<.multilang_fields_wrapper>` — the wrapper keys its id on `@current_lang`, so morphdom re-mounts everything inside on a tab switch and their state is lost. | [`dev_docs/guides/multilang-content.md`](dev_docs/guides/multilang-content.md) |
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
