defmodule PhoenixKitProjects.Web.Components.StatTile do
  @moduledoc """
  Compact bordered card with a label and a big number. Used in
  OverviewLive's top stats row (Running / Tasks in progress / Tasks
  todo / Tasks done) and in the bottom navigation row.

  Named `stat_tile` to avoid colliding with core's fancier
  `PhoenixKitWeb.Components.Core.StatCard.stat_card/1` (which takes
  title + subtitle + icon + color and renders a much larger card).
  This one is the minimum-chrome variant.

  ## Example

      <.stat_tile label="Running" value={@active_count} />
      <.stat_tile label="Tasks in progress" value={@in_progress} value_class="text-warning" />
  """

  use Phoenix.Component

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :value_class, :string, default: nil

  def stat_tile(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm border border-base-200">
      <div class="card-body p-3">
        <div class="text-xs text-base-content/60">{@label}</div>
        <div class={["text-2xl font-bold", @value_class]}>{@value}</div>
      </div>
    </div>
    """
  end
end
