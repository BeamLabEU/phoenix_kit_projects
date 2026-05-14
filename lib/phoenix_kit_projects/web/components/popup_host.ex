defmodule PhoenixKitProjects.Web.Components.PopupHost do
  @moduledoc """
  Layered daisyUI `<dialog>` modal stack driven by a `modal_stack`
  assign. The function component renders the always-visible content
  (default slot) plus one `<dialog>` per stack frame, delegating each
  frame's body rendering to the `:frame` slot the host provides.

  The host LV owns state — receiving `:opened` / `:closed` / `:saved` /
  `:deleted` PubSub events, pushing/popping the stack, generating
  `frame_ref`s. See `PhoenixKitProjects.Web.PopupHostLive` for the
  opinionated wrapper that does this automatically. Use the component
  directly when you need full control (e.g. modal-stack alongside other
  host state).

  Reuses the daisyUI modal pattern from `project_show_live.ex:1633-1662`
  — `<dialog open class="modal modal-open">` + ESC handler +
  modal-backdrop button.

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

  ## Z-index layering

  Each frame's `<dialog>` gets `z-[N]` where N starts at 50 (matches the
  start-project modal precedent) and increments by 10 per stack depth.
  Stack cap at 5 frames matches `PopupHostLive`'s `@max_stack_depth`.

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

  attr(:modal_stack, :list, required: true)
  attr(:on_close, :string, default: "close_top_modal")
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  slot :frame, required: true do
    attr(:any, :any)
  end

  def popup_host(assigns) do
    top_frame_ref =
      case List.last(assigns.modal_stack) do
        %{frame_ref: ref} -> ref
        _ -> nil
      end

    assigns = assign(assigns, :top_frame_ref, top_frame_ref)

    ~H"""
    <div class={@class}>
      {render_slot(@inner_block)}
      <dialog
        :for={{frame, depth} <- Enum.with_index(@modal_stack)}
        open
        class="modal modal-open"
        style={"z-index: #{50 + depth * 10}"}
        phx-window-keydown={frame.frame_ref == @top_frame_ref && @on_close}
        phx-key={frame.frame_ref == @top_frame_ref && "Escape"}
        phx-value-frame-ref={frame.frame_ref}
        data-frame-ref={frame.frame_ref}
      >
        <div class="modal-box max-w-4xl">
          {render_slot(@frame, frame)}
        </div>
        <button
          type="button"
          phx-click={@on_close}
          phx-value-frame-ref={frame.frame_ref}
          class="modal-backdrop"
          aria-label="Close"
        ></button>
      </dialog>
    </div>
    """
  end
end
