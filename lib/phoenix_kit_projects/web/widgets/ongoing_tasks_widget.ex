defmodule PhoenixKitProjects.Web.Widgets.OngoingTasksWidget do
  @moduledoc """
  Dashboard widget: the current open (waiting, can be started, in progress)
  tasks of a project.
  Views: `detailed` (task, assignee, status, progress) / `compact` (task + status
  dot). Settings: `"project"` (name / id / substring) and `"limit"`.
  """
  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitProjects.Gettext

  require Logger

  import PhoenixKitProjects.Web.Components.AssignmentStatusBadge
  import PhoenixKitProjects.Web.Widgets.Helpers

  alias PhoenixKitProjects.{Paths, Projects}
  alias PhoenixKitProjects.People
  alias PhoenixKitProjects.People.Person
  alias PhoenixKitProjects.Schemas.Assignment

  @default_limit 6

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, :id, assigns.id)

    if available?() do
      settings = assigns[:settings] || %{}
      project = resolve_project(settings["project"], assigns[:scope])

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
    rows = Projects.list_assignments(project.uuid)
    by_uuid = Map.new(rows, &{&1.uuid, &1})

    # The limit goes to top-level tasks; a subtask takes a slot only when
    # it is somebody's or has a day of its own (it is otherwise read off
    # the task it sits under).
    rows
    |> Enum.filter(
      &(&1.status in ["waiting", "todo", "in_progress"] and
          (is_nil(&1.parent_uuid) or own_line?(&1)))
    )
    |> Enum.take(limit)
    |> Enum.map(&%{&1 | parent: &1.parent_uuid && Map.get(by_uuid, &1.parent_uuid)})
  rescue
    # Never crash the host dashboard: a transient DB error renders the
    # widget's empty state instead of taking down the host LiveView.
    e ->
      Logger.warning("[OngoingTasksWidget] ongoing_tasks failed: #{Exception.message(e)}")
      []
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

  defp own_line?(%Assignment{} = a) do
    not is_nil(a.assigned_person_uuid) or not is_nil(a.assigned_team_uuid) or
      not is_nil(a.assigned_department_uuid) or not is_nil(a.start_date) or not is_nil(a.end_date)
  end

  defp task_label(%Assignment{} = a), do: Assignment.label_under(a) || gettext("Untitled task")

  defp dot_class("in_progress"), do: "bg-warning"
  defp dot_class("done"), do: "bg-success"
  defp dot_class(_), do: "bg-base-300"

  defp assignee(%{assigned_team: %{name: n}}) when is_binary(n), do: n
  defp assignee(%{assigned_department: %{name: n}}) when is_binary(n), do: n
  defp assignee(%{assigned_person: %Person{} = p}), do: People.display_name(p)
  defp assignee(_), do: nil
end
