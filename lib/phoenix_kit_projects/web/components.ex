defmodule PhoenixKitProjects.Web.Components do
  @moduledoc """
  Aggregator for the projects module's reusable UI components.

  `use PhoenixKitProjects.Web.Components` brings every component
  function into the caller's scope so templates can write
  `<.page_header>` / `<.empty_state>` / etc. without per-LV imports.

  Components live in `web/components/*.ex`; this module just imports
  them. Component contracts are intentionally tight (typed attrs,
  named slots) so a future move into core's
  `PhoenixKitWeb.Components.*` namespace is mechanical when a sibling
  module needs to reuse one.
  """

  defmacro __using__(_opts) do
    quote do
      import PhoenixKitProjects.Web.Components.PageHeader
      import PhoenixKitProjects.Web.Components.EmptyState
      import PhoenixKitProjects.Web.Components.StatTile
      import PhoenixKitProjects.Web.Components.TierPill
      import PhoenixKitProjects.Web.Components.RunningCard
      import PhoenixKitProjects.Web.Components.SortableTable
      import PhoenixKitProjects.Web.Components.DerivedStatusBadge
      import PhoenixKitProjects.Web.Components.TabsStrip
      import PhoenixKitProjects.Web.Components.SmartLink
      import PhoenixKitProjects.Web.Components.SmartMenuLink
      import PhoenixKitProjects.Web.Components.PopupHost
    end
  end
end
