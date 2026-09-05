defmodule PhoenixKitProjects.Web.Widgets.RunningWidget do
  @moduledoc """
  Dashboard widget: the running projects in the Overview's order
  (`RunningTiers` — late first, then near done, on track, empty), each with
  its tier and progress. This is the Overview dashboard's "Running" list as
  a widget, so a dashboards-module board can replace that page.

  Views: `compact` (N-slot rows: name · tier · progress bar) / `cards` (the
  Overview's `running_card` outline with the sub-project breakdown, clipped
  at the box). Settings: `"limit"`, `"late_only"`.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitProjects.Gettext

  require Logger

  import PhoenixKitProjects.Web.Components.RunningCard
  import PhoenixKitProjects.Web.Widgets.Helpers

  alias PhoenixKitProjects.{L10n, Paths, Projects, RunningTiers}
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.Components.TierPill

  @default_limit 6

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, :id, assigns.id)

    if available?() do
      settings = assigns[:settings] || %{}
      limit = limit(settings)
      late_only? = settings["late_only"] in [true, "true"]
      {rows, total} = running_rows(assigns[:scope], limit, late_only?)

      {:ok,
       socket
       |> assign(:available, true)
       |> assign(:view, effective_view(assigns[:view], ~w(compact cards)))
       |> assign(:rows, rows)
       |> assign(:total, total)
       |> assign(:budget, limit)
       |> assign(:late_only?, late_only?)
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

  # Viewer-scoped at the query (never name a private project to a dashboard
  # reader), tree summaries tagged and ordered exactly like the Overview.
  defp running_rows(scope, limit, late_only?) do
    now = DateTime.utc_now()
    today = DateTime.to_date(now)

    summaries =
      Projects.list_active_projects(viewer: viewer_for(scope))
      |> Enum.map(&Projects.project_tree_summary/1)
      |> Enum.map(&RunningTiers.tag(&1, now))
      |> then(fn all -> if late_only?, do: Enum.filter(all, & &1.late), else: all end)

    RunningTiers.prioritize(summaries, today, now, limit)
  rescue
    e ->
      Logger.warning("[RunningWidget] running_rows failed: #{Exception.message(e)}")
      {[], 0}
  end

  @impl true
  def render(%{available: false} = assigns) do
    ~H"""
    <div class="contents">
      <.frame title={gettext("Running projects")} icon="hero-play-circle"><.unavailable /></.frame>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="contents">
      <.frame title={title(@late_only?)} icon="hero-play-circle" href={Paths.projects()}>
        <:actions>
          <span :if={@total > length(@rows)} class="text-xs text-base-content/40 tabular-nums">
            {length(@rows)}/{@total}
          </span>
        </:actions>
        <.empty
          :if={@rows == []}
          icon="hero-play-circle"
          message={
            if(@late_only?,
              do: gettext("Nothing is late."),
              else: gettext("Nothing running right now.")
            )
          }
        />
        <%!-- N-slot self-fit (dashboards contract): the box divides into
             `limit` fixed slots and each row's type scales to its slot. --%>
        <ul :if={@rows != [] and @view == "compact"} class="flex h-full min-h-0 flex-col divide-y divide-base-200">
          <li
            :for={s <- @rows}
            class="flex min-h-0 flex-1 items-center gap-2 overflow-hidden [container-type:size]"
          >
            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-2">
                <.link
                  navigate={Paths.project(s.project.uuid)}
                  class="truncate leading-tight hover:underline"
                  style={fit_text(11, "34cqh", 15)}
                >
                  {Project.localized_name(s.project, @lang)}
                </.link>
                <%!-- The tier as self-fitting text (a daisyUI badge has a
                     fixed height and would not follow the slot). --%>
                <span
                  class={["shrink-0 rounded-full px-[0.6em] py-[0.1em] font-medium leading-tight", tier_class(s.tier)]}
                  style={fit_text(8, "22cqh", 11)}
                >
                  {tier_label(s.tier)}
                </span>
              </div>
              <div class="pk-slot-meta mt-[2cqh] flex items-center gap-2">
                <progress
                  class={["progress h-[10cqh] min-h-1 flex-1", progress_class(s.tier)]}
                  value={s.progress_pct}
                  max="100"
                  aria-label={gettext("Progress")}
                >
                </progress>
                <span
                  class="shrink-0 leading-none tabular-nums text-base-content/60"
                  style={fit_text(9, "24cqh", 12)}
                >
                  {s.progress_pct}% · {s.task_done}/{s.task_total}
                </span>
              </div>
            </div>
          </li>
          <li :for={_pad <- 1..max(@budget - length(@rows), 0)//1} class="min-h-0 flex-1"></li>
        </ul>
        <div :if={@rows != [] and @view == "cards"} class="flex h-full min-h-0 flex-col gap-2 overflow-hidden">
          <.running_card :for={s <- @rows} node={s} tier={s.tier} lang={@lang} />
        </div>
      </.frame>
    </div>
    """
  end

  defp title(true), do: gettext("Late projects")
  defp title(false), do: gettext("Running projects")

  defp tier_class(:late), do: "bg-error/15 text-error"
  defp tier_class(:near_done), do: "bg-success/15 text-success"
  defp tier_class(:on_track), do: "bg-info/10 text-info"
  defp tier_class(:empty), do: "bg-base-200 text-base-content/50"

  defp tier_label(tier), do: elem(TierPill.pill_attrs(tier), 2)

  defp progress_class(:late), do: "progress-error"
  defp progress_class(:near_done), do: "progress-success"
  defp progress_class(_), do: "progress-primary"
end
