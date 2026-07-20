defmodule PhoenixKitProjects.Web.Widgets.ProjectStatusWidget do
  @moduledoc """
  Dashboard widget: the status of a single project — lifecycle + workflow status,
  progress, task counts, and a live ETA. Views: `detailed` / `simple` (auto-simple
  when small). Pick the project via the `"project"` setting (name / id / substring).
  """
  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitProjects.Gettext

  require Logger

  import PhoenixKitProjects.Web.Components.DerivedStatusBadge
  import PhoenixKitProjects.Web.Widgets.Helpers

  alias PhoenixKitProjects.{Paths, Statuses}
  alias PhoenixKitProjects.Schemas.Project

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, :id, assigns.id)

    if available?() do
      project = resolve_project((assigns[:settings] || %{})["project"])

      {:ok,
       socket
       |> assign(:available, true)
       |> assign(:project, project)
       |> assign(
         :view,
         effective_view(assigns[:view], ~w(detailed simple))
       )
       |> assign_project_data(project)}
    else
      {:ok, assign(socket, :available, false)}
    end
  end

  defp assign_project_data(socket, nil) do
    assign(socket, summary: nil, lifecycle: nil, wf_status: nil, eta: nil)
  end

  defp assign_project_data(socket, %Project{} = project) do
    summary = safe_project_summary(project)

    remaining =
      if summary,
        do: max(summary.total_hours - summary.total_hours * summary.progress_pct / 100, 0.0),
        else: 0.0

    socket
    |> assign(:summary, summary)
    |> assign(:lifecycle, Project.derived_status(project))
    |> assign(:wf_status, workflow_status(project))
    |> assign(
      :eta,
      if(project.started_at,
        do: Project.eta_from(project, DateTime.utc_now(), remaining),
        else: nil
      )
    )
  end

  defp workflow_status(project) do
    if Statuses.available?(), do: Statuses.current_status(project), else: nil
  rescue
    # Never crash the host dashboard: a transient DB error just drops the
    # workflow badge (the render already tolerates a nil status).
    e ->
      Logger.warning("[ProjectStatusWidget] workflow_status failed: #{Exception.message(e)}")
      nil
  end

  @impl true
  def render(%{available: false} = assigns) do
    ~H"""
    <div class="contents"><.frame title={gettext("Project status")}><.unavailable /></.frame></div>
    """
  end

  def render(%{project: nil} = assigns) do
    ~H"""
    <div class="contents">
      <.frame title={gettext("Project status")}>
        <.empty message={gettext("No project found — pick one in this widget's settings.")} />
      </.frame>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="contents">
      <.frame title={@project.name} href={Paths.project(@project.uuid)}>
      <div class="flex flex-col gap-2">
        <div class="flex flex-wrap items-center gap-1">
          <.project_status_badge project={@project} />
          <.workflow_status_badge :if={@wf_status} status={@wf_status} />
        </div>

        <div :if={@summary}>
          <div class="mb-0.5 flex items-center justify-between text-xs text-base-content/60">
            <span>{gettext("Progress")}</span>
            <span class="tabular-nums">{@summary.progress_pct}%</span>
          </div>
          <progress class="progress progress-primary h-2 w-full" value={@summary.progress_pct} max="100" />
        </div>

        <div :if={@view == "detailed" and @summary} class="grid grid-cols-2 gap-x-3 gap-y-1 text-xs">
          <.stat label={gettext("Tasks")} value={"#{@summary.done}/#{@summary.total}"} />
          <.stat label={gettext("In progress")} value={@summary.in_progress} />
          <.stat label={gettext("Estimate")} value={hours(@summary.total_hours)} />
          <.stat label={gettext("ETA")} value={date(@eta)} />
        </div>
      </div>
      </.frame>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)

  defp stat(assigns) do
    ~H"""
    <%!-- flex-wrap + min-w-0: in a narrow widget slot the 2-col grid track
         can't fit "label  2026-07-18" on one line — the value wraps under
         the label instead of being clipped at the card edge. --%>
    <div class="flex flex-wrap items-baseline justify-between gap-x-2 min-w-0">
      <span class="text-base-content/50">{@label}</span>
      <span class="font-medium tabular-nums">{@value}</span>
    </div>
    """
  end
end
