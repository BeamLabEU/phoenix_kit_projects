defmodule PhoenixKitProjects.Web.Widgets.WorkloadWidget do
  @moduledoc """
  Dashboard widget: workspace-wide projects + task workload at a glance — project
  lifecycle counts (running / overdue / scheduled / completed) and assignment
  status counts (todo / in progress / done). Views: `detailed` / `simple`.
  """
  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitProjects.Web.Widgets.Helpers

  alias PhoenixKitProjects.{Paths, Projects}
  alias PhoenixKitProjects.Schemas.Project

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, :id, assigns.id)

    if available?() do
      projects = Projects.list_projects()
      lifecycle = Enum.frequencies_by(projects, &Project.derived_status/1)

      {:ok,
       socket
       |> assign(:available, true)
       |> assign(:compact, compact?(assigns[:size]))
       |> assign(
         :view,
         effective_view(assigns[:view], ~w(detailed simple), small?(assigns[:size], 4, 2))
       )
       |> assign(:total, length(projects))
       |> assign(:lifecycle, lifecycle)
       |> assign(:tasks, task_counts())}
    else
      {:ok, assign(socket, available: false, compact: false)}
    end
  end

  defp task_counts do
    Projects.assignment_status_counts()
  rescue
    _ -> %{"todo" => 0, "in_progress" => 0, "done" => 0}
  end

  @impl true
  def render(%{available: false} = assigns) do
    ~H"""
    <div class="contents">
      <.frame compact={@compact} title={gettext("Projects workload")} icon="hero-chart-pie"><.unavailable /></.frame>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="contents">
      <.frame compact={@compact} title={gettext("Projects workload")} icon="hero-chart-pie" href={Paths.projects()}>
      <div :if={@view == "simple"} class="grid grid-cols-2 gap-2">
        <.kpi label={gettext("Running")} value={count(@lifecycle, :running)} tone="text-success" />
        <.kpi
          label={gettext("Overdue")}
          value={count(@lifecycle, :overdue)}
          tone={if(count(@lifecycle, :overdue) > 0, do: "text-error", else: "text-base-content")}
        />
      </div>

      <div :if={@view == "detailed"} class="flex flex-col gap-2">
        <div>
          <p class="mb-1 text-xs font-semibold uppercase tracking-wide text-base-content/40">
            {gettext("Projects")} · {@total}
          </p>
          <div class="grid grid-cols-2 gap-x-3 gap-y-1 text-xs">
            <.line label={gettext("Running")} value={count(@lifecycle, :running)} />
            <.line label={gettext("Overdue")} value={count(@lifecycle, :overdue)} />
            <.line label={gettext("Scheduled")} value={count(@lifecycle, :scheduled)} />
            <.line label={gettext("Completed")} value={count(@lifecycle, :completed)} />
          </div>
        </div>
        <div>
          <p class="mb-1 text-xs font-semibold uppercase tracking-wide text-base-content/40">
            {gettext("Tasks")}
          </p>
          <div class="grid grid-cols-3 gap-x-3 text-xs">
            <.line label={gettext("Todo")} value={@tasks["todo"] || 0} />
            <.line label={gettext("Active")} value={@tasks["in_progress"] || 0} />
            <.line label={gettext("Done")} value={@tasks["done"] || 0} />
          </div>
        </div>
      </div>
      </.frame>
    </div>
    """
  end

  defp count(freqs, key), do: Map.get(freqs, key, 0)

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:tone, :string, default: "text-base-content")

  defp kpi(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center rounded bg-base-200/50 py-2">
      <span class={["text-2xl font-bold tabular-nums", @tone]}>{@value}</span>
      <span class="text-xs text-base-content/50">{@label}</span>
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
