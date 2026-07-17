defmodule PhoenixKitProjects.Web.Widgets.OngoingTasksWidget do
  @moduledoc """
  Dashboard widget: the current ongoing (todo + in-progress) tasks of a project.
  Views: `detailed` (task, assignee, status, progress) / `compact` (task + status
  dot). Settings: `"project"` (name / id / substring) and `"limit"`.
  """
  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitProjects.Web.Components.AssignmentStatusBadge
  import PhoenixKitProjects.Web.Widgets.Helpers

  alias PhoenixKitProjects.{Paths, Projects}
  alias PhoenixKitProjects.Schemas.Assignment
  alias PhoenixKitStaff.Schemas.Person

  @default_limit 6

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, :id, assigns.id)

    if available?() do
      settings = assigns[:settings] || %{}
      project = resolve_project(settings["project"])

      {:ok,
       socket
       |> assign(:available, true)
       |> assign(:project, project)
       |> assign(
         :view,
         effective_view(assigns[:view], ~w(detailed compact))
       )
       |> assign(:tasks, ongoing_tasks(project, limit(settings)))
       |> assign(:budget, limit(settings))}
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

  defp ongoing_tasks(nil, _limit), do: []

  defp ongoing_tasks(project, limit) do
    project.uuid
    |> Projects.list_assignments()
    |> Enum.filter(&(&1.status in ["todo", "in_progress"]))
    |> Enum.take(limit)
  rescue
    # Never crash the host dashboard: a transient DB error renders the
    # widget's empty state instead of taking down the host LiveView.
    _ -> []
  end

  @impl true
  def render(%{available: false} = assigns) do
    ~H"""
    <div class="contents"><.frame title={gettext("Ongoing tasks")}><.unavailable /></.frame></div>
    """
  end

  def render(%{project: nil} = assigns) do
    ~H"""
    <div class="contents">
      <.frame title={gettext("Ongoing tasks")}>
        <.empty message={gettext("No project found — pick one in this widget's settings.")} />
      </.frame>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="contents">
      <.frame title={gettext("Ongoing — %{name}", name: @project.name)} href={Paths.project(@project.uuid)}>
      <.empty :if={@tasks == []} icon="hero-check-circle" message={gettext("No ongoing tasks. 🎉")} />
      <%!-- N-SLOT self-fit: `limit` budget of slots; cq row type. --%>
      <ul :if={@tasks != []} class="flex h-full min-h-0 flex-col divide-y divide-base-200">
        <li
          :for={a <- @tasks}
          class="flex min-h-0 flex-1 items-center gap-2 overflow-hidden [container-type:size]"
        >
          <span
            :if={@view == "compact"}
            class={["h-[10cqh] w-[10cqh] shrink-0 rounded-full", dot_class(a.status)]}
          />
          <div class="min-w-0 flex-1">
            <p class="truncate leading-tight" style={fit_text(11, "34cqh", 15)}>
              {task_label(a)}
            </p>
            <p
              :if={@view == "detailed" and assignee(a)}
              class="pk-slot-meta truncate leading-tight text-base-content/50"
              style={fit_text(9, "24cqh", 12)}
            >
              {assignee(a)}
            </p>
          </div>
          <span
            :if={@view == "detailed" and a.track_progress}
            class="shrink-0 leading-none tabular-nums text-base-content/50"
            style={fit_text(10, "26cqh", 13)}
          >
            {a.progress_pct}%
          </span>
          <.assignment_status_badge :if={@view == "detailed"} status={a.status} size="sm" />
        </li>
        <li :for={_pad <- 1..max(@budget - length(@tasks), 0)//1} class="min-h-0 flex-1"></li>
      </ul>
      </.frame>
    </div>
    """
  end

  defp task_label(%Assignment{} = a), do: Assignment.label(a) || gettext("Untitled task")

  defp dot_class("in_progress"), do: "bg-warning"
  defp dot_class("done"), do: "bg-success"
  defp dot_class(_), do: "bg-base-300"

  defp assignee(%{assigned_team: %{name: n}}) when is_binary(n), do: n
  defp assignee(%{assigned_department: %{name: n}}) when is_binary(n), do: n
  defp assignee(%{assigned_person: %Person{} = p}), do: Person.display_name(p)
  defp assignee(_), do: nil
end
