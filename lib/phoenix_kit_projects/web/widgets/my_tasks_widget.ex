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
       |> assign(:compact, compact?(assigns[:size]))
       |> assign(
         :view,
         effective_view(assigns[:view], ~w(detailed compact), small?(assigns[:size], 4, 2))
       )
       |> assign(:tasks, my_tasks(scope_user_uuid(assigns[:scope]), limit(settings)))}
    else
      {:ok, assign(socket, available: false, compact: false)}
    end
  end

  defp limit(settings) do
    case Integer.parse(to_string(settings["limit"] || "")) do
      {n, _} when n > 0 -> n
      _ -> @default_limit
    end
  end

  defp my_tasks(nil, _limit), do: []

  defp my_tasks(user_uuid, limit),
    do: user_uuid |> Projects.list_assignments_for_user() |> Enum.take(limit)

  @impl true
  def render(%{available: false} = assigns) do
    ~H"""
    <div class="contents">
      <.frame title={gettext("My tasks")} compact={@compact}><.unavailable /></.frame>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="contents">
      <.frame title={gettext("My tasks")} icon="hero-user-circle" compact={@compact}>
        <p :if={@tasks == []} class="text-sm text-base-content/50">
          {gettext("Nothing assigned to you right now.")}
        </p>

        <ul :if={@tasks != []} class="flex flex-col divide-y divide-base-200">
          <li :for={a <- @tasks} class="flex items-center gap-2 py-1.5">
            <span
              :if={@view == "compact"}
              class={["h-2 w-2 shrink-0 rounded-full", dot_class(a.status)]}
              aria-hidden="true"
            />
            <div class="min-w-0 flex-1">
              <.link
                navigate={Paths.project(a.project_uuid)}
                class="block truncate text-sm hover:underline"
              >
                {task_label(a)}
              </.link>
              <p :if={@view == "detailed" and a.project} class="truncate text-xs text-base-content/50">
                {a.project.name}
              </p>
            </div>
            <span
              :if={@view == "detailed" and a.track_progress}
              class="shrink-0 text-xs tabular-nums text-base-content/50"
            >
              {a.progress_pct}%
            </span>
            <.assignment_status_badge :if={@view == "detailed"} status={a.status} size="sm" />
          </li>
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
