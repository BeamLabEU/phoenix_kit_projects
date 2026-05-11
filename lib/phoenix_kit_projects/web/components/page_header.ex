defmodule PhoenixKitProjects.Web.Components.PageHeader do
  @moduledoc """
  Section heading + description + action button row used by every
  admin LV in the projects module (Overview, Projects list, Tasks,
  Templates, Project show, every form).

  ## Slots

    * `:actions` — the action buttons rendered on the right side.
      Multiple action slots stack horizontally with `gap-2`.
    * `:back_link` — optional link rendered above the heading (the
      form-page "← back to list" pattern). When present the heading
      drops the description (forms typically don't have one).

  ## Examples

      # List-page header.
      <.page_header title="Projects" description="All projects.">
        <:actions>
          <.link navigate={Paths.new_project()} class="btn btn-primary btn-sm">
            New project
          </.link>
        </:actions>
      </.page_header>

      # Form-page header (back-link variant).
      <.page_header title={@page_title}>
        <:back_link>
          <.link navigate={Paths.projects()} class="link link-hover text-sm">
            <.icon name="hero-arrow-left" class="w-4 h-4 inline" /> {gettext("Projects")}
          </.link>
        </:back_link>
      </.page_header>
  """

  use Phoenix.Component

  attr :title, :string, required: true
  attr :description, :string, default: nil

  slot :actions
  slot :back_link

  def page_header(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-4">
      <div>
        <div :if={@back_link != []}>{render_slot(@back_link)}</div>
        <h1 class={["text-2xl font-bold", @back_link != [] && "mt-1"]}>{@title}</h1>
        <p :if={@description} class="text-sm text-base-content/60 mt-1">{@description}</p>
      </div>
      <div :if={@actions != []} class="flex flex-wrap gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end
end
