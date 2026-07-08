defmodule PhoenixKitProjects.Web.Widgets.ProjectScheduleWidget do
  @moduledoc """
  Dashboard widget: a single project's schedule/estimate — total estimated hours,
  progress, planned end, and a live ETA (with an on-track / late cue). Views:
  `detailed` / `simple`. Settings: `"project"`.
  """
  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitProjects.Web.Widgets.Helpers

  alias PhoenixKitProjects.{Paths, Projects}
  alias PhoenixKitProjects.Schemas.Project

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, :id, assigns.id)

    if available?() do
      project = resolve_project((assigns[:settings] || %{})["project"])

      {:ok,
       socket
       |> assign(:available, true)
       |> assign(:compact, compact?(assigns[:size]))
       |> assign(:project, project)
       |> assign(
         :view,
         effective_view(assigns[:view], ~w(detailed simple), small?(assigns[:size], 4, 2))
       )
       |> assign_schedule(project)}
    else
      {:ok, assign(socket, available: false, compact: false)}
    end
  end

  defp assign_schedule(socket, nil), do: assign(socket, summary: nil, eta: nil, late?: false)

  defp assign_schedule(socket, %Project{} = project) do
    now = DateTime.utc_now()
    summary = Projects.project_summary(project)

    remaining =
      if summary,
        do: max(summary.total_hours - summary.total_hours * summary.progress_pct / 100, 0.0),
        else: 0.0

    late? =
      summary && summary.planned_end && summary.progress_pct < 100 &&
        DateTime.compare(now, summary.planned_end) == :gt

    socket
    |> assign(:summary, summary)
    |> assign(
      :eta,
      if(project.started_at, do: Project.eta_from(project, now, remaining), else: nil)
    )
    |> assign(:late?, late? == true)
  end

  @impl true
  def render(%{available: false} = assigns) do
    ~H"""
    <div class="contents">
      <.frame compact={@compact} title={gettext("Schedule")} icon="hero-calendar-days"><.unavailable /></.frame>
    </div>
    """
  end

  def render(%{summary: nil} = assigns) do
    ~H"""
    <div class="contents">
      <.frame compact={@compact} title={gettext("Schedule")} icon="hero-calendar-days">
        <p class="text-sm text-base-content/50">{gettext("No project found.")}</p>
      </.frame>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="contents">
      <.frame compact={@compact} title={@project.name} icon="hero-calendar-days" href={Paths.project(@project.uuid)}>
      <div class="flex flex-col gap-2">
        <div>
          <div class="mb-0.5 flex items-center justify-between text-xs text-base-content/60">
            <span>{gettext("Progress")}</span>
            <span class="tabular-nums">{@summary.progress_pct}%</span>
          </div>
          <progress
            class={["progress h-2 w-full", if(@late?, do: "progress-error", else: "progress-primary")]}
            value={@summary.progress_pct}
            max="100"
          />
        </div>

        <div class="flex items-center gap-2 text-sm">
          <.icon name="hero-flag" class="h-4 w-4 text-base-content/40" />
          <span class="text-base-content/60">{gettext("ETA")}</span>
          <span class="ml-auto font-semibold tabular-nums">{date(@eta)}</span>
          <span :if={@late?} class="badge badge-error badge-sm gap-1">
            <.icon name="hero-exclamation-triangle" class="h-3 w-3" />{gettext("late")}
          </span>
        </div>

        <div :if={@view == "detailed"} class="grid grid-cols-2 gap-x-3 gap-y-1 text-xs">
          <.line label={gettext("Estimate")} value={hours(@summary.total_hours)} />
          <.line label={gettext("Planned end")} value={date(@summary.planned_end)} />
          <.line label={gettext("Tasks")} value={"#{@summary.done}/#{@summary.total}"} />
          <.line label={gettext("Sub-projects")} value={@summary.subproject_count} />
        </div>
      </div>
      </.frame>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)

  defp line(assigns) do
    ~H"""
    <div class="flex items-baseline justify-between gap-2">
      <span class="text-base-content/50">{@label}</span>
      <span class="font-medium tabular-nums">{@value}</span>
    </div>
    """
  end
end
