defmodule PhoenixKitProjects.Web.Widgets.ProjectsBoardWidget do
  @moduledoc """
  Dashboard widget: every project at a glance, coloured by status.
  Views: `grid` (a uniform tile per project, tinted by lifecycle and
  attention-sorted — overdue first, completed last — with the workflow status
  as a second line) / `counts` (a bucket per workflow status with a count).
  No settings — shows all projects.
  """
  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitProjects.Gettext

  require Logger

  import PhoenixKitProjects.Web.Components.DerivedStatusBadge
  import PhoenixKitProjects.Web.Widgets.Helpers

  alias PhoenixKitProjects.{Paths, Statuses}
  alias PhoenixKitProjects.Schemas.Project

  # Attention-first tile order: what needs eyes sorts before what's fine.
  @lifecycle_rank %{overdue: 0, running: 1, setup: 2, scheduled: 3, completed: 4, archived: 5}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, :id, assigns.id)

    if available?() do
      projects = safe_list_projects()
      status_by = statuses_by_project(projects)

      tiles =
        projects
        |> Enum.map(fn p -> %{project: p, lifecycle: Project.derived_status(p)} end)
        |> Enum.sort_by(fn t -> {Map.get(@lifecycle_rank, t.lifecycle, 9), t.project.name} end)

      {:ok,
       socket
       |> assign(:available, true)
       |> assign(:view, effective_view(assigns[:view], ~w(grid counts)))
       |> assign(:projects, projects)
       |> assign(:tiles, tiles)
       |> assign(:status_by, status_by)
       |> assign(:buckets, buckets(projects, status_by))}
    else
      {:ok, assign(socket, :available, false)}
    end
  end

  defp statuses_by_project(projects) do
    if Statuses.available?(), do: Statuses.statuses_for_projects(projects), else: %{}
  rescue
    # Never crash the host dashboard: a transient DB error just drops the
    # workflow colours/buckets (tiles fall back to the neutral status).
    e ->
      Logger.warning("[ProjectsBoardWidget] statuses_by_project failed: #{Exception.message(e)}")
      %{}
  end

  # Group projects by their workflow status label (nil → "No status"), keeping a
  # representative status map (for the colour) + the count, ordered by count desc.
  defp buckets(projects, status_by) do
    projects
    |> Enum.group_by(fn p -> status_by[p.uuid] end)
    |> Enum.map(fn {status, ps} -> %{status: status, count: length(ps)} end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  @impl true
  def render(%{available: false} = assigns) do
    ~H"""
    <div class="contents">
      <.frame title={gettext("Projects board")} icon="hero-squares-2x2"><.unavailable /></.frame>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="contents">
      <.frame title={gettext("Projects board")} icon="hero-squares-2x2" href={Paths.projects()}>
      <.empty :if={@projects == []} icon="hero-squares-2x2" message={gettext("No projects yet.")} />

      <div :if={@view == "grid"} class="grid grid-cols-[repeat(auto-fill,minmax(9rem,1fr))] gap-1.5">
        <.link
          :for={t <- @tiles}
          navigate={Paths.project(t.project.uuid)}
          title={"#{t.project.name} · #{lifecycle_label(t.lifecycle)}"}
          class={["min-w-0 rounded-md px-2 py-1.5 transition-colors", tint(t.lifecycle)]}
        >
          <span class="flex min-w-0 items-center gap-1.5">
            <span class={["h-2 w-2 shrink-0 rounded-full", dot(t.lifecycle)]} aria-hidden="true" />
            <span class="truncate text-xs font-medium">{t.project.name}</span>
          </span>
          <span class="mt-0.5 flex min-w-0 items-center gap-1 pl-3.5">
            <span
              :if={workflow_color(@status_by[t.project.uuid] || %{})}
              class="h-1.5 w-1.5 shrink-0 rounded-full"
              style={"background-color: #{workflow_color(@status_by[t.project.uuid])}"}
              aria-hidden="true"
            />
            <span class="truncate text-[11px] text-base-content/50">
              {(@status_by[t.project.uuid] || %{})[:label] || lifecycle_label(t.lifecycle)}
            </span>
          </span>
        </.link>
      </div>

      <ul :if={@view == "counts"} class="flex flex-col gap-1">
        <li :for={b <- @buckets} class="flex items-center gap-2 text-sm">
          <.workflow_status_badge :if={b.status} status={b.status} />
          <span :if={is_nil(b.status)} class="badge badge-ghost badge-sm">{gettext("No status")}</span>
          <span class="ml-auto font-semibold tabular-nums">{b.count}</span>
        </li>
      </ul>
      </.frame>
    </div>
    """
  end

  # base-content tints keep completed/archived visually quiet; the loud colours
  # go to the states that need attention.
  defp tint(:overdue), do: "bg-error/10 hover:bg-error/20"
  defp tint(:running), do: "bg-success/10 hover:bg-success/20"
  defp tint(:setup), do: "bg-warning/10 hover:bg-warning/20"
  defp tint(:scheduled), do: "bg-info/10 hover:bg-info/20"
  defp tint(_quiet), do: "bg-base-200/60 hover:bg-base-200"

  defp dot(:overdue), do: "bg-error"
  defp dot(:running), do: "bg-success"
  defp dot(:setup), do: "bg-warning"
  defp dot(:scheduled), do: "bg-info"
  defp dot(_quiet), do: "bg-base-content/30"

  defp lifecycle_label(:overdue), do: gettext("overdue")
  defp lifecycle_label(:running), do: gettext("running")
  defp lifecycle_label(:setup), do: gettext("setup")
  defp lifecycle_label(:scheduled), do: gettext("scheduled")
  defp lifecycle_label(:completed), do: gettext("completed")
  defp lifecycle_label(:archived), do: gettext("archived")
  defp lifecycle_label(other), do: to_string(other)
end
