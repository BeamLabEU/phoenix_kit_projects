defmodule PhoenixKitProjects.Web.Components.TierPill do
  @moduledoc """
  Status pill rendered next to a project title on the Running
  dashboard. Encodes the prioritized-tier classification:

    * `:late` — past `planned_end`, not done (red, exclamation)
    * `:near_done` — progress ≥ 75% (green, flag)
    * `:on_track` — has tasks, not late, not near-done (info, check)
    * `:empty` — no tasks yet (ghost, inbox)

  Use the `tier:` attr directly when the caller already knows the
  tier; for callers driving the pill off a summary map use the
  paired `tier_for_summary/1` helper from `OverviewLive`.

  ## Example

      <.tier_pill tier={:late} />
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Icon

  @type tier :: :late | :near_done | :on_track | :empty

  attr(:tier, :atom, required: true, values: [:late, :near_done, :on_track, :empty])

  def tier_pill(assigns) do
    {pill_class, pill_icon, pill_label} = pill_attrs(assigns.tier)

    assigns =
      assign(assigns, pill_class: pill_class, pill_icon: pill_icon, pill_label: pill_label)

    ~H"""
    <span class={"badge badge-xs gap-1 shrink-0 #{@pill_class}"}>
      <.icon name={@pill_icon} class="w-3 h-3" /> {@pill_label}
    </span>
    """
  end

  @doc "Returns the daisyUI class, heroicon name, and gettext'd label for a tier."
  @spec pill_attrs(tier()) :: {String.t(), String.t(), String.t()}
  def pill_attrs(:late), do: {"badge-error", "hero-exclamation-triangle", gettext("late")}
  def pill_attrs(:near_done), do: {"badge-success", "hero-flag", gettext("near done")}
  def pill_attrs(:on_track), do: {"badge-info badge-outline", "hero-check", gettext("on time")}
  def pill_attrs(:empty), do: {"badge-ghost", "hero-inbox", gettext("no tasks")}
end
