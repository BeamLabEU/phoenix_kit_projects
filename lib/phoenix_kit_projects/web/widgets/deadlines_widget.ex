defmodule PhoenixKitProjects.Web.Widgets.DeadlinesWidget do
  @moduledoc """
  Dashboard widget: the running projects with the NEAREST planned ends —
  soonest first, overdue flagged — so slipping work surfaces on the dashboard
  before someone opens the projects page. Data comes from
  `Projects.project_summaries/1` (the same batched math as the overview:
  weekend-aware `planned_end`, progress %). Views: `detailed` (date, progress,
  late badge) / `compact` (name + date). Settings: `"limit"`.
  """
  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitProjects.Web.Widgets.Helpers

  alias PhoenixKitProjects.{Paths, Projects}

  @default_limit 6

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, :id, assigns.id)

    if available?() do
      settings = assigns[:settings] || %{}

      {:ok,
       socket
       |> assign(:available, true)
       |> assign(:compact, compact?(assigns[:size]))
       |> assign(
         :view,
         effective_view(assigns[:view], ~w(detailed compact), small?(assigns[:size], 4, 2))
       )
       |> assign(:rows, deadline_rows(limit(settings)))
       |> assign(:now, DateTime.utc_now())}
    else
      {:ok, assign(socket, available: false, compact: false)}
    end
  end

  defp limit(settings) do
    case Integer.parse(to_string(settings["limit"] || "")) do
      {n, _} when n > 0 -> n
      _ -> @default_limit
    end
  end

  # Started, unfinished projects with a computable planned end, soonest first.
  defp deadline_rows(limit) do
    Projects.list_active_projects()
    |> Projects.project_summaries()
    |> Enum.filter(&(&1.planned_end && &1.progress_pct < 100))
    |> Enum.sort_by(& &1.planned_end, DateTime)
    |> Enum.take(limit)
  rescue
    _ -> []
  end

  @impl true
  def render(%{available: false} = assigns) do
    ~H"""
    <div class="contents">
      <.frame title={gettext("Deadlines")} compact={@compact}><.unavailable /></.frame>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="contents">
      <.frame title={gettext("Deadlines")} icon="hero-flag" compact={@compact}>
        <p :if={@rows == []} class="text-sm text-base-content/50">
          {gettext("No running projects with a planned end.")}
        </p>

        <ul :if={@rows != []} class="flex flex-col divide-y divide-base-200">
          <li :for={row <- @rows} class="flex items-center gap-2 py-1.5">
            <div class="min-w-0 flex-1">
              <.link
                navigate={Paths.project(row.project.uuid)}
                class="block truncate text-sm hover:underline"
              >
                {row.project.name}
              </.link>
              <p :if={@view == "detailed"} class="text-xs tabular-nums text-base-content/50">
                {row.progress_pct}% · {row.done}/{row.total} {gettext("tasks")}
              </p>
            </div>
            <span class={[
              "shrink-0 text-xs tabular-nums",
              if(late?(row, @now), do: "font-medium text-error", else: "text-base-content/60")
            ]}>
              {date(row.planned_end)}
            </span>
            <span :if={late?(row, @now)} class="badge badge-error badge-xs gap-0.5 shrink-0">
              {gettext("late")}
            </span>
          </li>
        </ul>
      </.frame>
    </div>
    """
  end

  defp late?(%{planned_end: %DateTime{} = planned}, now),
    do: DateTime.compare(planned, now) == :lt

  defp late?(_row, _now), do: false
end
