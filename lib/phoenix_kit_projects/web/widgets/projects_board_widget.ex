defmodule PhoenixKitProjects.Web.Widgets.ProjectsBoardWidget do
  @moduledoc """
  Dashboard widget: every project at a glance, coloured by workflow status.
  Views: `grid` (a tile per project with its coloured status badge) / `counts`
  (a bucket per workflow status with a count). No settings — shows all projects.
  """
  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitProjects.Web.Components.DerivedStatusBadge
  import PhoenixKitProjects.Web.Widgets.Helpers

  alias PhoenixKitProjects.{Paths, Projects, Statuses}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, :id, assigns.id)

    if available?() do
      projects = Projects.list_projects()

      status_by =
        if Statuses.available?(), do: Statuses.statuses_for_projects(projects), else: %{}

      {:ok,
       socket
       |> assign(:available, true)
       |> assign(:compact, compact?(assigns[:size]))
       |> assign(:view, effective_view(assigns[:view], ~w(grid counts)))
       |> assign(:projects, projects)
       |> assign(:status_by, status_by)
       |> assign(:buckets, buckets(projects, status_by))}
    else
      {:ok, assign(socket, available: false, compact: false)}
    end
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
      <.frame compact={@compact} title={gettext("Projects board")} icon="hero-squares-2x2"><.unavailable /></.frame>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="contents">
      <.frame compact={@compact} title={gettext("Projects board")} icon="hero-squares-2x2" href={Paths.projects()}>
      <p :if={@projects == []} class="text-sm text-base-content/50">{gettext("No projects yet.")}</p>

      <div :if={@view == "grid"} class="flex flex-wrap gap-1.5">
        <.link
          :for={p <- @projects}
          navigate={Paths.project(p.uuid)}
          class="flex max-w-full items-center gap-1.5 rounded border border-base-200 px-2 py-1 hover:bg-base-200"
        >
          <span class="truncate text-xs font-medium">{p.name}</span>
          <.workflow_status_badge :if={@status_by[p.uuid]} status={@status_by[p.uuid]} />
          <.project_status_badge :if={is_nil(@status_by[p.uuid])} project={p} />
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
end
