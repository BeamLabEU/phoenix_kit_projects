defmodule PhoenixKitProjects.Web.Components.PopupHost do
  @moduledoc """
  Layered daisyUI `<dialog>` modal stack driven by a `modal_stack`
  assign. The function component renders the always-visible content
  (default slot) plus one `<dialog>` per stack frame, delegating each
  frame's body rendering to the `:frame` slot the host provides.

  The host LV owns state — receiving `:opened` / `:closed` / `:saved` /
  `:deleted` / `:dirty` PubSub events, pushing/popping the stack, generating
  `frame_ref`s. See `PhoenixKitProjects.Web.PopupHostLive` for the
  opinionated wrapper that does this automatically. Use the component
  directly when you need full control (e.g. modal-stack alongside other
  host state).

  Every frame is core's `<.modal>` (the `PkDialog` hook: native
  `<dialog>` in the browser's top layer, Esc + backdrop close, stacked
  dialogs closing top-first), so a popup here looks and behaves like every
  other dialog in the kit. `placement` picks the classic centered box or
  the **drawer** — a full-height sheet sliding in from the right, the
  shape for a create/edit form opened over the page it belongs to.

  ## Slots

    * `:inner_block` (default) — the always-visible content. Host
      typically embeds the root LV here via `live_render(@socket, ...)`.
    * `:frame` (with `:let={frame}`) — per-stack-frame content. Receives
      the frame map (`%{frame_ref, lv, session, id}`) so the host can
      call `live_render(@socket, frame.lv, id: frame.id, session: frame.session)`.

  ## Attrs

    * `:modal_stack` — list of frame maps (ordered bottom→top).
    * `:on_close` — event name fired on ESC, backdrop-click, and
      explicit close buttons. Host's `handle_event/3` must pop the top
      frame in response. Defaults to `"close_top_modal"`.
    * `:class` — outer wrapper class. Defaults to nil (no wrapping).

  ## Stacking and closing

  Frames open through `showModal()`, so the browser's top layer stacks
  them in open order — no z-index bookkeeping. Esc and the backdrop push
  `on_close` with the dialog's `phx-value-frame-ref`, which the host
  matches against its top frame (`pop_if_top_matches/2`). A frame the
  host marks `closeable: false` (a form that has been edited) ignores Esc
  and the backdrop — the form's own Cancel is the way out, so a stray
  click never eats what was typed. Its ✕ still closes, but asks first in
  the host's own dialog (`ConfirmAction.ask/2` for `on_close`, carrying
  the frame ref), never the browser's box: the host answers
  `request_confirm` / `confirm_action_ok` / `confirm_action_cancel` and
  draws `<.confirm_action_modal>` (`PopupHostLive` does). Stack cap at 5
  frames matches `PopupHostLive`'s `@max_stack_depth`.

  ## Example

      <.popup_host modal_stack={@modal_stack} on_close="close_top_modal">
        {live_render(@socket, PhoenixKitProjects.Web.OverviewLive,
           id: "embed-root",
           session: %{
             "mode" => "emit",
             "pubsub_topic" => @host_topic,
             "wrapper_class" => "flex flex-col w-full px-4 py-6 gap-6"
           })}

        <:frame :let={frame}>
          {live_render(@socket, frame.lv, id: frame.id, session: frame.session)}
        </:frame>
      </.popup_host>
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [modal: 1]

  alias PhoenixKitProjects.Web.Components.ConfirmAction

  attr(:modal_stack, :list, required: true)
  attr(:on_close, :string, default: "close_top_modal")
  attr(:class, :string, default: nil)

  attr(:placement, :atom,
    default: :center,
    values: [:center, :end],
    doc: "`:center` — the classic box; `:end` — the drawer (full-height sheet on the right)."
  )

  attr(:max_width, :string,
    default: "6xl",
    doc: "core `<.modal>` `max_width` for every frame (`\"2xl\"` suits a form drawer)."
  )

  attr(:modal_box_class, :string,
    default: "w-11/12 max-w-6xl",
    doc: """
    daisyUI `modal-box` sizing/class overrides. Default
    `"w-11/12 max-w-6xl"` takes 91% of the viewport width capped at
    `max-w-6xl` (72rem ≈ 1152px) — wider than daisyUI's default
    `max-w-md` so embedded admin LVs (project show, assignment form,
    etc.) have room for tables + cards + timelines. Pass a different
    Tailwind size class (`"max-w-4xl"`, `"max-w-7xl"`, etc.) if a
    host page wants a narrower or wider modal.
    """
  )

  slot(:inner_block, required: true)

  slot :frame, required: true do
    attr(:any, :any)
  end

  def popup_host(assigns) do
    ~H"""
    <%!--
      Keyframes for the per-frame loading spinner overlay. Inlined here
      so this component is self-contained regardless of the host app's
      Tailwind/CSS pipeline — repeats are harmless (CSS dedups same
      keyframe definitions). Animation runs once on mount, holds at
      `opacity: 0; visibility: hidden` thereafter so the overlay is
      truly out of the way once the LV content is composited.
    --%>
    <style nonce={PhoenixKitProjects.Web.CSP.nonce(:style)}>
      /* The frame's skeleton (Max, 2026-11-25: the opening popup was a
         thin empty strip with a spinner, then jumped to its size). A
         frame's content is its own LiveView: until that joins, its
         container is empty, and only then is the skeleton shown, shaped
         like the frame that is coming. It fades in after 150 ms, so a
         fast load never flashes it. Pure CSS: no message has to arrive
         for it to go. */
      /* One `:has()` with `:empty`: a `:has()` inside another is invalid
         CSS, and the browser dropped the whole rule, so the skeleton never
         showed (grok, 2026-11-26). The container LiveView renders before
         the frame joins has no children and no text. */
      .pkp-frame .pkp-skel { display: none; }
      .pkp-frame *:has(> [data-phx-session]:empty) > .pkp-skel {
        display: block;
        animation: pkp-skel-in 160ms ease-out 150ms both;
      }
      @keyframes pkp-skel-in { from { opacity: 0; } to { opacity: 1; } }
      /* Tabs never jump (the panel, 2026-10-31): a drawer holding a tab
         strip (`FormParts.form_tabs/1`) is one full-height column. Every
         box from the frame down to the strip is a flex column that fills
         what is left; beside the strip, the open pane is the ONE scroll
         area; everything else (the header, the form's buttons) keeps its
         height. The strip is outside what scrolls, so it cannot move. */
      /* A centred popup with tabs keeps one height whatever the open tab
         holds (the boss, 2026-10-31: the tabs jumped as the content
         changed length): the box is a fixed share of the screen, so a
         short tab leaves room at the bottom and a long one scrolls inside
         its pane — never a small box around a long tab. Popups without
         tabs (confirms, small forms) keep their own height. */
      .pkp-frame.pkp-center:has([data-pkp-tabs]) { overflow: hidden; }
      .pkp-frame.pkp-center > *:has([data-pkp-tabs]) {
        flex: none; height: 70dvh;
      }
      /* A task's view: its header (and the frame's ✕) stay, the part under
         it scrolls. The box keeps its natural height up to its maximum;
         only then does the body scroll. */
      /* The ✕, pinned by its own rule as well as its utility classes: when
         a stylesheet lacked right-6/top-6 (a rebuild still running after a
         restart) the button fell to its natural place, over the title on
         the left (Max, 2026-11-25). */
      .pkp-frame .pkp-frame-close {
        position: absolute; right: 1.5rem; top: 1.5rem; left: auto; z-index: 20;
      }
      /* A task view's header row is a line of text, not buttons: centred on
         it the ✕ sat a few pixels low. */
      .pkp-frame:has([data-pkp-view-body]) .pkp-frame-close { top: 1.25rem; }
      /* Offline (LiveView marks each view's root .phx-disconnected / .phx-error
         while the connection is down): say so, and keep the save buttons
         from looking pressable (Max, 2026-11-25: "I clicked add and close
         and nothing happened … I shouldn't be left guessing"). */
      .pkp-frame .pkp-offline { display: none; }
      .phx-disconnected .pkp-frame .pkp-offline,
      .phx-error .pkp-frame .pkp-offline,
      .pkp-frame .phx-disconnected .pkp-offline,
      .pkp-frame .phx-error .pkp-offline { display: flex; }
      .phx-disconnected .pkp-frame button[type="submit"],
      .phx-error .pkp-frame button[type="submit"],
      .pkp-frame .phx-disconnected button[type="submit"],
      .pkp-frame .phx-error button[type="submit"] { pointer-events: none; opacity: .5; }
      .pkp-frame:has([data-pkp-view-body]) { overflow: hidden; }
      .pkp-frame *:has([data-pkp-view-body]) {
        display: flex; flex-direction: column; flex: 0 1 auto; min-height: 0;
        overflow: hidden;
      }
      .pkp-frame *:has([data-pkp-view-body]) > *:not(:has([data-pkp-view-body])):not([data-pkp-view-body]) {
        flex-shrink: 0;
      }
      .pkp-frame [data-pkp-view-body] {
        flex: 0 1 auto; min-height: 0; overflow-y: auto; overscroll-behavior: contain;
      }
      /* A long hint wraps; nothing in a pane scrolls sideways. */
      .pkp-frame [role="tabpanel"] { overflow-x: hidden; }
      .pkp-frame [role="tabpanel"] .label { white-space: normal; }
      .pkp-frame *:has([data-pkp-tabs]) {
        display: flex; flex-direction: column; flex: 1 1 0%; min-height: 0;
      }
      .pkp-frame *:has([data-pkp-tabs]) > *:not(:has([data-pkp-tabs])):not([role="tabpanel"]):not([data-pkp-scroll]) {
        flex-shrink: 0;
      }
      /* A form whose tabs sit outside it (the project popup, whose Settings
         tab shows a panel that cannot be inside the form): the area after
         the tabs is the one scroll area instead of the open pane. */
      .pkp-frame *:has([data-pkp-tabs]) > [data-pkp-scroll] {
        flex: 1 1 0%; min-height: 0; overflow-y: auto; overscroll-behavior: contain;
      }
      .pkp-frame *:has(> [data-pkp-tabs]) > [role="tabpanel"]:not(.hidden) {
        flex: 1 1 0%; min-height: 0; overflow-y: auto; overscroll-behavior: contain;
      }
    </style>
    <div class={@class}>
      {render_slot(@inner_block)}
      <%!-- One core modal per frame. The id carries the frame ref so a
           frame keeps its dialog (and the browser's open state) across
           re-renders while frames above it come and go. --%>
      <.modal
        :for={frame <- @modal_stack}
        id={"popup-host-frame-#{frame.frame_ref}"}
        show={true}
        on_close={@on_close}
        closeable={Map.get(frame, :closeable, true)}
        close_guard={:input}
        placement={@placement}
        max_width={@max_width}
        class={
          [@modal_box_class, "relative pkp-frame", @placement == :center && "pkp-center"]
          |> Enum.reject(&(&1 in [nil, false]))
          |> Enum.join(" ")
        }
        phx-value-frame-ref={frame.frame_ref}
        data-frame-ref={frame.frame_ref}
      >
        <.frame_skeleton kind={skeleton_kind(frame)} />
        <%!-- A way out that is always there (Max, 2026-10-14: a drawer he
             could not close — the backdrop is a no-op while a field holds
             typed text, by `close_guard={:input}`, and there was no other
             control). A click on × is deliberate, so it closes; it asks
             first only while the form says it has unsaved changes. On the
             header's row (the boss, 2026-11-02): the box's padding is 1.5rem
             and the header's buttons are 2rem high. --%>
        <%!-- `PkpFrameClose` centres it on the frame's header row
             (`[data-pkp-frame-head]`), whatever that frame's header is
             (Max, 2026-11-25: it sat a few pixels low beside a form's
             title); the CSS position is the fallback. --%>
        <button
          id={"popup-host-frame-#{frame.frame_ref}-close"}
          type="button"
          phx-hook="PkpFrameClose"
          class="pkp-frame-close btn btn-ghost btn-sm btn-circle absolute right-6 top-6 z-20"
          {close_attrs(@on_close, frame)}
          aria-label={gettext("Close")}
          title={gettext("Close")}
        >
          <.icon name="hero-x-mark" class="w-5 h-5" />
        </button>
        <div
          class="pkp-offline absolute inset-x-6 bottom-3 z-30 items-center justify-center gap-2 rounded-box bg-warning/90 text-warning-content text-sm py-1.5 px-3"
          role="status"
        >
          <span class="loading loading-spinner loading-xs"></span>
          {gettext("Connection lost — reconnecting. Saving works again once it is back.")}
        </div>
        {render_slot(@frame, frame)}
      </.modal>
    </div>
    """
  end

  # The ✕: closes at once, or — while the frame's form holds unsaved
  # changes — asks first in the host's own dialog.
  defp close_attrs(on_close, %{frame_ref: ref} = frame) do
    if Map.get(frame, :closeable, true) == false do
      ConfirmAction.ask(on_close,
        title: gettext("Close without saving?"),
        message: gettext("What you changed since the last save is lost."),
        confirm: gettext("Discard"),
        "frame-ref": ref
      )
    else
      %{"phx-click" => on_close, "phx-value-frame-ref" => ref}
    end
  end

  # Which skeleton a frame shows while its LiveView joins: the shape of
  # what is coming, so the box opens at about its size.
  defp skeleton_kind(%{lv: PhoenixKitProjects.Web.AssignmentViewLive}), do: :view

  defp skeleton_kind(%{lv: lv})
       when lv in [
              PhoenixKitProjects.Web.AssignmentFormLive,
              PhoenixKitProjects.Web.ProjectFormLive,
              PhoenixKitProjects.Web.TaskFormLive,
              PhoenixKitProjects.Web.TemplateFormLive
            ],
       do: :form

  defp skeleton_kind(_frame), do: :generic

  attr(:kind, :atom, required: true)

  defp frame_skeleton(%{kind: :view} = assigns) do
    ~H"""
    <div class="pkp-skel" aria-hidden="true" data-pkp-skeleton="view">
      <div class="flex items-center gap-2 pr-10 h-7">
        <div class="skeleton h-5 w-14 rounded"></div>
        <div class="skeleton h-5 w-56"></div>
      </div>
      <div class="mt-5 grid gap-6 @2xl:grid-cols-[minmax(0,1fr)_15rem]">
        <div class="flex flex-col gap-3">
          <div class="skeleton h-4 w-24"></div>
          <div class="skeleton h-10 w-full"></div>
          <div class="flex gap-4 mt-2">
            <div class="skeleton h-5 w-24"></div>
            <div class="skeleton h-5 w-16"></div>
          </div>
          <div class="skeleton h-24 w-full"></div>
          <div class="flex items-start gap-3">
            <div class="skeleton h-7 w-7 rounded-full shrink-0"></div>
            <div class="flex-1 flex flex-col gap-2">
              <div class="skeleton h-3 w-32"></div>
              <div class="skeleton h-3 w-3/4"></div>
            </div>
          </div>
        </div>
        <div class="flex flex-col gap-3">
          <div class="skeleton h-4 w-full"></div>
          <div class="skeleton h-4 w-5/6"></div>
          <div class="skeleton h-4 w-2/3"></div>
        </div>
      </div>
    </div>
    """
  end

  defp frame_skeleton(%{kind: :form} = assigns) do
    ~H"""
    <div class="pkp-skel" aria-hidden="true" data-pkp-skeleton="form">
      <div class="flex items-center gap-2 pr-10 h-7">
        <div class="skeleton h-5 w-40"></div>
      </div>
      <div class="skeleton h-10 w-full mt-4 rounded-box"></div>
      <div class="mt-5 flex flex-col gap-4">
        <div class="skeleton h-10 w-full"></div>
        <div class="skeleton h-28 w-full"></div>
        <div class="flex gap-3">
          <div class="skeleton h-10 flex-1"></div>
          <div class="skeleton h-10 flex-1"></div>
        </div>
      </div>
      <div class="mt-6 flex justify-end gap-2">
        <div class="skeleton h-9 w-20"></div>
        <div class="skeleton h-9 w-28"></div>
      </div>
    </div>
    """
  end

  defp frame_skeleton(assigns) do
    ~H"""
    <div class="pkp-skel" aria-hidden="true" data-pkp-skeleton="generic">
      <div class="flex items-center gap-2 pr-10 h-7">
        <div class="skeleton h-5 w-48"></div>
      </div>
      <div class="mt-5 flex flex-col gap-3">
        <div class="skeleton h-4 w-full"></div>
        <div class="skeleton h-4 w-5/6"></div>
        <div class="skeleton h-4 w-2/3"></div>
      </div>
    </div>
    """
  end
end
