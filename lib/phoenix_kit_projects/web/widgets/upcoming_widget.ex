defmodule PhoenixKitProjects.Web.Widgets.UpcomingWidget do
  @moduledoc """
  Dashboard widget: the Overview's side column — projects still in setup
  (immediate start, not started yet), projects scheduled to start later,
  and the most recently completed ones. Views: `upcoming` (setup +
  scheduled, soonest first) / `completed` (newest first). Settings:
  `"limit"`.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitProjects.Gettext

  require Logger

  import PhoenixKitProjects.Web.Widgets.Helpers

  alias PhoenixKitProjects.{L10n, Paths, Projects}
  alias PhoenixKitProjects.Schemas.Project

  @default_limit 6

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, :id, assigns.id)

    if available?() do
      settings = assigns[:settings] || %{}
      limit = limit(settings)
      view = effective_view(assigns[:view], ~w(upcoming completed))

      {:ok,
       socket
       |> assign(:available, true)
       |> assign(:view, view)
       |> assign(:rows, rows(view, assigns[:scope], limit))
       |> assign(:budget, limit)
       |> assign(:today, Date.utc_today())
       |> assign(:lang, L10n.current_content_lang())}
    else
      {:ok, assign(socket, :available, false)}
    end
  end

  defp limit(settings) do
    case Integer.parse(to_string(settings["limit"] || "")) do
      {n, _} when n > 0 -> n
      _ -> @default_limit
    end
  end

  # Viewer-scoped at the query — see `Helpers.viewer_for/1`.
  defp rows("completed", scope, limit) do
    limit
    |> Projects.list_recently_completed_projects(viewer: viewer_for(scope))
    |> Enum.map(&{:completed, &1})
  rescue
    e ->
      Logger.warning("[UpcomingWidget] completed rows failed: #{Exception.message(e)}")
      []
  end

  defp rows(_upcoming, scope, limit) do
    viewer = viewer_for(scope)
    setup = Projects.list_setup_projects(viewer: viewer) |> Enum.map(&{:setup, &1})

    # Already soonest-first from the query.
    scheduled = Projects.list_upcoming_projects(viewer: viewer) |> Enum.map(&{:scheduled, &1})

    Enum.take(setup ++ scheduled, limit)
  rescue
    e ->
      Logger.warning("[UpcomingWidget] upcoming rows failed: #{Exception.message(e)}")
      []
  end

  @impl true
  def render(%{available: false} = assigns) do
    ~H"""
    <div class="contents">
      <.frame title={gettext("Upcoming projects")} icon="hero-calendar"><.unavailable /></.frame>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="contents">
      <.frame title={title(@view)} icon={icon(@view)} href={Paths.projects()}>
        <.empty
          :if={@rows == []}
          icon={icon(@view)}
          message={
            if(@view == "completed",
              do: gettext("Nothing completed yet."),
              else: gettext("Nothing scheduled or in setup.")
            )
          }
        />
        <ul :if={@rows != []} class="flex h-full min-h-0 flex-col divide-y divide-base-200">
          <li
            :for={{kind, p} <- @rows}
            class="flex min-h-0 flex-1 items-center gap-2 overflow-hidden [container-type:size]"
          >
            <span class={["shrink-0", tone(kind)]} style={fit_text(9, "22cqh", 12)}>{label(kind)}</span>
            <.link
              navigate={Paths.project(p.uuid)}
              class="min-w-0 flex-1 truncate leading-tight hover:underline"
              style={fit_text(11, "34cqh", 15)}
            >
              {Project.localized_name(p, @lang)}
            </.link>
            <span
              class="pk-slot-meta shrink-0 leading-none tabular-nums text-base-content/60"
              style={fit_text(9, "24cqh", 12)}
            >
              {when_text(kind, p, @today)}
            </span>
          </li>
          <li :for={_pad <- 1..max(@budget - length(@rows), 0)//1} class="min-h-0 flex-1"></li>
        </ul>
      </.frame>
    </div>
    """
  end

  defp title("completed"), do: gettext("Recently completed")
  defp title(_), do: gettext("Upcoming projects")

  defp icon("completed"), do: "hero-trophy"
  defp icon(_), do: "hero-calendar"

  defp label(:setup), do: gettext("setup")
  defp label(:scheduled), do: gettext("scheduled")
  defp label(:completed), do: gettext("done")

  defp tone(:setup), do: "text-warning"
  defp tone(:scheduled), do: "text-info"
  defp tone(:completed), do: "text-success"

  defp when_text(:setup, _p, _today), do: gettext("not started")

  defp when_text(:scheduled, %{scheduled_start_date: %DateTime{} = at}, today),
    do: relative_days(Date.diff(DateTime.to_date(at), today))

  defp when_text(:completed, %{completed_at: %DateTime{} = at}, today),
    do: relative_days(Date.diff(DateTime.to_date(at), today))

  defp when_text(_, _, _), do: "—"

  defp relative_days(0), do: gettext("today")
  defp relative_days(1), do: gettext("tomorrow")
  defp relative_days(-1), do: gettext("yesterday")
  defp relative_days(n) when n > 0, do: gettext("in %{count} days", count: n)
  defp relative_days(n), do: gettext("%{count} days ago", count: -n)
end
