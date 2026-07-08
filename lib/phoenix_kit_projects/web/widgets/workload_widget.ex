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

      <div :if={@view == "detailed"} class="flex h-full flex-col justify-center gap-2">
        <div>
          <p class="mb-1 text-xs font-semibold uppercase tracking-wide text-base-content/40">
            {gettext("Projects")} · {@total}
          </p>
          <div class="grid grid-cols-4 gap-1.5">
            <.kpi small label={gettext("Running")} value={count(@lifecycle, :running)} tone="text-success" />
            <.kpi
              small
              label={gettext("Overdue")}
              value={count(@lifecycle, :overdue)}
              tone={if(count(@lifecycle, :overdue) > 0, do: "text-error", else: "text-base-content/70")}
            />
            <.kpi small label={gettext("Scheduled")} value={count(@lifecycle, :scheduled)} tone="text-info" />
            <.kpi small label={gettext("Completed")} value={count(@lifecycle, :completed)} tone="text-base-content/70" />
          </div>
        </div>
        <div>
          <p class="mb-1 text-xs font-semibold uppercase tracking-wide text-base-content/40">
            {gettext("Tasks")}
          </p>
          <div class="grid grid-cols-3 gap-1.5">
            <.kpi small label={gettext("Todo")} value={@tasks["todo"] || 0} tone="text-base-content" />
            <.kpi small label={gettext("Active")} value={@tasks["in_progress"] || 0} tone="text-warning" />
            <.kpi small label={gettext("Done")} value={@tasks["done"] || 0} tone="text-success" />
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
  attr(:small, :boolean, default: false)

  defp kpi(assigns) do
    ~H"""
    <div class={[
      "flex flex-col items-center justify-center rounded bg-base-200/50",
      if(@small, do: "py-1.5", else: "py-2")
    ]}>
      <span class={[
        "font-bold tabular-nums",
        if(@small, do: "text-lg leading-6", else: "text-2xl"),
        @tone
      ]}>
        {@value}
      </span>
      <span class="text-[11px] text-base-content/50">{@label}</span>
    </div>
    """
  end
end
