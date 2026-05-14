# Emit Mode + Popup Host — `phoenix_kit_projects`

**Status:** Shipped. All 9 LVs in this module honor the emit-mode
contract; the `<.popup_host>` function component + `PopupHostLive`
LiveView ship the opinionated "popup-driven embed" UX. Regression
gate: `test/phoenix_kit_projects/web/embedding_emit_test.exs` +
`popup_host_live_test.exs`.

This doc is the reference for hosts that want to render this
module's LVs as popups (or drawers / sidepanels) instead of as
top-level admin pages.

## Why this exists

PR #6 made every LV embeddable via `live_render`. The deferred
concern flagged at `embedding_audit.md:146-150` was that every
in-LV navigation (`<.link navigate>`, form-save `push_navigate`)
still targeted the **top-level** browser session — clicking a card
inside an embedded `OverviewLive` yanked the user out of the host
page entirely. The host's own form state was lost, the URL changed,
and the host had no way to keep the user where they started.

The fix: when a host passes `session["mode"] = "emit"` + a PubSub
topic to an embedded LV, no `push_navigate` ever fires from this
module. Instead, every navigation site broadcasts a UI-intent event
on the host topic. The host renders the requested LV inside a
popup/drawer/inline-panel on the existing page — no URL change, no
DOM replacement, host form state intact.

## The two layers

### Layer 1 — The contract (`mode: "emit"`)

Every embeddable LV reads four new session keys via
`PhoenixKitProjects.Web.Helpers.assign_embed_state/2`:

| Key | Default | Required when | Notes |
|---|---|---|---|
| `"mode"` | `"navigate"` | — | `"navigate"` keeps PR #6 behaviour; `"emit"` enables broadcasts |
| `"pubsub_topic"` | `nil` | `mode == "emit"` | Host-supplied topic string; mount **raises** if `emit` is set without a topic |
| `"frame_ref"` | `nil` | inherited from PopupHost | Opaque integer; stamped into every emit so the receiver can dedup against the modal stack |
| `"close_on"` | `["closed"]` | — | Subset of `["closed", "saved", "deleted"]`; reserved for future per-frame opt-in (today PopupHost closes on all three) |

`session["redirect_to"]` from PR #6 stays supported in navigate mode.
If both `redirect_to` and `mode: "emit"` are passed, a warning logs
and emit wins.

### Layer 2 — `PhoenixKitProjects.Web.PopupHostLive`

The opinionated wrapper. Host mounts it once via `live_render`:

```heex
{Phoenix.Component.live_render(@socket, PhoenixKitProjects.Web.PopupHostLive,
   id: "projects-popup-host",
   session: %{
     "pubsub_topic" => "host:orders:" <> @order_id,
     "root_view" => %{
       "lv" => "Elixir.PhoenixKitProjects.Web.OverviewLive",
       "session" => %{
         "wrapper_class" => "flex flex-col w-full px-4 py-6 gap-6"
       }
     }
   })}
```

What it does:

1. Subscribes to `"host:orders:" <> @order_id` on connect.
2. Renders `OverviewLive` inline as the always-visible content
   (passing `mode: "emit"` + the topic into its session).
3. On `{:projects, :opened, %{lv, session, frame_ref}}` — generates
   a fresh `frame_ref`, pushes a frame onto the modal stack, renders
   the target LV inside a daisyUI `<dialog>` with `mode: "emit"` +
   the same topic propagated.
4. On `{:projects, :closed | :saved | :deleted, %{frame_ref: ref}}`
   — pops the top frame iff `ref` matches (race-safe against stale
   events from a modal the user already closed).
5. ESC and modal-backdrop click also pop the top.
6. Caps stack depth at 5 (configurable in the LV).

## The event vocabulary

UI-intent verbs, distinct from `PhoenixKitProjects.PubSub`'s
content-broadcast verbs so `handle_info` clauses subscribed to
canonical `projects:*` topics never collide with handlers on a host
topic:

```elixir
{:projects, :opened, %{lv: module(), session: map(), frame_ref: integer() | nil}}
{:projects, :closed, %{frame_ref: integer() | nil}}
{:projects, :saved, %{kind: kind(), action: :create | :update,
                      record: struct(), close: boolean(),
                      next: {module(), map()} | nil,
                      frame_ref: integer() | nil}}
{:projects, :deleted, %{kind: kind(), uuid: binary(), close: boolean(),
                        frame_ref: integer() | nil}}

# kind() :: :project | :task | :template | :assignment
```

**`close:` flag.** `:saved` and `:deleted` carry a close-intent flag so
the emitter — not the receiver — decides whether the modal frame
should pop. The two flavors:

| Emitter call site | Event | `close` | Why |
|---|---|---|---|
| `navigate_after_save/3` (form-LV save) | `:saved` | `true` | Form is terminal — modal closes |
| `notify_deleted_or_navigate/4` (LV's own resource deleted) | `:deleted` | `true` | Resource is gone — modal closes |
| `notify_deleted/3` (list-LV row deleted) | `:deleted` | `false` | List stays open; row vanishes via local reload |

`PopupHostLive` pops the matching frame iff `close: true` AND `frame_ref` matches the top. `close: false` events are informational only — the host's other subscribers can still react.

**`next:` chain (on `:saved` only).** Optional `{module(), map()}`
tuple. When set together with `close: true`, PopupHost pops the current
frame and pushes a new frame for `next` — mirrors the navigate-mode
`push_navigate(to: edit_path)` flow that takes a user from "just
created" to "now configure it." Used by `TaskFormLive` (`:new` → `:edit`
so user can add deps), `ProjectFormLive` (`:new` → project show),
`TemplateFormLive` (`:new` → template show). `next` is rejected at
emit time when `close: false` (the combination has no defined
semantics — `next` always replaces the current frame, never stacks on
top of it). The `next` LV must pass `embeddable_lv?/1`.

**Stale-emitter guards (load-bearing race safety).** PopupHost only
acts on `:opened`, `:closed`, `:saved`, `:deleted` when the event's
`frame_ref` matches the current top of the stack (nil ↔ empty stack ↔
root view). Stale or adversarial broadcasts are dropped + logged. A
practical consequence: a root view cannot emit `:opened` while a modal
is already stacked — the emitter's `frame_ref` (nil for root) won't
match the modal's ref (non-nil). This is deliberate. Root-driven
background workflows (e.g. "after a long-running job completes, auto-
open a modal") must either wait for the stack to be empty before
emitting, or emit from a stacked frame that's actually open. If a
future use case needs a more permissive policy, add a `policy:` field
to the `:opened` payload rather than weakening the guard.

The `:projects` discriminator matches the existing module-broadcast
namespace (`PhoenixKitProjects.PubSub:15`). The four event atoms
are reserved — content broadcasts use `:project_created`,
`:assignment_updated`, etc.

## Helpers (callers)

In `PhoenixKitProjects.Web.Helpers`:

- **`assign_embed_state(socket, session) :: socket`** — call from
  every LV's `mount/3`. Reads the four embed-mode session keys,
  validates, and assigns `:embed_mode`, `:embed_pubsub_topic`,
  `:embed_frame_ref`, `:embed_close_on`. Raises if `mode == "emit"`
  without a topic.
- **`attach_open_embed_hook(socket) :: socket`** — chain after
  `assign_embed_state/2`. Attaches the shared `open_embed` event
  handler via `Phoenix.LiveView.attach_hook/4`, which intercepts
  `<.smart_link>` clicks in emit mode.
- **`navigate_or_open(socket, opts) :: socket`** — generic
  branching primitive. `opts: [to: path, open: {Module, session}]`.
  Navigate mode pushes to `to`; emit mode broadcasts `:opened`.
- **`close_or_navigate(socket, fallback_path) :: socket`** — for
  Cancel / Back / error paths. Navigate mode push-navigates
  (respecting `:embed_redirect_to` with the open-redirect guard);
  emit mode broadcasts `:closed`.
- **`navigate_after_save(socket, default_path, opts) :: socket`** —
  for form save success. Navigate mode push-navigates; emit mode
  broadcasts `:saved` with `kind: :project | :task | :template |
  :assignment`, `record:`, and `action: :create | :update` from
  opts.
- **`notify_deleted_or_navigate(socket, kind, uuid, fallback_path)
  :: socket`** — for delete success. Emit mode broadcasts `:deleted`.

## `<.smart_link>` component

Replaces `<.link navigate={...}>` everywhere this module navigates
to another module LV. In navigate mode renders a real `<a href>`
(right-click-new-tab works, prefetch works, screen readers see a
link). In emit mode renders a `<button phx-click="open_embed">`
that the hook decodes against the whitelist and emits.

```heex
<.smart_link
  navigate={Paths.project(uuid)}
  emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => uuid}}}
  embed_mode={@embed_mode}
  class="link link-hover"
>
  Project name
</.smart_link>
```

## Whitelist guard

`Helpers.embeddable_lvs/0` is a compile-time list of the 9 LVs this
module exposes. `Helpers.embeddable_lv?/1` rejects anything else.
The `open_embed` handler validates `phx-value-lv` against this list
before calling `String.to_existing_atom/1`, and `PopupHostLive`
re-validates on every `:opened` message. Protects against
hot-reload renames, accidental cross-module embedding, and any
future HTTP-boundary wiring.

## Test convention

Every embeddable LV has a describe block in
`test/phoenix_kit_projects/web/embedding_emit_test.exs`:

```elixir
test "emit-mode mount with topic", %{conn: conn} do
  topic = unique_topic()
  ProjectsPubSub.subscribe(topic)

  {:ok, view, _} =
    live_isolated(conn, MyLV, session: %{
      "mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 0
    })

  view |> element("button[phx-click=open_embed]", "Some action") |> render_click()

  assert_receive {:projects, :opened, %{lv: TargetLV, session: ..., frame_ref: 0}}, 500
end
```

The `frame_ref` round-trip pins that the LV stamps the supplied ref
into every emit — the popup host relies on this for race-safe pops.

## What this doesn't include

- **Multi-tenant topic namespacing** — out of scope until core
  grows tenants. Document that the host owns the topic name.
- **PopupHost permission gate** — embedded LVs already self-gate
  via `permission: "projects"`. PopupHost is a UI shell, not an auth
  boundary.
- **`previous_record` in `:saved` payload** — overkill for v1; add
  if a host genuinely needs diff display.
- **Cross-module promotion** to `PhoenixKitWeb.Components.PopupHost`
  — mechanical lift later when a sibling module (catalogue / staff)
  wants the same surface.
- **Comments drawer modal-aware behaviour** — the comments drawer
  uses `position: fixed` and already works inside or outside a
  modal; left alone.

## Open redirects

The PR #6 open-redirect guard on `session["redirect_to"]`
(`safe_internal_path?/1`) is still load-bearing in navigate mode
and now lives inside both `navigate_after_save/3` and
`close_or_navigate/2`. Emit mode broadcasts on a host-supplied
topic; the host owns its name and is responsible for not handing it
to other modules.

## Pre-flight checklist for new LVs

When adding a new LV to this module that's intended to be
embeddable:

- [ ] `mount/3` calls `WebHelpers.assign_embed_state(socket, session)`
  then `WebHelpers.attach_open_embed_hook(socket)`.
- [ ] Every `<.link navigate={...}>` to another module LV is
  `<.smart_link navigate={...} emit={...} embed_mode={@embed_mode}>`.
- [ ] Form save success goes through `WebHelpers.navigate_after_save/3`
  with `[kind:, record:, action:]` opts. If the navigate-mode flow takes
  the user to a follow-up screen after the save (e.g. create-then-edit),
  pass `next: {NextLV, %{...session...}}` so emit mode chains the same
  way (`close: true` is required when `next:` is set).
- [ ] Error paths (not-found) go through `WebHelpers.close_or_navigate/2`,
  with safe placeholder assigns set so the post-emit render path
  doesn't crash before the host yanks the modal.
- [ ] Cancel buttons fire `phx-click="cancel"`; the handler calls
  `WebHelpers.close_or_navigate/2`.
- [ ] **Delete success** — pick the right helper based on whether the
  LV stays on the page after the delete:
   - **`WebHelpers.notify_deleted_or_navigate/4`** — the LV's own
     resource is gone, the modal should pop. Emits `:deleted` with
     `close: true` (or push_navigates in navigate mode).
   - **`WebHelpers.notify_deleted/3`** — list/detail LV where a row
     was deleted but the LV stays open showing the post-delete state.
     Emits `:deleted` with `close: false`; no-op in navigate mode (the
     LV's local reload handles the visual update).
- [ ] Add the LV to `Helpers.embeddable_lvs/0`. `PopupHostLive`
  validates against the same list via `Helpers.embeddable_lv?/1` —
  single source of truth, no second list to keep in sync.
- [ ] Add an emit-mode describe block to `embedding_emit_test.exs`.
