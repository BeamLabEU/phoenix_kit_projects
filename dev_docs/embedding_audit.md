# Embedding Audit — phoenix_kit_projects

**Status:** All 9 LiveViews are embeddable via `live_render`. Initial
fix on `ProjectShowLive` shipped in response to upstream issue
[#5](https://github.com/BeamLabEU/phoenix_kit_projects/issues/5); the
remaining 8 LVs were brought to the same standard in the follow-up
sweep. Coverage is pinned by 28 `live_isolated/3` tests in
`test/phoenix_kit_projects/web/embedding_test.exs`.

This doc is the bulletproof reference — what was blocked, why it was
blocked, the shape of each fix, why these problems existed, and the
test convention that stops them from being re-introduced.

## Why embedding matters

Host apps (the canonical case is Tymofii's Andi app — sub-order
"Project" tab) want to drop the **module's own** LiveView into their
own workflow via `live_render/3` so any upstream UX improvement lands
in their app for free, instead of re-implementing the timeline /
status / dependency / comments surfaces against
`PhoenixKitProjects.Projects` context functions.

This is the second-class reuse model PhoenixKit has tacitly opted into:
sibling modules consume each other's **contexts** (`Staff.list_people/1`,
`Catalogue.get_item/1`) but never each other's LVs. Host apps want the
LVs too, and Phoenix LiveView already supports it via `live_render` —
we just have to stop blocking it.

## The contract Phoenix LiveView enforces

When an LV is mounted via `live_render(socket, mod, id: "...", session:
%{...})` (i.e. **not** through `live "/...", Mod` in a router):

1. `params` arrives as the atom `:not_mounted_at_router` instead of a
   map. Any clause like `def mount(%{"id" => id}, ...)` raises
   `FunctionClauseError` before the LV can start. Use `_params` or add
   a sibling `mount(:not_mounted_at_router, %{"id" => id} = session, socket)`
   clause that delegates.
2. **If the LV exports `def handle_params/3`,** Phoenix LV's
   `channel.ex:580-583` checks `socket.root_pid != self() or is_nil(router)`
   and raises from `Route.live_link_info!`:

   > cannot invoke handle_params/3 on `Mod` because it is not mounted
   > nor accessed through the router live/3 macro

   This fires **regardless** of what `handle_params/3` actually does —
   even a no-op `def handle_params(_, _, s), do: {:noreply, s}` trips
   it. The check is on export presence, not body. Fix: drop
   `handle_params/3`; fold its body into the tail of `mount/3` (gate
   on `connected?(socket)` if you want to preserve the cheap
   disconnected render).
3. Hardcoded wrapper classes (`mx-auto max-w-Nxl`) freeze a layout
   assumption — narrow centered column — that's right for the
   standalone admin page and wrong for a wide host layout. Make the
   wrapper class a session-overridable assign with a sane default.

The first two are hard blockers (the LV crashes or refuses to mount).
The third is soft (the LV mounts but looks broken).

## Per-LV diagnosis

All 9 LVs are fixed; the catalogue below records what was blocked and
what shape each fix took, so future-me (or the next contributor) can
match new LVs against the playbook.

### Tier 1 — read-only LVs, high embed value

Mechanical fix: each `handle_params/3` body was a single `load_*(socket)`
call that folded straight into the mount tail.

**`overview_live.ex`** — dashboard, `max-w-6xl`
- Was: `handle_params/3` exported; body `{:noreply, reload(socket)}`.
- Fix: dropped `handle_params/3`; mount tail loads unconditionally
  (`{:ok, reload(socket)}`). Both disconnected and connected mounts
  hit the DB so the first HTML response already has content — no
  empty-skeleton pop-in. Wrapper class via `session["wrapper_class"]`
  with `@default_wrapper_class` module attribute.
- Embed value: **HIGH** — host home page widget.

**`projects_live.ex`** — list, `max-w-5xl`
- Was: `handle_params/3` exported; body `{:noreply,
  load_projects(socket)}`.
- Fix: identical shape to `overview_live`.
- Embed value: **HIGH** — host "recent projects" panel.

### Tier 2 — read-only LVs, medium embed value

**`templates_live.ex`** — list, `max-w-5xl`
- Was: `handle_params/3` exported; body `{:noreply,
  load_templates(socket)}`.
- Fix: identical shape to Tier 1.
- Embed value: **MEDIUM**.

**`tasks_live.ex`** — list with view toggle, `max-w-5xl`
- Was: `handle_params/3` exported; body read `params["view"]` to gate
  between `"list"` and `"groups"`. View toggle was URL-driven
  (`<.link patch={"?view=…"}>`).
- Fix: dropped the URL param. View toggle is now a
  `<button phx-click="set_view" phx-value-view="…">` that fires a
  `handle_event/3` clause assigning `:view` and reloading. Embedders
  preselect via `session["view"]` (validated against `@valid_views`,
  defaults to `"list"`). Bookmarkability of `?view=groups` on the admin
  page is lost — UI state, not a real route arg.
- Embed value: **MEDIUM**.

### Tier 3 — form LVs

Forms had two extra concerns beyond the Tier 1/2 pattern:
1. **`live_action`** (`:new` / `:edit`) is set by the router. Embedded
   mount has no router → no live_action. The host has to pass it.
2. **Save-time `push_navigate`** to `Paths.projects()` /
   `Paths.project(uuid)` navigates the top-level browser session,
   yanking the user out of the host workflow. For forms, save is the
   common path.

**Helpers added** in `PhoenixKitProjects.Web.Helpers`:
- `resolve_live_action/3` — reads action from router-set assign OR
  `session["live_action"]`, falls back to `:new`. Uses
  `String.to_existing_atom/1` so unknown values can't mint atoms.
- `resolve_action_params/2` — extracts `"id"` / `"project_id"` /
  `"template"` from session when `params == :not_mounted_at_router`.
- `navigate_after_save/2` — push_navigates to either the
  `session["redirect_to"]` override (now on socket as
  `:embed_redirect_to`) or the default path. Used in save success
  handlers AND on apply_action error paths (project / assignment not
  found).
- `maybe_put_locale/1` — reads `session["locale"]` and restores the
  Gettext locale in the embedded LV process. Because `live_render/3`
  spawns a new process, the parent's process-dictionary locale is lost;
  without this helper all translations fall back to English. Called at
  the top of every embeddable LV's `mount/3`.

**`project_form_live.ex`** — `max-w-xl`, **MEDIUM**
- Fix: `mount/3` resolves wrapper_class / live_action / embed_redirect_to
  / action params from session, then calls `apply_action/3` at the
  mount tail. `handle_params/3` dropped. Four `push_navigate` call
  sites swapped to `WebHelpers.navigate_after_save`.

**`assignment_form_live.ex`** — `max-w-xl`, **MEDIUM**
- Same shape. Seven `push_navigate` call sites (three apply_action
  error paths, four save handlers) all routed through
  `WebHelpers.navigate_after_save`. Embedders pass `project_id` (and
  optionally `id` for `:edit`) via session.

**`task_form_live.ex`** — `max-w-xl`, **LOW**
- Same shape, applied for consistency rather than concrete embed need.

**`template_form_live.ex`** — `max-w-xl`, **LOW**
- Same shape.

**Shipped** (`dev_docs/embedding_emit.md`): the PubSub-emit-and-let-
host-react seam. Embedded LVs in `mode: "emit"` broadcast UI-intent
events on a host-supplied topic (`:opened` / `:closed` / `:saved` /
`:deleted`) **instead of** calling `push_navigate` — every one of
this module's nav sites now routes through `<.smart_link>` /
`navigate_or_open/2` / `close_or_navigate/2` /
`navigate_after_save/3` / `notify_deleted_or_navigate/4`. The module
also ships `PhoenixKitProjects.Web.PopupHostLive` + `<.popup_host>`,
an opinionated host shell that subscribes to the topic, manages a
daisyUI `<dialog>` modal stack with frame-ref-based race-safe pop
semantics, and `live_render`s the requested LV inside each frame.
See `dev_docs/embedding_emit.md` for the full contract and `<.popup_host>`
reference.

## Why these problems exist

The pattern analysis from the Phase 1 fix applies verbatim to the rest
of the module. Five root causes:

1. **The 0.2.0 `handle_params` refactor was workspace-wide and
   blast-radius-blind.** The CHANGELOG framed it as a perf win: "HTTP
   render + WebSocket connect share a single query path." Sensible
   for the admin-route case, silently traded away the unstated
   capability of `live_render` embedding. No annotation in the
   migration guide said "this assumes you'll never embed."
2. **Module mental model is `/admin`-only.** AGENTS.md describes LVs
   as belonging to `/phoenix_kit/admin/<module>/...`. Cross-module
   reuse has historically meant *context functions*. The framework
   encouraged context reuse and was silent on LV reuse, so authors
   weren't omitting embed clauses — they didn't know those clauses
   existed.
3. **Wrapper class is copy-paste from a single template.** All 8 LVs
   open with `flex flex-col mx-auto max-w-{xl,5xl,6xl} px-4 py-6
   gap-{4,6}` — only the `max-w-N` varies. Originated from an early
   detail LV and propagated by copy-paste, freezing a layout
   assumption (narrow centered column) that wasn't a deliberate
   design call.
4. **No test harness ever exercised `live_isolated/3`.** Across all
   of Max's modules, **zero existing tests use `live_isolated/3`**.
   Every LV test goes through the router via `live(conn,
   "/en/admin/...")`. CI catches router-clause mount bugs instantly;
   it cannot catch embed-clause mount bugs because no test asks the
   question.
5. **No CI gate or convention check.** Nothing flags
   `def handle_params/3` + map-destructured `def mount/3` as
   co-occurrence. Credo doesn't check it; dialyzer doesn't either
   (the types match — `unsigned_params() | :not_mounted_at_router` is
   `term()` in practice). The contract is enforced only at mount
   time on the embed code path that was never exercised.

Issue #5 surfaced externally because the reporter (Andi) is the first
external embedder of a phoenix_kit module. Max's own apps consume
modules only via admin routes, so the bug was structurally invisible
to Max's testing surface. Same reason the wrapper-class hardcoding
never registered — every internal consumer was the admin layout,
which is what the hardcoded class assumes.

## Completed work

All four bulletproofing steps from the original plan landed in one
sweep:

- **Step 0 (issue #5 follow-up):** `ProjectShowLive` fixed, embed tests
  added, AGENTS.md contract section written.
- **Step 1 — Tier 1.** `overview_live`, `projects_live` migrated:
  `handle_params/3` dropped, mount tail loads on `connected?`, wrapper
  class parameterized.
- **Step 2 — Tier 2.** `templates_live` same as Tier 1.
  `tasks_live` additionally swapped URL-driven `?view=` for a
  `phx-click` toggle (with `session["view"]` preselect for embedders).
- **Step 3 — Tier 3.** All four form LVs (`project_form_live`,
  `assignment_form_live`, `task_form_live`, `template_form_live`)
  migrated with the same shape. Helpers in
  `PhoenixKitProjects.Web.Helpers`:
  `resolve_live_action/3`, `resolve_action_params/2`,
  `navigate_after_save/2`. The `session["redirect_to"]` seam ships;
  the PubSub-emit alternative stays deferred until a concrete embedder
  needs it.
- **Step 4 — Regression prevention.** `test/phoenix_kit_projects/web/
  embedding_test.exs` (28 tests) is the single source of truth for the
  embed contract. CI runs it on every PR.

## Test convention to prevent regression

Every read-only LV that's intended to be embeddable gets a
`describe "embedded (live_isolated)"` block in its test file with
three tests (mirrors the shape added to `project_show_live_test.exs`):

```elixir
describe "embedded (live_isolated)" do
  test "mounts via live_isolated with session params", %{conn: conn} do
    # … setup …
    {:ok, _view, html} =
      live_isolated(conn, PhoenixKitProjects.Web.OverviewLive, session: %{})
    assert html =~ gettext("Projects")
  end

  test "wrapper_class defaults to the standalone layout", %{conn: conn} do
    {:ok, _view, html} =
      live_isolated(conn, PhoenixKitProjects.Web.OverviewLive, session: %{})
    assert html =~ "mx-auto max-w-6xl"
  end

  test "wrapper_class override from session replaces the default", %{conn: conn} do
    {:ok, _view, html} =
      live_isolated(conn, PhoenixKitProjects.Web.OverviewLive,
        session: %{"wrapper_class" => "flex flex-col w-full px-4 py-6 gap-6"}
      )
    assert html =~ "flex flex-col w-full px-4 py-6 gap-6"
    refute html =~ "max-w-6xl"
  end
end
```

These three tests catch all three blockers as a unit:
- Test 1 fails if mount/3 or handle_params/3 breaks embed.
- Test 2 + 3 fail if the wrapper assign isn't wired correctly.

**Rule for new LVs in this module:** if it's a read-only LV (show,
list, dashboard) and could plausibly be embedded by a host app, the
`embedded (live_isolated)` describe block is mandatory. Add it on the
same PR that introduces the LV. The shape is mechanical; it adds
~30 lines and seconds of test runtime.

## Pre-flight checklist for new LVs

When writing a new read-only LV in `phoenix_kit_projects`, before
opening the PR:

- [ ] `mount/3` either uses `_params` for the first arg **or** has
  both a router clause **and** a `mount(:not_mounted_at_router,
  session, socket)` clause that delegates.
- [ ] **No `def handle_params/3` exported.** If you need to load data
  on mount, do it at the tail of `mount/3`. If you need URL-derived
  state, see "Why no handle_params?" below.
- [ ] The outermost `<div>` in `render/1` uses `class={@wrapper_class}`
  with a default assigned in `mount/3` reading `session["wrapper_class"]`.
- [ ] A `describe "embedded (live_isolated)"` block exists in the test
  file with the three canonical assertions.

## Why no `handle_params/3`?

The 0.2.0 refactor introduced `handle_params/3` to share the
disconnected/connected query path. The unstated cost was breaking
embeddability. Replacement pattern:

```elixir
def mount(_params, session, socket) do
  wrapper_class = Map.get(session, "wrapper_class", @default_wrapper_class)

  socket =
    socket
    |> assign(wrapper_class: wrapper_class, …skeleton defaults…)
    |> load_data()

  {:ok, socket}
end
```

**Load on both disconnected and connected mount.** The skeleton
assigns are defensive defaults that `load_data/1` overwrites on the
same socket — the render path never actually paints them. An earlier
draft gated the load on `connected?(socket)` to "keep the disconnected
render cheap"; that was a mistake. mount/3 runs twice on first page
load regardless (disconnected HTTP render → connect → connected
mount), so the DB cost was identical, but the gated version shipped
empty content on the first HTML response and pop-in on connect. Don't
do that. (Same trade-off as the 0.2.0 `handle_params/3` pattern minus
the embed blocker.)

If you genuinely need to parse URL params (`?view=tree`,
`?page=N`, etc.), prefer:

1. A `phx-click` event that assigns local state (works in router AND
   embed), or
2. Reading from `get_connect_params(socket)` once in mount (URL or
   query string params available there too).

`handle_params/3` is reserved for LVs that **never** need to be
embedded — currently none in this module.

## Open questions / things that would harden this further

- **Should we promote `wrapper_class` into a `PhoenixKitWeb` core
  helper?** Right now each LV opens with `<div class={@wrapper_class}>`
  and duplicates the default constant. A core function component
  (`<.embeddable_wrapper class={@wrapper_class}>...</.embeddable_wrapper>`
  with a workspace-wide default) would normalize this across all
  modules. Promotion is the same mechanical lift described in
  AGENTS.md for component-promotion.
- **Does `push_navigate` from within an embedded LV need a seam?**
  For show LVs it's a rare path; for form LVs it's the common path
  (every save). The Tier 3 design section sketches two shapes; we'll
  pick one when a real form-embed requirement lands.
- **PubSub topic scoping in multi-tenant hosts.** `projects:all` is
  global; two embeddings of different projects on the same host page
  will both re-render on every project event. Probably fine in
  practice (renders are cheap), but the right shape long-term is to
  thread a tenant key through every topic — out of scope until core
  grows tenant support.
