# AGENTS.md

Guidance for AI agents working on the `phoenix_kit_projects` plugin module.

## Project overview

A PhoenixKit plugin module for project + task management. Implements `PhoenixKit.Module` behaviour. Registers one admin tab (`Projects`) with subtabs:

- **Overview** — active projects with progress bars, my tasks, upcoming/setup/completed projects, stats. Its Calendar tab has two modes: **Tasks (default)** — every leaf task across all projects on its scheduled days (identity-colored by project, per-day cap with a Google-style "+N more"; a day-cell or "+N more" click opens a whole-day popup via `PkDialogTrigger` + a kept-in-DOM modal; month + agenda views) — and **Projects** (the original one-bar-per-project view with the configurable overdue marker). Tasks mode carries an **assignee filter** — one Linear-style chip rail: a MULTI-person core `<.search_picker>` (search-on-focus browse, DB-limited pages with Load more, picked people excluded from suggestions) plus quick-adders for **Me** and **Unassigned** (a dashed chip with live count) that insert removable chips beside the input; every active filter is a visible chip, all filtering as one union, with a **Clear** button that renders only while filtering (resets chips + Unassigned + Overdue + Personal-only); the header is just a **Filters funnel button** (badged with the active count) + the mode toggle; every control lives in a client-side popup panel (JS.toggle open — patch-safe — with phx-click-away dismiss): picker, Me/Unassigned quick-adders, chips, Personal-only/Overdue-only, Clear; INHERITED semantics by default — the person plus their teams and departments via `PhoenixKitProjects.Assignees`, with a "Direct only" toggle and "via Team" provenance in the popup rows) and an **"Overdue only"** toggle (late = not done + scheduled span past — red inset ring on chips, `late` badge in popup rows). The raw walk is cached in assigns; filter flips are in-memory
- **Tasks** — library of reusable task templates (title, description, duration, default dependencies, default assignee)
- **Projects** — list of projects (filterable by status)
- **Templates** — reusable project templates cloned into real projects

Plus hidden subtabs for project/task/template/assignment new/edit/show pages.

## Common commands

Run from `/www/app`, not from inside this plugin subdir:

```bash
mix compile
mix format
sudo supervisorctl restart elixir
```

## Dependencies

- `phoenix_kit` (path dep) — Module behaviour, Settings, RepoHelper, Activity
- `phoenix_kit_staff` — **hard dep.** Assignment/Task schemas reference `PhoenixKitStaff.Schemas.{Team, Department, Person}` for the polymorphic assignee; staff tables must exist for our migrations (V101 depends on V100). Both must be declared in the parent app's `mix.exs` *and* in `extra_applications`
- `phoenix_live_view`, `ecto_sql`

## Local cross-repo development

`phoenix_kit` (and any sibling `phoenix_kit_*` dep) resolves from Hex by
default. To build or test this module against a **local checkout** of a
dependency — e.g. an unpublished core change — export `<APP>_PATH` and Mix
swaps the Hex pin for a `path:` + `override: true` dep at resolve time:

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix test     # this module against local core
PHOENIX_KIT_AI_PATH=../phoenix_kit_ai mix test
PHOENIX_KIT_STAFF_PATH=../phoenix_kit_staff mix test
PHOENIX_KIT_COMMENTS_PATH=../phoenix_kit_comments mix test
PHOENIX_KIT_ENTITIES_PATH=../phoenix_kit_entities mix test
```

The variable name is the dep's app name upper-cased with `_PATH` appended
(`:phoenix_kit` -> `PHOENIX_KIT_PATH`, `:phoenix_kit_ai` ->
`PHOENIX_KIT_AI_PATH`). Set several at once to override multiple deps. This
module's sibling overrides: `PHOENIX_KIT_AI_PATH`, `PHOENIX_KIT_STAFF_PATH`, `PHOENIX_KIT_COMMENTS_PATH`, `PHOENIX_KIT_ENTITIES_PATH`. **Unset = the
published pin**, so `mix hex.publish` and CI resolve exactly as before.
Implemented via `pk_dep/3` in `mix.exs` — never hand-edit a `phoenix_kit*`
dep into a `path:` tuple (a committed path dep ships a broken package); set
the env var instead.

## Architecture

### Concepts

- **Task** — a reusable template (title, description, estimated duration with unit, optional default assignee, optional default dependencies on other tasks)
- **Project** — a container for assignments. Has start mode (`immediate` or `scheduled`), optional `counts_weekends` flag, `is_template` flag (templates are cloned into real projects), and completion tracking (`completed_at`)
- **Assignment** — a task instance within a project. Copies description/duration from the template at creation, but is independently editable. Optionally assigned to a Department/Team/Person.
- **Dependency** — "assignment A must finish before B" link, scoped to the same project
- **TaskDependency** — default dependency between two task templates, auto-applied when both templates are in the same project

### Schemas

- `PhoenixKitProjects.Schemas.Task` — `phoenix_kit_project_tasks`
- `PhoenixKitProjects.Schemas.Project` — `phoenix_kit_projects`
- `PhoenixKitProjects.Schemas.Assignment` — `phoenix_kit_project_assignments`
- `PhoenixKitProjects.Schemas.Dependency` — `phoenix_kit_project_dependencies`
- `PhoenixKitProjects.Schemas.TaskDependency` — `phoenix_kit_project_task_dependencies`

All UUIDv7 PKs. Duration units: `minutes`, `hours`, `days`, `weeks`, `fortnights`, `months`, `years` (all defined on `Schemas.Task`, which also hosts `to_hours/3` with `counts_weekends` awareness).

### Context

`PhoenixKitProjects.Projects` — everything. Task library CRUD, template deps, project CRUD, templates, assignment CRUD, dependency management, schedule/progress computations (`project_summaries/1` batch query to avoid N+1 per project), completion auto-detection (`recompute_project_completion/1`), and template cloning (`create_project_from_template/2` uses `Ecto.Repo.transaction` for atomic cloning).

### LiveViews

Under `PhoenixKitProjects.Web.*`:
- `OverviewLive` — dashboard
- `TasksLive`, `TaskFormLive` — task library
- `ProjectsLive`, `ProjectFormLive`, `ProjectShowLive` — projects
- `ProjectGanttLive`, `ProjectCalendarLive` — the show page's Timeline / Calendar tabs (read-only alternate views, nested via `live_render`)
- `TemplatesLive`, `TemplateFormLive` — templates (reuses `ProjectShowLive` for view)
- `AssignmentFormLive` — add/edit task-in-project

`ProjectShowLive` is large (~900 lines) — handles the vertical timeline, status transitions, inline duration editing, per-task progress sliders, dependency badges, schedule/projected-end calculation. Sections are marked with `<%!-- ... --%>` HEEx comments for navigation.

**Show-page tabs (List / Timeline / Calendar):** both alternate views render
the SAME schedule through the shared `PhoenixKitProjects.ScheduleLayout`
(tree flatten + `PhoenixLiveGantt.Layout.sequential/2` walk, hour-precise,
weekday/weekend-aware), so they can never disagree about a task's dates. The
Timeline is `ProjectGanttLive` (`phoenix_live_gantt`); the Calendar is
`ProjectCalendarLive` (`phoenix_live_calendar` month grid, top-level
assignments as all-day status-colored bars capped per day with "+N more",
the same whole-day popup as the Overview, and the same Filters panel (shared
`Web.AssigneeFilter` glue + `<.assignee_filter_panel>`; sub-project bars match
DESCENDANT-aware — any subtree task belonging to the person keeps the bar); a sub-project is one bar spanning
its subtree, click drills into the child; dates deliberately UTC-unshifted to
match the Timeline, unlike the Overview calendar). Tabs are instant assign
flips; each nested LV lazy-mounts on first open and stays mounted. URL sync
(`/gantt` / `/calendar` suffix) is the `ProjectTabsUrl` host hook, opt-in via
`session["tab_url_sync"]` for embeds.

### URL paths

Under `/admin/projects/*`: `tasks`, `list` (projects), `templates`, plus `.../new`, `.../:id`, `.../:id/edit`, `.../:id/gantt`, `.../:id/calendar`, and assignment routes like `list/:project_id/assignments/new`. Use `PhoenixKitProjects.Paths`.

### Embedding LiveViews via `live_render`

**See also:** [`dev_docs/embedding_audit.md`](dev_docs/embedding_audit.md)
— the deep-dive audit of every LV in this module, why the blockers
exist, the per-LV fix shapes, the test convention, and the pre-flight
checklist for new LVs. Read it before adding a new LV.

**All 11 LVs are embeddable.** The regression gate is
`test/phoenix_kit_projects/web/embedding_test.exs` (navigate-mode
contract, including the `current_user_uuid` identity contract) plus
`embedding_emit_test.exs` (emit-mode contract — every LV that renders a
`<.smart_link emit>` needs a block there, or a missing
`attach_open_embed_hook/1` ships as a click-crash). Coverage, one
describe block per LV in each file:
`OverviewLive`, `ProjectsLive`, `TemplatesLive`, `TasksLive`,
`ProjectShowLive`, `ProjectGanttLive`, `ProjectCalendarLive`,
`ProjectFormLive`, `TaskFormLive`, `TemplateFormLive`, `AssignmentFormLive`.

The whitelist that gates **host-driven** insertion (PopupHost `root_view`,
`<.smart_link emit>`, emit `:opened`, `next` frames) is the single
`Web.Helpers.embeddable_lvs/0` list — an LV must be in it to be insertable
by another app, even if its `mount/3` already handles the off-router embed
contract. (The admin Timeline tab renders `ProjectGanttLive` via a direct
`live_render`, which never consulted the whitelist — which is why the Gantt
ran in our own UI yet stayed un-insertable until it was added to the list.)

> **Host responsibility — pass the viewer's identity.** Any user-aware
> behavior in an embed (the `ProjectShowLive` comments composer, and
> activity-log actor attribution on *every* mutating LV) needs the host to
> pass `session["current_user_uuid"]` — see the contract below. Without it
> the embed degrades to anonymous (the comments composer shows "Sign in to
> post a comment.", `Activity.actor_uuid/1` records `nil`) but never
> crashes. This is unavoidable: a `live_render` child is a separate
> `:not_mounted_at_router` process and can't see the host's `conn`,
> assigns, or the router's auth `on_mount` hook — it only gets the
> `session` map you hand it. Same mechanism as `session["locale"]`.
>
> ⚠️ **Identity ≠ authorization.** The `permission: "projects"` gate lives
> in core's `:phoenix_kit_ensure_admin` `on_mount`, which runs only for
> router-mounted admin pages — **never** for an off-router `live_render`
> mount. So embedded mutation handlers are NOT role-gated, and
> `current_user_uuid` reconstructs the viewer for audit + the comments
> composer only. **The host MUST gate the embedding page to
> projects-authorized users** (and source the uuid from its own trusted
> scope, never request params — the signed session stops client tampering,
> not unauthorized hosts).

Common shape for **read-only LVs** (Overview / Projects / Templates /
Tasks / ProjectShow / ProjectGantt):

```heex
{live_render(@socket, PhoenixKitProjects.Web.OverviewLive,
   id: "embedded-projects-overview",
   session: %{
     "wrapper_class" => "flex flex-col w-full px-4 py-6 gap-6",
     # Viewer identity — needed for the comments composer + activity actor.
     # Source from the host's own authenticated scope, never request params.
     "current_user_uuid" => @phoenix_kit_current_scope.user.uuid
   })}
```

`ProjectShowLive` additionally requires `session["id"]` (the project
UUID), reads `session["current_user_uuid"]` for the comments-drawer
composer, and renders the **List/Timeline/Calendar tab bar in embeds too**
(the Timeline/Calendar tabs are nested `live_render`s of `ProjectGanttLive`
/ `ProjectCalendarLive`); its URL-sync hook is opt-in via
`session["tab_url_sync"]` (off by default — see the contract bullet).
`ProjectGanttLive` (the read-only Timeline view) and `ProjectCalendarLive`
(the read-only month-calendar view) also require `session["id"]` and accept
`session["headless"]` (drops the back-link when nested as the show page's
tab). `TasksLive` accepts `session["view"]` (`"list"` or `"groups"`).

> ⚠️ **Embedded Timeline needs the gantt JS hooks in the host's
> LiveSocket.** When a host embeds `ProjectShowLive` and the user opens
> the Timeline tab, the nested `ProjectGanttLive` renders with
> `enable_hooks={true}`, expecting `window.PhoenixLiveGanttHooks`
> (`LgBarPopover` / `LgAutoScroll`). The chart itself is server-rendered
> SVG and shows without them, but the bar popover + scroll-to-today are
> inert until they're loaded. A PhoenixKit-core host gets them
> zero-config via this module's `js_sources/0` + core's
> `:phoenix_kit_js_sources` compiler (core ≥ 1.7.146; run
> `mix phoenix_kit.update`, recompile, rebuild assets). A non-PhoenixKit
> host must import `phoenix_live_gantt/priv/static/assets/phoenix_live_gantt.js`
> in its `app.js` and spread `window.PhoenixLiveGanttHooks` into its
> LiveSocket `hooks`.

Common shape for **form LVs** (ProjectForm / AssignmentForm /
TaskForm / TemplateForm):

```heex
{live_render(@socket, PhoenixKitProjects.Web.ProjectFormLive,
   id: "embedded-new-project",
   session: %{"live_action" => "new",
              "wrapper_class" => "flex flex-col w-full px-4 py-6 gap-4",
              "redirect_to" => "/host/orders/#{@order_id}",
              # So the form's activity log attributes to the real actor.
              "current_user_uuid" => @phoenix_kit_current_scope.user.uuid})}
```

Contract (all keys optional unless noted):

- `session["id"]` — required for `ProjectShowLive`, `ProjectGanttLive`,
  and for `:edit` actions on form LVs. String UUID.
- `session["project_id"]` — required for `AssignmentFormLive` (both
  `:new` and `:edit`).
- `session["live_action"]` — `"new"` or `"edit"` for form LVs.
  Defaults to `:new`. Resolved via `String.to_existing_atom/1` so
  unknown values fall back to the default.
- `session["template"]` — optional template UUID for
  `ProjectFormLive` `:new` (prefills the template picker).
- `session["view"]` — `"list"` or `"groups"` for `TasksLive`.
  Defaults to `"list"`.
- `session["wrapper_class"]` — overrides the outermost `<div>` class.
  Each LV defaults to its standalone-admin class
  (`mx-auto max-w-{xl,4xl,5xl,6xl} px-4 py-6 gap-{4,6}`); pass any
  host-friendly Tailwind class string.
- `session["locale"]` — optional locale code (e.g. `"ru"`, `"et"`).
  When set, both `PhoenixKitWeb.Gettext` and the process-global Gettext
  locale are restored inside the embedded LV's mount so translations
  render in the host's language. Backward-compatible — absent key is a
  no-op and the backend default (English) is used.
- `session["current_user_uuid"]` — **the viewing user's UUID** (string).
  Required for any user-aware behavior in an embed: the comments drawer's
  composer (else it shows "Sign in to post a comment.") and activity-log
  actor attribution (`Activity.actor_uuid/1` would otherwise record
  `nil`). An off-router `live_render` mount runs no `on_mount` hook, so
  `:phoenix_kit_current_scope` / `:phoenix_kit_current_user` are absent;
  `WebHelpers.assign_embed_user/2` reloads the user from this uuid and
  rebuilds the scope. The host MUST source it from its own trusted
  server-side assign (its `phoenix_kit_current_scope` → `scope.user.uuid`),
  **never** request params. Pass a string UUID, **not** the `%User{}`
  struct — a struct would serialize the password hash into the
  client-readable signed `live_render` session. Absent / unknown / inactive
  uuid degrades to an anonymous scope (composer disabled), never crashes.
  Backward-compatible. The reconstructed scope is a mount-time snapshot
  with no live refresh hook, so a mid-session permission change isn't
  reflected until remount. `PopupHostLive` forwards this key into every
  child session, so a host using it passes the uuid once.
- `session["redirect_to"]` — form LVs only. String path. When set,
  `push_navigate` on save / mount-error fires to this path instead of
  the admin default. Lets the host close a modal, refresh state, etc.
  without yanking the user to `/admin/projects/...`.
- `session["tab_url_sync"]` — `ProjectShowLive` only. Boolean,
  **defaults `false`** in embeds. The List/Timeline/Calendar tab bar
  renders in every embed (only templates stay list-only), but the
  `ProjectTabsUrl` hook that mirrors the active tab onto the browser URL
  (via `history.replaceState` — no history entries; back/forward return to
  the previous page, and per-tab entries are impossible without
  `handle_params/3`, which would block embedding) is **off by default** —
  an embed must not rewrite the host's address bar. Pass `true` (a real
  boolean, not `"true"`) only if the host mounts the show page as its own
  full-page route and wants `/gantt` / `/calendar` deep-linking. The
  router-mounted standalone admin page enables it implicitly.
- `id:` opt on `live_render` should be unique per logical embed (e.g.
  include the resource UUID) so two embeddings of the same LV on one
  page don't collide.

Behavior notes:

- `push_navigate` from within an embedded LV navigates the
  **top-level** browser session. Read-only LVs: rare paths (back-link,
  post-delete redirect). Form LVs: every save — that's why the
  `redirect_to` seam exists.
- All `phx-click` events, PubSub subscriptions, and the comments
  drawer (on `ProjectShowLive`) are scoped to the embedded socket;
  reactivity works the same as on the standalone page. The drawer's
  composer is enabled only when the viewer was supplied via
  `session["current_user_uuid"]` (reconstructed by
  `WebHelpers.assign_embed_user/2`); otherwise it renders the read-only
  thread + a "Sign in to post a comment." prompt.
- Two embeds of different resources can coexist on one host page;
  PubSub fan-out (`projects:all` etc.) is global so both will rerender
  on cross-resource events. Per-project topic
  (`projects:project:<uuid>`) is already scoped.

### Emit mode + popup host

**See:** [`dev_docs/embedding_emit.md`](dev_docs/embedding_emit.md)
for the full contract.

Above contract handles **layout** (where the embedded LV sits, how
session keys flow). The follow-up problem PR #6 deferred:
*navigation* inside an embedded LV still calls top-level
`push_navigate`, yanking the user out of the host page. Shipped fix
— two extra session keys turn every `push_navigate` site into a
PubSub broadcast on a host topic:

| Key | Default | Required when | Notes |
|---|---|---|---|
| `"mode"` | `"navigate"` | — | `"emit"` switches all nav sites to broadcast |
| `"pubsub_topic"` | `nil` | `mode == "emit"` | Host-supplied topic |
| `"frame_ref"` | `nil` | inherited from PopupHost | Race-safe pop identity |
| `"close_on"` | `["closed"]` | — | Subset of `["closed", "saved", "deleted"]` |

Event vocabulary (UI-intent verbs, disjoint from
`PhoenixKitProjects.PubSub`'s content-broadcast verbs so
`handle_info` clauses never collide):

```elixir
{:projects, :opened, %{lv, session, frame_ref}}
{:projects, :closed, %{frame_ref}}
{:projects, :saved, %{kind, action, record, close, next, frame_ref}}
{:projects, :deleted, %{kind, uuid, close, frame_ref}}
```

`record` on `:saved` is **`%{uuid: ...}` only**, never the full Ecto
struct — the payload rides a host-supplied PubSub topic that may be
relayed over the client-readable wire, and a preloaded record (e.g.
`assigned_person: [:user]`) would leak PII. `kind` conveys the type;
the host re-fetches by uuid if it needs the record.

`close: bool` — emitter-controlled "should the modal frame pop after
this event?" `navigate_after_save/3` defaults to `true` (form saves
are terminal). `notify_deleted_or_navigate/4` emits `true` (resource
is gone). `notify_deleted/3` emits `false` (list-LV row deleted; the
list stays open). `PopupHostLive` pops iff `close: true` AND
`frame_ref` matches the top frame.

`next: {lv, session} | nil` (on `:saved`) — optional follow-up LV.
When set, PopupHost pops the current frame and pushes a new frame for
`next` (e.g. "task created — open the edit screen so the user can add
dependencies", mirroring the navigate-mode `push_navigate(to:
edit_path)` flow).

For zero-config popup UX, host mounts
`PhoenixKitProjects.Web.PopupHostLive` once with an optional
`root_view` session key — it subscribes, manages a daisyUI `<dialog>`
modal stack, and renders requested LVs inside via `live_render`.

`PopupHostLive` also reads `session["current_user_uuid"]` (and
`session["locale"]`) from its own session and **forwards** them into
every child session it renders — root view and each stacked frame. So a
popup-host integration passes the viewer's uuid **once** to PopupHost
and the comments composer / activity actor work in every nested LV:

```heex
{Phoenix.Component.live_render(@socket, PhoenixKitProjects.Web.PopupHostLive,
   id: "projects-popup-host",
   session: %{
     "pubsub_topic" => "host:orders:#{@order_id}",
     "current_user_uuid" => @phoenix_kit_current_scope.user.uuid,
     "root_view" => %{"lv" => "Elixir.PhoenixKitProjects.Web.OverviewLive"}
   })}
```

## Database

Migrations live in `phoenix_kit` core as versioned `VNN`. Current migration: **V101** creates all project tables. When changing schema, add next `VNN`.

## Schedule math

- Durations normalized to hours via `Task.to_hours/3`. Weekdays-only mode uses 8h/day, 40h/week; calendar mode uses 24h/day, 168h/week
- Per-task `counts_weekends` overrides the project-level setting
- `calculate_schedule/2` in `ProjectShowLive` computes planned vs projected end dates:
  - **Planned** = `started_at + sum_of_task_hours` (fixed)
  - **Projected** = `now + remaining_hours / velocity` where velocity = done_hours / max(elapsed, 1h)
- Weekend work counts toward velocity even in weekdays-only projects (calendar_hours used when progress > plan)
- `progress_pct` on an assignment contributes proportionally to "done hours" only when `track_progress` is enabled

### Planned: per-task "count as work hours" toggle

A future change will add an opt-in per-task flag (working name
`count_as_work_hours`) that switches a task's planned-end math from
the current weekdays-only 8h/day / calendar 24h/day approximations
to the assignee's actual weekly work windows. The assignee side
ships in `phoenix_kit_staff` as a `Person.work_schedule` JSONB
column (see `phoenix_kit_staff/AGENTS.md` → "Planned:
`Person.work_schedule` (JSONB)" for the column shape and fallback
rules). The two PRs ship together; neither side has landed yet.

When the toggle is off, `Task.to_hours/3` keeps its current
behaviour. When it is on and the assignee has a non-empty
`work_schedule`, planned-end math walks that week's windows. When
it is on but the assignee's `work_schedule` is empty, math falls
back to the existing 5×8 approximation in `work_hours_elapsed/2` —
a Mon–Fri 09:00–17:00 windowed helper does not exist yet and is
part of this same follow-up work.

## Completion auto-detection

After every assignment status/progress/removal change, `Projects.recompute_project_completion/1` checks whether all assignments are `done` and sets `project.completed_at` accordingly. Reopening a task clears it. Logs `projects.project_completed` / `projects.project_reopened`.

## Activity logging

Every mutation logs via `PhoenixKitProjects.Activity`. Action strings: `projects.<resource>_<verb>`:

- `projects.project_created/updated/deleted/started/completed/reopened`
- `projects.template_created/updated/deleted`
- `projects.project_created_from_template`
- `projects.task_created/updated/deleted`
- `projects.task_dependency_added/removed`
- `projects.dependency_added/removed`
- `projects.assignment_created/updated/started/completed/reopened/removed`
- `projects.assignment_progress_updated`
- `projects.assignment_duration_changed`
- `projects.assignment_tracking_toggled`
- `projects.project_archived/unarchived`
- `projects.subproject_created/linked/detached`
- `projects.project_status_changed` — workflow current-status change (show page)
- `projects.gantt_display_changed/reset` — Timeline-chart display settings (settings page; `resource_type: "projects_settings"`)
- `projects.calendar_display_changed/reset` — Overview-calendar overdue-animation settings (settings page; `resource_type: "projects_settings"`)

The two `_changed` actions are **coalesced per field**: a slider drag emits a
debounced `phx-change` per step, but only ONE audit row — the settled value —
flushes after ~1s of quiet (`@display_log_flush_ms`; a reset supersedes any
still-queued change rows, and `terminate/2` best-effort-flushes on navigation).
Discrete controls (toggles, resets, selects outside the two display forms) log
immediately.
- `projects.status_entity_provisioned` — a default status list generated (per-project form OR global settings; `metadata.scope` = `"shared"` | `"global_default"`)
- `projects.default_status_entity_set` — global default status list chosen (settings page; `resource_type: "projects_settings"`)
- `projects.status_translations_toggled` — global translated-titles flag flipped (settings page)

Guarded with `Code.ensure_loaded?/1` + rescue — logging never crashes mutations.

**Where to log:** activity logging happens at the **LiveView layer**, not inside context functions in `PhoenixKitProjects.Projects`. LiveViews have `actor_uuid` via `socket.assigns[:phoenix_kit_current_user]` and know the user's intent; contexts stay pure, returning `{:ok, record} | {:error, changeset}`. The LiveView logs on success.

**Embedded mounts and the actor:** `socket.assigns[:phoenix_kit_current_user]` is set by core's `:phoenix_kit_ensure_admin` `on_mount` hook on the standalone admin page, but that hook does **not** run for a `live_render` (`:not_mounted_at_router`) mount. There, the assign comes from `WebHelpers.assign_embed_user/2`, which reconstructs the user from `session["current_user_uuid"]` (see the embedding contract above). If the host doesn't pass that key, embedded mutations log `actor_uuid: nil` — by design, not a crash. `Activity.actor_uuid/1` reads the assign with bracket access, so it tolerates the missing key.

**Sugar helpers don't log on their own:** `complete_assignment/2` and `reopen_assignment/1` are thin wrappers that delegate to the server-trusted `update_assignment_status/2`. They emit the same PubSub broadcast, but do **not** emit an activity log entry themselves. If a caller wants `projects.assignment_completed` or `projects.assignment_reopened` recorded, the caller must log it explicitly.

**Mass-assignment guard:** `Assignment.changeset/2` (used by `create_assignment/1` and `update_assignment_form/2`) does NOT cast `completed_by_uuid` or `completed_at` — those fields are server-owned and can only be set via `Assignment.status_changeset/2`, reached through `update_assignment_status/2`. This protects against form-based mass-assignment of completion metadata. The `_form` suffix on the public function is a deliberate smell: reaching for it from non-form code should trigger a second look.

## Permissions

`permission: "projects"` on all tabs. Mount guards; events trust the mount check.

## Settings keys

- `projects_enabled` — boolean, read by `PhoenixKitProjects.enabled?/0`, toggled via **Admin > Modules**. `enabled?` rescues all errors and returns `false` so missing settings tables don't crash module discovery.

## File layout

```
lib/phoenix_kit_projects.ex                  # Main module (PhoenixKit.Module behaviour)
lib/phoenix_kit_projects/
├── activity.ex                              # Activity logging wrapper
├── assignees.ex                             # Effective-assignee resolver (person∪teams∪departments scope, match provenance)
├── calendar_display.ex                      # Overview month-calendar mappers (Tasks mode task_events/4 + Projects mode events/6) + overdue-marker settings
├── gantt_display.ex                         # Timeline bar-label/display settings (read on /admin/settings/projects)
├── l10n.ex                                  # Date/time localization helpers
├── paths.ex                                 # Path helpers (/admin/projects/*)
├── projects.ex                              # Context: tasks, projects, assignments, deps
├── schedule_layout.ex                       # Shared durations→dates walk behind the Timeline + Calendar tabs
├── statuses.ex                              # Workflow statuses (entities-backed, cement-at-start)
├── pub_sub.ex                               # Topics + broadcast helpers
├── schemas/
│   ├── assignment.ex                        # Mass-assignment guard + single-assignee check
│   ├── dependency.ex                        # Per-project "A → B" link (self-reference rejected)
│   ├── project.ex
│   ├── project_status.ex                    # Cemented per-project workflow status row (V125)
│   ├── task.ex                              # Duration math (to_hours/3, format_duration/2)
│   └── task_dependency.ex                   # Template-level default deps
└── web/
    ├── assignment_form_live.ex
    ├── components.ex                         # `use` aggregator — imports every web/components/*.ex
    ├── components/
    │   ├── assignee_filter_panel.ex         # `<.assignee_filter_panel>` — the Filters funnel + popup (chips/picker/toggles)
    │   ├── day_popup_modal.ex               # `<.day_popup_modal>` — the whole-day popup both calendars share
    │   ├── derived_status_badge.ex          # `<.derived_status_badge>` + `<.project_status_badge>`
    │   ├── empty_state.ex                   # `<.empty_state>` — icon + heading + sub + CTA slot
    │   ├── page_header.ex                   # `<.page_header>` — title + description + actions + back_link slots
    │   ├── running_card.ex                  # `<.running_card>` — dashboard project summary tile
    │   ├── sortable_table.ex                # `<.sortable_table>` — drag-to-reorder table with `:col` slots
    │   ├── stat_tile.ex                     # `<.stat_tile>` — compact "label + big number" card
    │   ├── tabs_strip.ex                    # `<.tabs_strip>` — daisyUI tabs-boxed switcher
    │   └── tier_pill.ex                     # `<.tier_pill>` — Running-tier status pill
    ├── overview_live.ex
    ├── project_calendar_live.ex             # Calendar tab — month grid over the ScheduleLayout walk
    ├── project_form_live.ex
    ├── project_gantt_live.ex                # Timeline tab — gantt over the ScheduleLayout walk
    ├── project_show_live.ex                 # Large (~1700 lines) — timeline, schedule math
    ├── projects_live.ex
    ├── task_form_live.ex
    ├── tasks_live.ex
    ├── template_form_live.ex
    └── templates_live.ex
```

## Web components

LVs `use PhoenixKitProjects.Web.Components` to pull in every reusable
component in one line. Components live in `web/components/*.ex` as
individual Phoenix.Component modules. The aggregator in
`web/components.ex` only `import`s them — it doesn't define functions
of its own, so adding a new component is `add file → add import` and
done.

Components are deliberately scoped to this module's surface (not
core's `PhoenixKitWeb.Components.*` namespace). Promoting one to core
is mechanical when a sibling module needs it: copy the file, rename
the module to `PhoenixKitWeb.Components.<Name>`, drop the import here,
let the consumer fall through to the core function.

**What's already a core component (use the core one, don't duplicate):**
`<.input>`, `<.select>`, `<.textarea>`, `<.checkbox>`, `<.icon>`,
`<.multilang_tabs>`, `<.translatable_field>`, `<.stat_card>` (note:
core's takes title + subtitle + icon — for a minimal "label + value"
tile use this module's `<.stat_tile>`).

**List-LV toolkit (in core):** `<.table_default>` + `<.sortable_tbody>`
+ `<.sortable_row>` + `<.drag_handle_cell>` + `<.drag_handle_header_cell>`
+ `<.bulk_select_scope>` + `<.bulk_select_header_cell>` + `<.bulk_select_cell>`
+ `<.bulk_actions_toolbar>` + `<.sort_selector>` + `<.reorder_modal>`
+ `<.load_more>`. See `phoenix_kit/AGENTS.md` → "Core List-UI Components"
for the full toolkit doc. `ProjectsLive`, `TasksLive`, `TemplatesLive`
are the canonical consumer examples — never re-roll a list LV without
checking that file pair first.

**Reorder strategy whitelist (load-bearing):** consumer LVs MUST use a
hardcoded `%{"name_asc" => :name_asc, …}` map for `apply_reorder`'s
strategy string→atom, never `String.to_existing_atom/1` on the param.
A crafted payload otherwise either raises or leaks the BEAM atom slot.

**`captured_uuids` collapse rule:** `open_reorder_modal` collapses
0–1-element selection lists to `:all` (single-row "reorder" is a no-op,
and the toolbar label reads "Reorder all" in those states). Apply the
same rule in any new bulk-action handler.

## Dashboard widgets (contributed to `phoenix_kit_dashboards`)

Projects contributes seven widgets to the dashboards module via the duck-typed
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
tasks — detailed/compact). Every view declares its own `min_size` (the improved
dashboards widget API), and the shared frame renders **compact** at a single
row so minimum boxes fit without scrollbars.

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

## Versioning & Releases

Versioning follows [SemVer](https://semver.org/). The version appears in two places that must stay in sync:

1. `mix.exs` — the `@version` module attribute
2. `lib/phoenix_kit_projects.ex` — `def version, do: "x.y.z"` (returned by the `PhoenixKit.Module` callback)

Release checklist:

1. Bump both versions; add a `CHANGELOG.md` entry. Date the header in the
   workspace-standard format `## x.y.z - YYYY-MM-DD` (matches core
   `phoenix_kit`, `phoenix_kit_publishing`, `phoenix_kit_document_creator`).
2. Run `mix precommit` — must exit clean
3. Commit ("Bump version to x.y.z") and push
4. Tag with the bare version: `git tag x.y.z && git push origin x.y.z`
5. Create a GitHub release via `gh release create`

## Conventions

- **Paths**: `PhoenixKitProjects.Paths.*` only
- **Activity**: via `PhoenixKitProjects.Activity` wrapper, always at the LiveView layer
- **Duration units + conversion**: centralized in `Schemas.Task`
- **Cross-module staff lookups**: direct calls to `PhoenixKitStaff.*` are fine — it's a declared hard dep. Wrap DB-backed lookups in a `rescue [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError]` that logs and returns an empty list so a staff DB outage never takes the projects UI down with it
- **Gettext (hybrid, two backends)**:
  - **Module-domain strings** (project / task / template / assignment /
    dependency UI — the bulk) live in `PhoenixKitProjects.Gettext` with
    `.po` files in `priv/gettext/`. Files declare
    `use Gettext, backend: PhoenixKitProjects.Gettext` and call
    `gettext(...)` / `ngettext(...)` normally. Refresh with
    `mix gettext.extract && mix gettext.merge priv/gettext --no-fuzzy`
    from this repo.
  - **Common/generic strings** (date/month formatting in
    `PhoenixKitProjects.L10n`, generic table chrome in
    `Web.Components.SortableTable`) stay on core's
    `PhoenixKitWeb.Gettext` backend. Their msgids ship in
    `phoenix_kit/lib/phoenix_kit_web/projects_gettext_manifest.ex`
    (extraction target — never called at runtime). Mirrors the
    `legal_gettext_manifest.ex` pattern.
  - Both backends share the same locale via `Gettext.put_locale/1`
    (process-global), so the `/ru/...` URL prefix translates both
    surfaces simultaneously.
  - See `dev_docs/i18n_triage.md` for the per-file bucket assignments.
- **LiveView layout**: `use PhoenixKitWeb, :live_view` (in `phoenix_kit_web.ex`) injects `layout: PhoenixKit.LayoutConfig.get_layout()` automatically. No need to wrap templates in `<PhoenixKitWeb.Components.LayoutWrapper.app_layout>` — that wrapper is for LiveViews served outside the admin live_session

## Pre-commit commands

Always run before git commit (mirrors the root `phoenix_kit` workflow):

```bash
# 1. Run the full pre-commit chain
mix precommit               # compile + format + credo --strict + dialyzer

# 2. Fix any problems surfaced above (warnings-as-errors in compile, format diffs, credo issues, dialyzer specs)

# 3. Review changes
git diff
git status

# 4. Commit
```

Step order matters: `compile` first (warnings-as-errors catches the loud stuff), then `format`, then `credo --strict`, then `dialyzer`. Run from `/www/app` so deps resolve against the workspace; `mix format` is the only one that works from inside the plugin subdir.

## Testing

Three levels:

- **Unit tests** in `test/phoenix_kit_projects/` — schemas,
  changesets, pure helpers (duration math, etc.), the `Errors` atom
  dispatcher. Always run.
- **Integration tests** in `test/phoenix_kit_projects/integration/`
  — hit a real PostgreSQL database via the Ecto sandbox. Use
  `PhoenixKitProjects.DataCase`.
- **LiveView smoke tests** in `test/phoenix_kit_projects/web/` —
  drive LVs via `Phoenix.LiveViewTest.live/2` against the test
  Endpoint + Router. Use `PhoenixKitProjects.LiveCase`.

Test infrastructure:

- `test/support/test_repo.ex` — `PhoenixKitProjects.Test.Repo`
- `test/support/test_endpoint.ex` — minimal `Phoenix.Endpoint` for
  LV tests; `server: false`, no port opened
- `test/support/test_router.ex` — minimal Router whose paths match
  `PhoenixKitProjects.Paths.*` (base scope `/en/admin/projects`)
- `test/support/test_layouts.ex` — root + app layouts; `app/1`
  renders flash divs (`#flash-info`, `#flash-error`,
  `#flash-warning`) so smoke tests can assert flash content via
  `render(view) =~ "Saved."` after click events
- `test/support/hooks.ex` — `:assign_scope` `on_mount` hook that
  reads `"phoenix_kit_test_scope"` from session and assigns
  `phoenix_kit_current_scope` + `phoenix_kit_current_user`
- `test/support/data_case.ex` — `PhoenixKitProjects.DataCase`, tags
  tests `:integration`, sets up the SQL Sandbox; hosts shared
  `fixture_task/1`, `fixture_project/1`, `fixture_template/1` and
  `errors_on/1`
- `test/support/live_case.ex` — `PhoenixKitProjects.LiveCase` with
  `fake_scope/1` + `put_test_scope/2` for plugging a real
  `%PhoenixKit.Users.Auth.Scope{}` into the test session; reuses
  fixtures from `DataCase`
- `test/support/activity_log_assertions.ex` —
  `assert_activity_logged/2` and `refute_activity_logged/2`
- `test/test_helper.exs` — starts `PhoenixKit.PubSub.Manager`,
  Hammer's `RateLimiter.Backend`, pins the URL prefix, starts
  `PhoenixKitProjects.Test.Endpoint`, and runs core's versioned
  migrations via `PhoenixKit.Migration.ensure_current/2` (V40
  extensions + uuid_generate_v7, V03 settings, V90 activities,
  V100 staff tables, V101 projects tables, V105 partial-index
  conversion) — no module-owned DDL anywhere
- `config/test.exs` — repo + Test.Endpoint config

Commands:

```bash
# First time only:
createdb phoenix_kit_projects_test

# All runs (unit + integration if DB is reachable):
mix test

# Unit tests only (DB not required):
mix test --exclude integration
```

The test helper runs core's versioned migrations via
`PhoenixKit.Migration.ensure_current/2` on every boot, so the schema
re-applies any newly-shipped Vxxx migrations automatically. No
`mix test.setup` step needed past the initial `createdb`.

Integration tests are auto-excluded if the DB isn't reachable. `mix
test` never hard-fails on a missing DB.

## CI expectations

GitHub Actions run on push and PRs: formatting check, `credo --strict`, `dialyzer`, compile with warnings-as-errors, and `mix test`. A failure in any of these blocks merge.

## Pull requests

### PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` with `{AGENT}_REVIEW.md` naming (e.g., `CLAUDE_REVIEW.md`). See the root `phoenix_kit/AGENTS.md` section on PR reviews for the authoritative directory layout.

Severity levels for review findings:

- `BUG - CRITICAL` — Will cause crashes, data loss, or security issues
- `BUG - HIGH` — Incorrect behavior that affects users
- `BUG - MEDIUM` — Edge cases, minor incorrect behavior
- `IMPROVEMENT - HIGH` — Significant code quality or performance issue
- `IMPROVEMENT - MEDIUM` — Better patterns or maintainability
- `NITPICK` — Style, naming, minor suggestions

## Commit message rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`.

## Soft-hide / archive

Archive is a **timestamp**, not a status enum. `projects.archived_at`
(added in core V112) follows the workspace's `trashed_at` convention
used by publishing posts and core files: null = visible, non-null =
hidden + audit-friendly "archived at."

Public API: `Projects.archive_project/1` and `Projects.unarchive_project/1`.
The dashboard buckets and `list_projects/1` filter on
`is_nil(archived_at)`. `Projects.list_projects/1` accepts `:archived`
opt — `false` (default, visible only), `true` (archived only), `:all`.

The derived state from `Project.derived_status/2` returns `:archived`
as the highest-priority bucket, so an archived project is always
labeled "archived" in the UI regardless of its other timestamps.

### Legacy `status` column — kept, unused

The pre-V112 `status` string column (`"active"` / `"archived"`) is
**still in the table** but no longer cast by the changeset, never read
by application code, and no longer surfaced in any UI. V112 backfilled
`archived_at = updated_at` for any row that was `status = 'archived'`
at migration time, so the soft-hide state survived the move.

The column is preserved deliberately so a future workflow concept that
legitimately wants a string lifecycle state (e.g. `"paused"`,
`"blocked"`, `"on_hold"`) can reuse the slot without another migration.
Anyone wiring such a feature must:

1. Re-introduce `status` to `Project.@optional` and `Project.changeset/2`.
2. Add a fresh `validate_inclusion(:status, …)` for the new vocabulary.
3. Update `Project.derived_status/2` priority order if the new state
   should outrank the existing buckets.
4. Decide whether to backfill existing `"active"`/`"archived"` rows.

If after a reasonable interval no such feature lands, drop the column
in a future Vxxx.

## Workflow statuses (entities-backed, cement-at-start)

A user-defined **workflow status** (Backlog → In Progress → Blocked →
Done, etc.), orthogonal to the computed `Project.derived_status/2` and the
`archived_at` soft-hide.

**Available on every project-like record.** Since a sub-project and a template
are both projects, they get the same status-source picker. The form section
(Custom Status select + "Generate default" + status preview + "Translated
status titles") lives in the shared `Web.Components.WorkflowStatusFields`
component, with its logic (`available?/0`, `entity_options/0`, `preview_for/1`,
`mode_string/1`, `apply_mode/3`, `selected_entity_uuid/1`) reused by
`ProjectFormLive` (inline), `TemplateFormLive`, and `AssignmentFormLive`'s
sub-project mode. Each LV owns its `generate_default_statuses` handler (it knows
which form to update). The current-status value picker on `ProjectShowLive`
isn't gated on `is_template`, so templates + opened sub-projects show it too; a
template's chosen list + current status flow to cloned projects via
`inherit_status_slug_in_tx/2`.
 The vocabulary is configured through the
**optional** `phoenix_kit_entities` module and **cemented locally** when a
project starts. Lives in `PhoenixKitProjects.Statuses` (mirrors
`Translations`' optional-dep scaffolding) + `Schemas.ProjectStatus`.

### Two layers
- **Catalog (entities).** Status lists are entities. The admin **generates**
  a default list (`Statuses.create_default_status_entity/0`) — named
  `project_statuses`, auto-incrementing to `project_statuses_2`, `_3`, … so
  generating again always makes a fresh list (e.g. after editing the last
  one) rather than reusing it — seeded with the default vocabulary. One is
  designated the **global default** via the Settings page (see below).
  Per-project custom entities the user owns are named
  `project_status_<32-hex-uuid>`; all are tagged
  `settings["source"] = "phoenix_kit_projects"`. Templates and
  not-yet-started projects read the chosen catalog **live**.
- **Cemented (local).** `start_project/2` snapshots the chosen catalog
  into `phoenix_kit_project_statuses` rows (in the same transaction). The
  running project then uses its own frozen, independently-editable copy —
  later catalog edits don't touch it. Same template→instance philosophy
  as Assignment-copies-Task.

  "Frozen" means it **stops following the live catalog**, NOT read-only.
  The cemented rows remain editable through the context as a deliberate
  escape hatch (there is no UI for it): `Statuses.add_project_status/2`,
  `update_project_status_row/2`, `remove_project_status/2`,
  `get_project_status/2`. So a started project's statuses can still be
  changed via the API "in case it's really wanted" — pinned by the
  "local CRUD post-start" test in `statuses_test.exs`.

`started_at` is the cement boundary (`derived_status` → `:running` iff
`started_at`). The selected status is `current_status_slug` on the
project — a stable identity that resolves against the live catalog
pre-start and the local rows post-start. It is **server-owned**: written
only via `Statuses.set_current_status/3` →
`Projects.set_current_status_slug/2` (the dedicated
`Project.current_status_changeset/2`), never the form changeset.
`status_entity_uuid` (which catalog list; nil = shared) is form-castable
**only before start** — see the source lock below.

### Choosing / changing the status source (incl. existing projects)
Any entity can serve as a status source — each of its data **records** is a
status, the record's built-in **`title`** is the label, and an optional
**`color`** field on records drives the badge colour. No marker field is
required. `Statuses.list_status_source_entities/0` returns entities grouped
for a picker (`[{"Status lists", …}, {"Other entities", …}]`, the
`settings["source"] = "phoenix_kit_projects"` catalogs first).

**Where the source is chosen.** The status-source picker lives ONLY on the
new/edit project forms (`ProjectFormLive`) — NOT on `ProjectShowLive`. The
show page only displays the current-status value picker, and only once the
project's list has statuses; it has no source selector. The picker is the
shared `<.workflow_status_fields>` component (form-bound to
`status_entity_uuid`, "Use global default" prompt + grouped) with a
**"Generate default"** button beside it and a live **preview** of the
selected list's statuses — the **same component** projects, templates and
sub-projects (`AssignmentFormLive`) all render, so the section never diverges.

**The source is a pre-start choice — frozen after start.** Since statuses
cement at `started_at`, a started project's source can no longer change. The
component takes `locked={Statuses.started?(project)}`: once started the
`<.select>` is `disabled`, the "Generate default" button is hidden, and a
"Frozen at start" hint shows. The lock is keyed on `started?` (NOT on whether
a custom entity is selected), so a started project on the **global default**
(nil `status_entity_uuid`) locks too. Server-side mate: every `save(:edit)`
runs `attrs = Statuses.lock_status_source(attrs, project)`, which strips
`status_entity_uuid` for started projects — so even a crafted submit past the
disabled control can't change the frozen source. (`set_status_entity/3` +
`recement_project_statuses/1` remain as a programmatic "cement on select" API,
exercised only by `statuses_test.exs`; no UI reaches them.)

**The "Shared default" is admin-chosen, not auto-created.** A project with no
`status_entity_uuid` resolves to the global default entity stored in the
`projects_default_status_entity_uuid` setting (picked on the projects Settings
page — `/admin/settings/projects` — or generated there). Nothing is
auto-provisioned on read; if no default is set, the project has no statuses.
`Statuses.global_default_status_entity_uuid/0` / `set_default_status_entity/1`
read/write the setting; `resolve_catalog_entity_uuid/1` uses it.

**Statuses are title-only for colour** (none seeded; badges render neutral), but
the cemented row uses JSONB (V125): `phoenix_kit_project_statuses` has
`label`(primary)/`slug`/`position` + `data` JSONB (`{"color"}` + future per-status
attrs) + `translations` JSONB (label i18n, workspace shape).
`ProjectStatus.color/1` reads `data["color"]`. (V125 was edited in place for the
JSONB shape — it's unreleased.)

**Titles are localized.** Reads resolve the label to the current content locale
(`L10n.current_content_lang/0`, the process Gettext locale the host sets from the
URL prefix) — no LV signature changes. Catalog reads pass `lang:` to
`EntityData.list_by_entity/2` so the entities module resolves each record's title;
`cement_project_statuses/2` captures the **primary** title as `label` plus every
enabled non-primary language's title into the row's `translations` JSONB (via
per-language catalog reads + `Languages.enabled_languages/0`), and
`ProjectStatus.localized_label/2` resolves cemented rows on read — so a started
project stays localized independent of the catalog.

**Display toggle (global + per-project override).** Translations are always
captured; *displaying* them is gated. `Statuses.use_status_translations?/1`
resolves: per-project override → global setting → `true`. The global default is
the `projects_use_status_translations` setting
(`Settings.get_boolean_setting(_, true)`). The per-project override is a tri-state
in the project's `settings` JSONB (`use_status_translations` = true/false/absent;
absent = inherit global) — `Project.status_translation_override/1` reads it (the
schema stays pure; resolution-with-global lives in `Statuses`). The project form
exposes a 3-way "Translated status titles" control (Default / Show translated /
Show original) that folds into `settings`. The **global** toggle lives in the core Settings area
(`/admin/settings/projects`, a global-settings tab via `settings_tabs/0` →
`Web.ProjectsSettingsLive`, alongside Comments/Posts/Entities), which writes the
global default — currently set via
`PhoenixKit.Settings` (default `true`).

### Optional dependency
`{:phoenix_kit_entities, "~> 0.1", optional: true}` — loadable in this
package's own test build, kept out of host closures. Every `Statuses`
function degrades gracefully when entities is absent/disabled
(`available?/0` gates everything; reads → `[]`/`nil`, provisioning →
`{:error, :entities_not_available}`, cement → no-op). UI surfaces guard
on a `:statuses_available` assign and hide cleanly.

### Schema (core V125)
- `phoenix_kit_projects.status_entity_uuid` — FK
  `phoenix_kit_entities(uuid) ON DELETE SET NULL`.
- `phoenix_kit_projects.current_status_slug` — varchar.
- `phoenix_kit_project_statuses` — the cemented copy (`project_uuid` FK
  cascade, `label`/`slug`/`position` + `data` JSONB (per-status attrs e.g.
  `{"color"}`) + `translations` JSONB (label i18n), provenance
  `source_entity_data_uuid` with no FK). Unique `(project_uuid, slug)`.

### Host wiring — "Used by N projects" count
Projects is a library and can't self-register OTP config. To power the
entities admin's reverse-reference hint, the host app adds:
```elixir
config :phoenix_kit_entities,
  reverse_references: [{"project_status", &PhoenixKitProjects.Statuses.reverse_reference_count/1}]
```
Informational only (never a delete-blocker). Counts projects/templates
currently *sourcing* from a catalog entity — started projects no longer
reference it (cemented), which is the intended semantics.

### ⚠️ Cross-repo release ordering
V125 ships in **core `phoenix_kit`**. This module pins `phoenix_kit
~> 1.7.121`; the feature can't run until core releases V125 (≥1.7.122)
and this pin is bumped. **Projects CI stays red until then** — same as
catalogue #28 / core #570. The status test suite + the new columns
require V125 in the projects build; develop/test locally via a temporary
`{:phoenix_kit, path: "../phoenix_kit", override: true}` until the release.

## Sub-projects (project-as-task, core V127)

A **sub-project** is a project embedded inside another project's task
timeline. The model is an `Assignment` that points at a child `Project`
via a new nullable `child_project_uuid` (V127) **instead of** a task
template — so a sub-project gets dependencies and drag-reorder *for free*
(both are already assignment-level and project-scoped, no changes there).

### Data model
- `phoenix_kit_project_assignments.child_project_uuid` → FK
  `phoenix_kit_projects(uuid) ON DELETE RESTRICT` (V127). `task_uuid` lost
  its `NOT NULL`; a DB `CHECK ((task_uuid IS NOT NULL) <> (child_project_uuid
  IS NOT NULL))` enforces **exactly one** of task/child-project (mirrored by
  `Assignment.validate_task_xor_child/1`). A partial **unique** index on
  `child_project_uuid` makes a project the child of **at most one** parent.
- `RESTRICT` (not `CASCADE`) is deliberate: a stray child-project delete
  fails loudly instead of silently mutating a parent's task list. Recursive
  teardown is orchestrated in the context (in a transaction), not by the DB.

### Source of truth + rollup (denormalized, NOT computed-on-read)
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

### Context API
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

### Templates
Sub-projects work on templates too: `create_subproject/2` makes the child
inherit the parent's `is_template` flag, so a sub-project added to a template is
itself a **sub-template**. `create_project_from_template/2` **deep-clones** the
whole sub-project subtree — `clone_subproject_assignment_in_tx/2` →
`deep_clone_project_in_tx/2` recursively copies each child template into a fresh
real project and re-links it (the single-parent unique index forbids two parents
sharing a child, so the deep copy is mandatory, not optional). Sub-templates are
hidden from `list_templates/0` / `count_templates/0` via `exclude_subprojects/1`,
same as sub-projects are hidden from the projects list.

### Dashboard (hierarchical, `OverviewLive` + `RunningCard`)
`Projects.project_tree_summary/1` returns a recursive node (per-level task
breakdown + nested children); the Running card renders it as an indented
outline — top summary (`N tasks · M sub-projects`) + status breakdown
(`X done · Y in progress · Z todo`) + each sub-project nested with its own
summary/breakdown, all the way down. **Empty sub-projects are neutral in the
progress average** (excluded from both `project_summaries/1`'s `progress_pct`
and the tree node's) so they don't drag a parent's % down before they have
tasks. The top node still carries `total` / `progress_pct` / `planned_end`, so
the tier + sort helpers read it like the old flat summary.

### UI (`ProjectShowLive`)
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
  `<.tabs_strip event="set_sp_mode">` ("Create new" / "Nest existing"). "Nest
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
  climbs. There's an "Open sub-project" link to the child's full page. Dependencies render and can be added/removed
  on the row (`add_subproject_dep` reuses `available_dependencies` +
  `add_dependency`). Drag-reorder works unchanged (the row is a `sortable-item`).
- Activity: `projects.subproject_created` / the existing
  `projects.assignment_removed` on teardown.

### Assignee on projects + sub-projects (core V128)
A project carries the same polymorphic assignee as a task — `assigned_team_uuid`
/ `assigned_department_uuid` / `assigned_person_uuid` on `phoenix_kit_projects`
(V128), one-of via a `num_nonnulls(...) <= 1` CHECK + `Project.validate_single_assignee/1`.
Because a sub-project IS a project, this one set of columns covers assigning a
sub-project too (its assignee lives on the child project row). `ProjectFormLive`
gains the team/department/person picker (mirrors `AssignmentFormLive` —
`assign_type` + `clear_other_assignees/2`); the **Add sub-project** modal carries
the same picker so you can assign at creation (`subproject_assignee_attrs/1` →
`create_subproject/2`). Display reuses the show LV's `assignee_type/1` +
`assignee_label/1` (they already work on any record with the assignee fields) on
the project header and each sub-project row; `get_project_with_assignee/1` +
the deep child preload in `@assignment_preloads` load the names.

### Linking guards (cycle-safe)
`link_subproject/2` is the "nest an existing project" path the inline-creation
flow originally deferred. It validates before assigning `child_project_uuid`:
`:self_link` (parent == child), `:kind_mismatch` (`is_template` differ),
`:would_create_cycle` (`child.uuid in project_ancestor_uuids(parent.uuid)` —
`walk_ancestors/2` climbs linking rows), and `:already_subproject` (the partial
unique index on `child_project_uuid`, caught at insert and mapped). The
depth-capped propagation still fails closed on corrupt data as a backstop.

### Cross-repo schema dependency
V127 (`child_project_uuid` on `phoenix_kit_project_assignments`) **and V128**
(assignee columns on `phoenix_kit_projects`) live in **core `phoenix_kit`**
(`@current_version` 128). Both shipped in `1.7.128`, which this module now pins
as its floor (`~> 1.7.128`), so the sub-project features run against any released
core. When iterating on the schema ahead of a core release, develop/test locally
via a temporary `{:phoenix_kit, path: "../phoenix_kit", override: true}`. Tests:
`test/phoenix_kit_projects/integration/subprojects_test.exs` (context) +
`test/phoenix_kit_projects/web/project_show_subprojects_test.exs` (LV render).

## Multilang user-input content

User-typed content (project name + description, task title +
description, assignment description) is translatable per language,
on top of the standard gettext-based UI translation. Driven by core's
**Languages module** — when 2+ languages are enabled there, the forms
auto-render `<.multilang_tabs>` and `<.translatable_field>`s from
`PhoenixKitWeb.Components.MultilangForm`; when disabled or only one
language, the forms degrade to the regular single-language layout
(no tabs, no skeletons).

### Storage shape (V112)

Each of the three project tables grew a `translations JSONB NOT NULL
DEFAULT '{}'::jsonb` column:

  * `phoenix_kit_projects.translations`            — `name`, `description`
  * `phoenix_kit_project_tasks.translations`       — `title`, `description`
  * `phoenix_kit_project_assignments.translations` — `description`

Primary-language values stay in their dedicated columns (`name`,
`title`, `description`); the JSONB only holds non-primary overrides:

```json
{
  "es-ES": {"name": "Proyecto", "description": "..."},
  "fr-FR": {"name": "Projet"}
}
```

This is the **"settings translations"** variant of
`<.translatable_field>` (per the component's docstring) — different
from the entity-data variant where everything goes inside a `data`
JSONB with a `_primary_language` marker. Projects has no per-record
custom fields, so the simpler primary-stays-in-columns shape applies.

### Read paths

Each schema exposes `localized_<field>/2` helpers with primary-fallback
semantics — `nil`/empty override → the primary column. Pass the
current locale (or `nil`):

```elixir
Project.localized_name(project, lang)
Project.localized_description(project, lang)
Task.localized_title(task, lang)
Task.localized_description(task, lang)
Assignment.localized_description(assignment, lang)
```

The current-content language for read paths comes from
`PhoenixKitProjects.L10n.current_content_lang/0`, which reads
`Gettext.get_locale(PhoenixKitWeb.Gettext)` — the locale the parent
app set from the URL prefix (`/bs/...` → `"bs"`). Activity-log
metadata always captures the **primary** column value
(`metadata.name = project.name`), not the localized one — audit
trails are locale-agnostic by design.

### Form mechanics

LVs that need multilang inputs:

1. `import PhoenixKitWeb.Components.MultilangForm`
2. Call `mount_multilang(socket)` in `mount/3` — adds
   `:multilang_enabled`, `:primary_language`, `:current_lang`,
   `:language_tabs`, `:show_multilang_tabs` and attaches the
   debounce hook. If the Languages module is off, all of these are
   defaults — the components no-op and inputs render as plain
   primary-language fields.
3. `handle_event("switch_language", %{"lang" => code}, socket)` →
   `handle_switch_language(socket, code)`. The component's 150 ms
   debounce handles rapid click-through.
4. In `validate` and `save`: pass the form params through
   `PhoenixKitProjects.Web.Helpers.merge_translations_attrs(attrs,
   in_flight_record, schema_module.translatable_fields())` before
   building the changeset. This:
     * strips Phoenix LV's `_unused_*` sentinel keys from the
       submitted `translations` map;
     * drops empty/`nil` overrides so cleared secondary fields
       fall back cleanly to the primary value;
     * deep-merges on top of the record's existing JSONB so other
       languages aren't clobbered;
     * preserves primary-language column values when a secondary-tab
       submission lacks them (the primary `<input>`s aren't in the
       DOM on secondary tabs, so a naive cast would treat them as
       nil and trigger `validate_required` failures).
5. `in_flight_record/3` uses `Ecto.Changeset.apply_changes/1` on the
   form's source so the user's already-typed primary values from
   prior `validate` events become the merge baseline. Needed for
   the "type EN-US, switch to BS, save" flow on `:new` records where
   `socket.assigns[:project]` is the pristine `%Project{}`.

### Form layout rule (load-bearing)

Translatable fields (`name`, `title`, `description`) go inside
`<.multilang_fields_wrapper>`. Non-translatable fields (start mode,
scheduled date, weekends, durations, assignee picker, status, deps)
must be **siblings outside the wrapper** — otherwise their state is
lost on every language switch (the wrapper keys its id on
`@current_lang`, so morphdom re-mounts everything inside on tab
change). `ProjectFormLive` and `TaskFormLive` use a two-card layout
(translatable card + settings card) inside one `<.form>`;
`AssignmentFormLive` has only one translatable field, so it renders
the tabs above the form and uses `<.translatable_field>` standalone
without a `multilang_fields_wrapper`.

## What this module does NOT have

Pinning the deliberate non-features so future-me doesn't propose them as
"missing":

- **No tenant scoping on PubSub topics** — `projects:all` /
  `projects:tasks` / `projects:templates` fan out to every subscriber.
  Per-tenant scoping is a framework-wide gap (no other feature module
  partitions PubSub by tenant either); the right shape is to thread an
  org/tenant key through every topic when core grows that capability.
  Per-project topic (`projects:project:<uuid>`) is already safe — you
  need the UUID to subscribe.
- **`ProjectShowLive` is mount-only by design** — initial DB reads happen
  at the tail of `mount/3`, not in `handle_params/3`. The 0.2.0 CHANGELOG
  noted a `handle_params/3` refactor across all list/show/form LVs to
  share the disconnected/connected query path; on `ProjectShowLive` that
  was reverted (issue #5) because Phoenix LiveView refuses to mount any LV
  exporting `handle_params/3` outside a router live route, which blocks
  embedding via `live_render`. Same constraint applies if a sibling LV
  ever needs to be embedded — drop `handle_params/3` and move its body
  into the mount tail.
- **No event-debounce / minimal-delta on OverviewLive `handle_info`** —
  every `:projects, _, _` broadcast triggers a full dashboard reload
  (~10 queries). Reviewer flagged in PR #1 review item #7. Same scope
  reason as above.
- **No status-helper extraction** — `status_color/1` /
  `status_badge_class/1` / `status_label/1` are duplicated between
  `OverviewLive` and `ProjectShowLive`. Cosmetic; surfaced for a future
  extraction batch when a third call site appears.
- **No HTTP boundary** — context calls only PostgreSQL via Ecto and
  reads core's settings; no `Req.get` / `:httpc.request` / external
  service. So no SSRF guard, no `Req.Test`-via-app-config stub pattern.
- **No own migrations** — V100 (staff) and V101 (projects) live in core
  `phoenix_kit`. Schema changes go in the next core `VNN`. Test-only
  setup migration inlines V100 + V101 + V105 verbatim, idempotent so a
  future Hex release containing them is a no-op.
- **No HTTP backend for translations** — translations live in this
  repo's `priv/gettext/` (module-domain strings, `PhoenixKitProjects.Gettext`
  backend) and in core's `priv/gettext/` (the ~16 common strings reached
  via the `PhoenixKitWeb.Gettext` backend). See the Gettext entry under
  Conventions and `dev_docs/i18n_triage.md` for the split.
- **No own Errors module for HTTP error shapes** — `Errors.message/1`
  covers `:not_found` / `:template_not_found` / `:task_not_found` plus
  a generic fallback. Add a new branch when a context fn introduces a
  new `{:error, atom}` shape.

## Planned: per-task work-hours toggle + per-user work schedule

Deferred enhancement to `Project.planned_end_for/2`'s weekday-only
model. After V112's fix the model treats every weekday-only duration
as work hours at a 3:1 calendar:work ratio (24 calendar hours = 8
work hours). This is fine for multi-day tasks ("5 days = 5 workdays =
Mon→Fri") but overshoots for short tasks: a 2-hour minute/hour-unit
task started Sat evening doesn't really need to "wait for Monday
morning" before it can be considered late — but the proportional
model says it does.

### Design

A per-task **`count_as_work_hours`** boolean decides which clock the
task's duration ticks against:

- **`false` (calendar)** — duration consumes raw calendar time,
  ignoring weekends/nights. New tasks default to `false` when the
  form unit is `minutes` or `hours`.
- **`true` (work hours)** — duration only ticks during work windows.
  New tasks default to `true` when the form unit is `days` or longer.

The **work schedule** lives on `PhoenixKitStaff.Schemas.Person` as a
JSONB column `work_schedule` keyed by weekday. Shape:

```json
{
  "monday":    {"start": "09:00", "end": "17:00"},
  "tuesday":   {"start": "09:00", "end": "17:00"},
  "wednesday": {"start": "09:00", "end": "17:00"},
  "thursday":  {"start": "09:00", "end": "17:00"},
  "friday":    {"start": "09:00", "end": "17:00"},
  "saturday":  null,
  "sunday":    null
}
```

When a `count_as_work_hours: true` task has an `assigned_person_uuid`,
its planned-end calc walks calendar time consuming budget only inside
that person's windows. Fallbacks, in order: assignee's
`work_schedule` → built-in `Mon-Fri 09:00–17:00` default. Tasks
assigned to a team/department (not a single person) use the default;
multi-assignee schedule resolution is out of scope for v1.

### Why this lives on Person, not Task

The schedule is a fact about the human, not the work — parallel to
the existing `work_location` / `work_phone` fields. The staff
module's "NOT a full HRIS" caveat in `phoenix_kit_staff/AGENTS.md`
forbids PTO ledgers and payroll; static work hours are closer to
existing per-person profile data and were judged acceptable.

### Scope (when this lands)

- **V113 migration** (in core `phoenix_kit`):
  - `count_as_work_hours BOOLEAN NOT NULL DEFAULT false` on
    `phoenix_kit_project_tasks` and `phoenix_kit_project_assignments`
  - `work_schedule JSONB NOT NULL DEFAULT '{}'` on
    `phoenix_kit_staff_people`
- **Schemas**: add the field to `Task`, `Assignment`, `Person`.
- **Math** — refactor `planned_end_for/2` and `work_hours_elapsed/2`
  to walk per-task. The current single-sum-of-hours design must be
  replaced with a sequential walk: iterate tasks in `position` order,
  extending the running cursor by each task's calendar OR work-window
  budget. `Projects.project_summaries/1` needs to return enough
  per-task data (or a precomputed `planned_end`) instead of a single
  scalar `total_hours`.
- **UI**:
  - `task_form_live.ex` / `assignment_form_live.ex` — checkbox
    "Count as work hours" visible when unit is minutes/hours; hidden
    (always `true`) for days+.
  - `person_form_live.ex` (in staff) — 7-row schedule editor (Mon–Sun
    each with start + end time inputs; empty pair = day off).
- **No backfill** — pre-launch, so existing rows take the column
  defaults. New rows inherit the unit-driven default at create time.

### Out of scope for v1

- Multiple assignees per task with different schedules — uses default.
- Lunch breaks / split windows per day — single window per day.
- Holidays / time-off / PTO — explicitly forbidden by staff module.
- Per-project schedule override — schedule is always per-assignee or
  the built-in default, never per-project.

### Origin

Surfaced 2026-05-11 while fixing `planned_end_for/2`'s weekend
handling (the wider audit that produced the "calendar past planned_end
forces expected_pct = 100" fix). Resolves the impedance mismatch
where the proportional model correctly handles "5 days = Mon→Fri" but
overstates "52 minutes started Saturday evening" as not-yet-due until
Monday morning.

## TODOs

Workspace-tracked cleanups not ready for an inline `# TODO` in `lib/`.

### Drop the embed-user core-helper fallback (after the next core release)

`Web.Helpers.assign_embed_user/2` delegates to core's
`PhoenixKitWeb.Users.Auth.assign_embedded_current_user/2` **only when the
running `phoenix_kit` exposes it** — a `function_exported?`/`apply`
forward-compat guard — and otherwise falls back to a local copy
(`local_assign_embed_user/2` + `resolve_embed_identity/1`) so the
Hex-pinned build stays green against older cores. The two paths are
behaviourally identical.

Once the `phoenix_kit` requirement floor in `mix.exs` includes the release
that ships `assign_embedded_current_user/2`: **remove the guard, the
`local_assign_embed_user/2` fallback, and `resolve_embed_identity/1`, and
call the core helper directly.** The core helper landed in core's local
tree (unpushed, riding a separate core change) on 2026-06-17; this cleanup
unblocks once that core release is out and the pin is bumped. Reference:
projects PR #22 (`53224a3`).
