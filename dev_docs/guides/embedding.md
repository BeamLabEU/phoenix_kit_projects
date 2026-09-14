# Embedding

How a host app mounts this module's LiveViews inside its own pages — the
`live_render` layout contract, emit mode, and the popup host.

Rules for this live in [AGENTS.md](../../AGENTS.md) → Feature notes.

**See also:** [`../embedding_audit.md`](../embedding_audit.md) — the deep-dive
audit of every LV in this module, why the blockers exist, the per-LV fix
shapes, the test convention, and the pre-flight checklist for new LVs. Read it
before adding a new LV. [`../embedding_emit.md`](../embedding_emit.md) carries
the full emit-mode contract.

## Embedding LiveViews via `live_render`

**Every LV is embeddable.** The regression gate is
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
composer, and renders the **task-view tab bar in embeds too**
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
> `:phoenix_kit_js_sources` compiler (run `mix phoenix_kit.update`,
> recompile, rebuild assets). A non-PhoenixKit
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

## Session-key contract (all keys optional unless noted)

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
  **defaults `false`** in embeds. The tab strips render in every embed
  (only templates stay tabless), but the URL mirror — a hidden element
  carrying the active tab's canonical address in `data-url`, which core's
  `PkUrlMirror` hook writes over the browser's via `history.replaceState`
  (no history entries; back/forward return to the previous page, and
  per-tab entries are impossible without `handle_params/3`, which would
  block embedding) — is **off by default**: an embed must not rewrite the
  host's address bar. Pass `true` (a real boolean, not `"true"`) only if
  the host mounts the show page as its own full-page route and wants
  `/tasks/board` / `/whiteboards` / `/comments` deep-linking. The
  router-mounted standalone admin page enables it implicitly.
- `id:` opt on `live_render` should be unique per logical embed (e.g.
  include the resource UUID) so two embeddings of the same LV on one
  page don't collide.

## Behavior notes

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

## Emit mode + popup host

The contract above handles **layout** (where the embedded LV sits, how
session keys flow). The follow-up problem: *navigation* inside an embedded
LV still calls top-level `push_navigate`, yanking the user out of the host
page. The fix — two extra session keys turn every `push_navigate` site into
a PubSub broadcast on a host topic:

| Key | Default | Required when | Notes |
|---|---|---|---|
| `"mode"` | `"navigate"` | — | `"emit"` switches all nav sites to broadcast; `"popup"` broadcasts only the sites that opt in (forms) and keeps page links |
| `"pubsub_topic"` | `nil` | `mode in ["emit", "popup"]` | Host-supplied topic |
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
{:projects, :dirty,   %{frame_ref, dirty}}          # form holds unsaved edits ⇒ host makes the frame un-closeable
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
`root_view` session key — it subscribes, manages a modal stack of
core `<.modal>` dialogs (native `<dialog>` + `PkDialog`: top layer,
Esc/backdrop, stacked children) and renders requested LVs inside via
`live_render`. Two more session keys shape the frames:

| Key | Default | Notes |
|---|---|---|
| `"placement"` | `"center"` | `"end"` renders every frame as a full-height right-hand sheet (a drawer) |
| `"max_width"` | `6xl` centered, `2xl` as a drawer | any core `max_width` value (`sm` … `7xl`, `full`) |

**Dirty frames.** A form that holds unsaved edits reports
`{:projects, :dirty, %{frame_ref, dirty: true}}` (`WebHelpers.mark_dirty/1`
piped into every handler that changes what a save would write — the
four form LVs do this; `notify_dirty/2` is a no-op outside emit mode);
the host then renders that frame with `closeable: false`, so Esc and
the backdrop do nothing and the form's own Cancel (which confirms
via `data-confirm` from `@dirty?`) is the only way out. Every frame
also arms core's `close_guard={:input}`, which makes the dialog
non-closeable on the client from the first keystroke — covering the
round trip and the forms' `phx-debounce` window. Clean again ⇒
closeable again. Refs that are no longer on the stack are ignored.

**Back inside a frame is Cancel.** The forms' header back link is a
page link only in navigate mode; in a frame it is a `phx-click="cancel"`
button (same confirm) — a frame must never push the list or project
page as another frame.

**Client-supplied sessions are sanitized.** The `phx-value-session`
on an `open_embed` button is client-editable; `sanitize_session_overrides/1`
drops the host-owned keys (`current_user_uuid`, `mode`, `pubsub_topic`,
`frame_ref`) at both ends — the emitter's `open_embed` handler and
`PopupHostLive` before it stamps the frame's session — so a crafted
payload cannot open a form as another user or re-route its events.
Never `put_new` an identity key from a wire session.

**Programmatic navigation in popup mode.** `navigate_or_open/2` takes
`popup: false` for page targets (a child project from the gantt or
calendar); the default opens the target in the drawer, mirroring
`<.smart_link popup={false}>`.

**The project page hosts its own drawer** (`embed_mode: :popup`).
`ProjectShowLive` mounted on the router flips `:navigate` to `:popup`,
generates a private topic (`projects:popup:<socket id>`) and renders a
`PopupHostLive` child with `placement: "end"`. In `:popup` mode
`<.smart_link>`/`<.smart_menu_link>` render the popup button by
default; a link that must leave the page passes `popup={false}`
(Files, Members, Modules, Activity, child projects do). Forms
(`AssignmentFormLive` in every flavour, edit project/template) open in
the sheet; a save pops it and the page's PubSub subscription refreshes
the plan. A page embedded by a host keeps the host's own mode — the
flip only happens on the router mount. Tests that drive the drawer
need a REAL user in the page scope (`fake_scope(user_uuid:
embed_user_uuid!())`): the sheet's form mounts off-router and rebuilds
identity from the page's `current_user_uuid`; a synthetic uuid
degrades it to anonymous and it closes itself.

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
