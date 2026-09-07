defmodule PhoenixKitProjects.Web.Components.PageHeader do
  @moduledoc """
  Section heading + description + action button row used by every
  admin LV in the projects module (Overview, Projects list, Tasks,
  Templates, Project show, every form).

  Every remaining caller is embeddable (`use PhoenixKitProjects.Web.Components`
  pages rendered either as a standalone routed admin page or nested via
  `live_render` inside a host page/drawer). When routed standalone
  (`embed_mode: :navigate`), core's admin layout already renders this same
  title in its breadcrumb bar from the LV's `page_title` assign — so pass
  `embed_mode` here and the title/description are suppressed to avoid
  showing it twice. In `:emit`/`:popup` mode (or when `embed_mode` is
  omitted) there's no breadcrumb chrome at all, so the title/description
  render as the page's only heading. `:back_link` and `:actions` always
  render regardless of mode — they're functional controls, not a title
  echo.

  ## Attributes

    * `embed_mode` — optional; when `:navigate`, suppresses the rendered
      title/description (already shown in the host breadcrumb). Omit or
      pass `:emit`/`:popup` to always render them.

  ## Slots

    * `:actions` — the action buttons rendered on the right side.
      Multiple action slots stack horizontally with `gap-2`.
    * `:back_link` — optional link rendered above the heading (the
      form-page "← back to list" pattern). When present the heading
      drops the description (forms typically don't have one).

  ## Examples

      # List-page header. Use `<.smart_link>` so the action button honors
      # the LV's `:embed_mode` (real <a href> in navigate mode, emit
      # broadcast in emit mode). See dev_docs/embedding_emit.md.
      <.page_header title="Projects" description="All projects.">
        <:actions>
          <.smart_link
            navigate={Paths.new_project()}
            emit={{PhoenixKitProjects.Web.ProjectFormLive, %{"live_action" => "new"}}}
            embed_mode={@embed_mode}
            class="btn btn-primary btn-sm"
          >
            New project
          </.smart_link>
        </:actions>
      </.page_header>

      # Form-page header (back-link variant).
      <.page_header title={@page_title}>
        <:back_link>
          <.smart_link
            navigate={Paths.projects()}
            emit={{PhoenixKitProjects.Web.ProjectsLive, %{}}}
            embed_mode={@embed_mode}
            class="link link-hover text-sm"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 inline" /> {gettext("Projects")}
          </.smart_link>
        </:back_link>
      </.page_header>
  """

  use Phoenix.Component

  attr(:title, :string, required: true)
  attr(:description, :string, default: nil)
  attr(:embed_mode, :atom, default: nil)

  slot(:actions)
  slot(:back_link)

  def page_header(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-4">
      <div>
        <div :if={@back_link != []}>{render_slot(@back_link)}</div>
        <%= if @embed_mode != :navigate do %>
          <h1 class={["text-2xl font-bold", @back_link != [] && "mt-1"]}>{@title}</h1>
          <p :if={@description} class="text-sm text-base-content/60 mt-1">{@description}</p>
        <% end %>
      </div>
      <div :if={@actions != []} class="flex flex-wrap gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end
end
