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
      projects = safe_list_projects()
      lifecycle = Enum.frequencies_by(projects, &Project.derived_status/1)

      {:ok,
       socket
       |> assign(:available, true)
       |> assign(
         :view,
         effective_view(assigns[:view], ~w(detailed simple))
       )
       |> assign(:total, length(projects))
       |> assign(:lifecycle, lifecycle)
       |> assign(:tasks, task_counts())}
    else
      {:ok, assign(socket, :available, false)}
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
      <.frame title={gettext("Projects workload")} icon="hero-chart-pie"><.unavailable /></.frame>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="contents">
      <.frame title={gettext("Projects workload")} icon="hero-chart-pie" href={Paths.projects()}>
      <%!-- Bands and KPI boxes self-fit via cq units — the whole body always
      fits its box (dashboards are one screenful: nothing scrolls or clips). --%>
      <div :if={@view == "simple"} class="grid h-full min-h-0 grid-cols-2 gap-2">
        <.kpi label={gettext("Running")} value={count(@lifecycle, :running)} tone="text-success" />
        <.kpi
          label={gettext("Overdue")}
          value={count(@lifecycle, :overdue)}
          tone={if(count(@lifecycle, :overdue) > 0, do: "text-error", else: "text-base-content")}
        />
      </div>

      <div :if={@view == "detailed"} class="flex h-full min-h-0 flex-col gap-[2cqh] [container-type:size]">
        <div class="flex min-h-0 flex-1 flex-col">
          <p
            class="mb-[1cqh] font-semibold uppercase leading-tight tracking-wide text-base-content/40"
            style={fit_text(9, "10cqh", 11)}
          >
            {gettext("Projects")} · {@total}
          </p>
          <div class="grid min-h-0 flex-1 grid-cols-4 gap-1.5">
            <.kpi small label={gettext("Running")} value={count(@lifecycle, :running)} tone="text-success" />
            <.kpi
              small
              label={gettext("Overdue")}
              value={count(@lifecycle, :overdue)}
              tone={if(count(@lifecycle, :overdue) > 0, do: "text-error", else: "text-base-content/70")}
            />
            <%!-- :scheduled (start planned for later) + :setup (immediate
                 start, not started yet) fold into one "Not started" tile so
                 the four tiles always sum to the headline total. --%>
            <.kpi
              small
              label={gettext("Not started")}
              value={count(@lifecycle, :scheduled) + count(@lifecycle, :setup)}
              tone="text-info"
            />
            <.kpi small label={gettext("Completed")} value={count(@lifecycle, :completed)} tone="text-base-content/70" />
          </div>
        </div>
        <div class="flex min-h-0 flex-1 flex-col">
          <p
            class="mb-[1cqh] font-semibold uppercase leading-tight tracking-wide text-base-content/40"
            style={fit_text(9, "10cqh", 11)}
          >
            {gettext("Tasks")}
          </p>
          <div class="grid min-h-0 flex-1 grid-cols-3 gap-1.5">
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
    <div class="flex min-h-0 flex-col items-center justify-center overflow-hidden rounded bg-base-200/50 [container-type:size]">
      <span class={["font-bold leading-none tabular-nums", @tone]} style={fit_text(14, "45cqh", 22)}>
        {@value}
      </span>
      <span class="truncate leading-tight text-base-content/50" style={fit_text(9, "20cqh", 11)}>
        {@label}
      </span>
    </div>
    """
  end
end
