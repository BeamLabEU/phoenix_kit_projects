defmodule PhoenixKitProjects.Web.Components.SmartLink do
  @moduledoc """
  Embed-mode aware link.

  In **navigate mode** renders a plain `<.link navigate={...}>` — the
  browser sees a real `<a href>`, right-click-open-new-tab works, screen
  readers see a link, prefetch works.

  In **emit mode** renders a `<button phx-click="open_embed">` that
  fires the shared `open_embed` event (intercepted by the hook attached
  via `PhoenixKitProjects.Web.Helpers.attach_open_embed_hook/1` in each
  LV's `mount/3`). The hook validates the target LV against
  `Helpers.embeddable_lvs/0` and broadcasts `{:projects, :opened, %{lv,
  session, frame_ref}}` on the host topic.

  Use everywhere this module currently uses `<.link navigate={...}>` to
  another module LV.

  ## Example

      <.smart_link
        navigate={Paths.project(project.uuid)}
        emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => project.uuid}}}
        embed_mode={@embed_mode}
        class="link link-hover"
      >
        {Project.localized_name(project, lang)}
      </.smart_link>

  ## Why both attrs are required

  Even in emit mode, `navigate` is required as a fallback — if the
  whitelist rejects the target, the hook returns `{:cont, socket}` and
  the LV's own handler can fire, but most call sites simply have no
  handler, so the click is a no-op. A future tweak could make the hook
  fall back to `push_navigate(navigate)` in that case; for now,
  whitelist mismatches are surfaced via `Logger.warning` from the
  hook itself.
  """

  use Phoenix.Component

  attr(:navigate, :string, required: true)

  attr(:emit, :any,
    required: true,
    doc: "{TargetLV :: module(), session_overrides :: map()}"
  )

  attr(:embed_mode, :atom,
    default: :navigate,
    values: [:navigate, :emit],
    doc:
      "Socket's :embed_mode assign. Defaults to :navigate so LVs that haven't been " <>
        "converted yet (or that forget to pass it) get safe browser-navigation behaviour."
  )

  attr(:class, :string, default: nil)
  attr(:rest, :global, include: ~w(title aria-label data-id))

  slot(:inner_block, required: true)

  def smart_link(assigns) do
    {target_lv, session_overrides} = assigns.emit

    assigns =
      assigns
      |> assign(:lv_str, Atom.to_string(target_lv))
      |> assign(:session_json, Jason.encode!(session_overrides))

    ~H"""
    <.link
      :if={@embed_mode == :navigate}
      navigate={@navigate}
      class={@class}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    <button
      :if={@embed_mode == :emit}
      type="button"
      phx-click="open_embed"
      phx-value-lv={@lv_str}
      phx-value-session={@session_json}
      class={@class}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end
end
