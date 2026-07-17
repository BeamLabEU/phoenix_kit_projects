defmodule PhoenixKitProjects.Web.Widgets.MyTasksWidget do
  @moduledoc """
  Dashboard widget: the CURRENT USER's open assignments across every active
  project — the personal "what's on my plate" view. Resolves the viewer through
  the host-provided `scope` assign → their staff person →
  `Projects.list_assignments_for_user/1` (which degrades gracefully on a Staff
  outage). Views: `detailed` (task, project, status, progress) / `compact`
  (task + status dot). Settings: `"limit"`.
  """
  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitProjects.Gettext

  require Logger

  import PhoenixKitProjects.Web.Components.AssignmentStatusBadge
  import PhoenixKitProjects.Web.Widgets.Helpers

  alias PhoenixKitProjects.{Paths, Projects}
  alias PhoenixKitProjects.Schemas.Assignment

  @default_limit 8

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, :id, assigns.id)

    if available?() do
      settings = assigns[:settings] || %{}

      {:ok,
       socket
       |> assign(:available, true)
       |> assign(
         :view,
         effective_view(assigns[:view], ~w(detailed compact))
       )
       |> assign(:tasks, my_tasks(scope_user_uuid(assigns[:scope]), limit(settings)))
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

  defp my_tasks(nil, _limit), do: []

  defp my_tasks(user_uuid, limit) do
    user_uuid |> Projects.list_assignments_for_user() |> Enum.take(limit)
  rescue
    # Never crash the host dashboard: ANY raise here (a transient DB error,
    # or a malformed viewer uuid escaping list_assignments_for_user/1's own
    # narrower rescue as an Ecto.Query.CastError) renders the widget's empty
    # state instead of taking down the host LiveView.
    e ->
      Logger.warning("[MyTasksWidget] my_tasks failed: #{Exception.message(e)}")
      []
  end

  @impl true
  def render(%{available: false} = assigns) do
    ~H"""
    <div class="contents">
      <.frame title={gettext("My tasks")}><.unavailable /></.frame>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="contents">
      <.frame title={gettext("My tasks")} icon="hero-user-circle">
        <.empty
          :if={@tasks == []}
          icon="hero-check-circle"
          message={gettext("Nothing assigned to you right now.")}
        />

        <%!-- N-SLOT self-fit: the box divides into the `limit` budget of
        slots; row type scales to its slot via cq units — always fits. --%>
        <ul :if={@tasks != []} class="flex h-full min-h-0 flex-col divide-y divide-base-200">
          <li
            :for={a <- @tasks}
            class="flex min-h-0 flex-1 items-center gap-2 overflow-hidden [container-type:size]"
          >
            <span
              :if={@view == "compact"}
              class={["h-[10cqh] w-[10cqh] shrink-0 rounded-full", dot_class(a.status)]}
              aria-hidden="true"
            />
            <div class="min-w-0 flex-1">
              <.link
                navigate={Paths.project(a.project_uuid)}
                class="block truncate leading-tight hover:underline"
                style={fit_text(11, "34cqh", 15)}
              >
                {task_label(a)}
              </.link>
              <p
                :if={@view == "detailed" and a.project}
                class="pk-slot-meta truncate leading-tight text-base-content/50"
                style={fit_text(9, "24cqh", 12)}
              >
                {a.project.name}
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
end
