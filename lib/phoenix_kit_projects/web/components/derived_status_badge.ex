defmodule PhoenixKitProjects.Web.Components.DerivedStatusBadge do
  @moduledoc """
  Badge that renders a project's `Project.derived_status/1` value as
  a daisyUI badge with the canonical icon + color + gettext'd label.

  Used in `ProjectsLive` (list view) but ready for reuse anywhere a
  project's lifecycle state needs a one-glance indicator.

  ## Example

      <.derived_status_badge state={Project.derived_status(project)} />
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon

  alias PhoenixKitProjects.Schemas.Project

  attr :state, :atom,
    required: true,
    values: [:running, :completed, :overdue, :scheduled, :setup, :archived, :template]

  def derived_status_badge(assigns) do
    ~H"""
    <span class={"badge badge-sm gap-1 #{badge_class(@state)}"}>
      <.icon name={icon_name(@state)} class="w-3 h-3" /> {label(@state)}
    </span>
    """
  end

  @doc "Convenience wrapper for the common pattern of badge'ing a project struct."
  attr :project, Project, required: true

  def project_status_badge(assigns) do
    assigns = assign(assigns, :state, Project.derived_status(assigns.project))

    ~H"""
    <.derived_status_badge state={@state} />
    """
  end

  defp label(:running), do: gettext("running")
  defp label(:completed), do: gettext("completed")
  defp label(:overdue), do: gettext("overdue")
  defp label(:scheduled), do: gettext("scheduled")
  defp label(:setup), do: gettext("setup")
  defp label(:archived), do: gettext("archived")
  defp label(:template), do: gettext("template")

  defp badge_class(:running), do: "badge-success"
  defp badge_class(:completed), do: "badge-success badge-outline"
  defp badge_class(:overdue), do: "badge-error"
  defp badge_class(:scheduled), do: "badge-info"
  defp badge_class(:setup), do: "badge-warning"
  defp badge_class(:archived), do: "badge-ghost"
  defp badge_class(:template), do: "badge-info badge-outline"

  defp icon_name(:running), do: "hero-play"
  defp icon_name(:completed), do: "hero-check-circle"
  defp icon_name(:overdue), do: "hero-exclamation-triangle"
  defp icon_name(:scheduled), do: "hero-calendar"
  defp icon_name(:setup), do: "hero-clock"
  defp icon_name(:archived), do: "hero-archive-box"
  defp icon_name(:template), do: "hero-document-duplicate"
end
