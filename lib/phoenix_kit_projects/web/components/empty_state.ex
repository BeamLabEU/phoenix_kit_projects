defmodule PhoenixKitProjects.Web.Components.EmptyState do
  @moduledoc """
  Centered icon + heading + optional sub-text + optional CTA. Used in
  every list view ("No projects yet.", "No templates yet.", "No tasks
  assigned to you right now.").

  ## Slots

    * `:cta` — optional call-to-action element (typically a `<.link>`
      or button) rendered below the description.

  ## Example

      <.empty_state icon="hero-clipboard-document-list" title="No projects yet.">
        <:cta>
          <.smart_link
            navigate={Paths.new_project()}
            emit={{PhoenixKitProjects.Web.ProjectFormLive, %{"live_action" => "new"}}}
            embed_mode={@embed_mode}
            class="btn btn-primary btn-xs"
          >
            <.icon name="hero-plus" class="w-3.5 h-3.5" /> New project
          </.smart_link>
        </:cta>
      </.empty_state>
  """

  use Phoenix.Component
  import PhoenixKitWeb.Components.Core.Icon

  attr(:icon, :string, default: "hero-clipboard-document-list")
  attr(:title, :string, required: true)
  attr(:description, :string, default: nil)
  attr(:class, :string, default: "py-16")

  slot(:cta)

  def empty_state(assigns) do
    ~H"""
    <div class={"text-center text-base-content/60 #{@class}"}>
      <.icon name={@icon} class="w-12 h-12 mx-auto mb-2 opacity-40" />
      <p class="text-sm font-medium">{@title}</p>
      <p :if={@description} class="text-xs text-base-content/50 mt-1">{@description}</p>
      <div :if={@cta != []} class="mt-3">
        {render_slot(@cta)}
      </div>
    </div>
    """
  end
end
