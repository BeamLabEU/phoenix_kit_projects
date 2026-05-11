defmodule PhoenixKitProjects.Web.Components.RunningCard do
  @moduledoc """
  One row in the dashboard's "Running" section — clickable link
  wrapping a title, tier pill, started-X-ago metadata, done/total
  counts, an in-progress note, and a colored progress bar.

  Driven by the `project_summary` map shape returned by
  `Projects.project_summaries/1`:

      %{
        project: %Project{},
        total: integer,
        done: integer,
        in_progress: integer,
        progress_pct: integer,
        total_hours: number,
        planned_end: DateTime.t() | nil
      }

  The caller passes the tier directly so the dashboard can reuse the
  same tier classifier it uses to sort + cap the list.

  ## Example

      <.running_card summary={s} tier={running_tier(s)} navigate={Paths.project(s.project.uuid)} lang={lang} />
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitProjects.Web.Components.TierPill

  alias PhoenixKitProjects.Schemas.Project

  attr :summary, :map, required: true
  attr :tier, :atom, required: true, values: [:late, :near_done, :on_track, :empty]
  attr :navigate, :string, required: true
  attr :lang, :string, default: nil

  def running_card(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="flex items-center gap-3 p-3 rounded hover:bg-base-200 transition"
    >
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2 min-w-0">
          <div class="font-medium truncate min-w-0">
            {Project.localized_name(@summary.project, @lang)}
          </div>
          <.tier_pill tier={@tier} />
        </div>
        <div class="flex items-center gap-2 text-xs text-base-content/60 mt-1">
          <span>{started_when_label(@summary.project)}</span>
          <span>·</span>
          <span>{gettext("%{done}/%{total} tasks", done: @summary.done, total: @summary.total)}</span>
          <%= if @summary.in_progress > 0 do %>
            <span>·</span>
            <span class="text-warning">{gettext("%{count} in progress", count: @summary.in_progress)}</span>
          <% end %>
        </div>
        <div class="w-full bg-base-300 rounded-full h-1.5 mt-2">
          <div
            class="bg-success h-1.5 rounded-full transition-all"
            style={"width: #{@summary.progress_pct}%"}
          />
        </div>
      </div>
      <div class="text-right shrink-0">
        <div class="text-lg font-bold">{@summary.progress_pct}%</div>
      </div>
    </.link>
    """
  end

  defp started_when_label(%{started_at: %DateTime{} = dt}) do
    days = Date.diff(DateTime.to_date(dt), Date.utc_today())
    gettext("Started %{when}", when: relative_day(days))
  end

  defp started_when_label(_), do: gettext("Not started yet")

  # Inlined here (rather than depending on a sibling LV's private
  # helper) so the component is self-contained — its only dependency
  # is `gettext`. Mirrors `OverviewLive.relative_day/1`.
  defp relative_day(0), do: gettext("today")
  defp relative_day(1), do: gettext("tomorrow")
  defp relative_day(-1), do: gettext("yesterday")

  defp relative_day(days) when days > 1 and days < 14,
    do: ngettext("in %{count} day", "in %{count} days", days)

  defp relative_day(days) when days > 1,
    do: gettext("in %{n} weeks", n: Float.round(days / 7, 1))

  defp relative_day(days) when days < 0 and days > -14,
    do: ngettext("%{count} day ago", "%{count} days ago", abs(days))

  defp relative_day(days),
    do: gettext("%{n} weeks ago", n: Float.round(abs(days) / 7, 1))
end
