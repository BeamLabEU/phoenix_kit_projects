defmodule PhoenixKitProjects.Web.TasksLive do
  @moduledoc "List reusable task templates."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitProjects.{Activity, Paths, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: ProjectsPubSub.subscribe(ProjectsPubSub.topic_tasks())
    {:ok, assign(socket, page_title: gettext("Task Library")) |> load_tasks()}
  end

  defp load_tasks(socket), do: assign(socket, tasks: Projects.list_tasks())

  @impl true
  def handle_info({:projects, _event, _payload}, socket) do
    {:noreply, load_tasks(socket)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[TasksLive] unexpected handle_info: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("delete", %{"uuid" => uuid}, socket) do
    case Projects.get_task(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Task not found."))}

      task ->
        case Projects.delete_task(task) do
          {:ok, _} ->
            Activity.log("projects.task_deleted",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "task",
              resource_uuid: task.uuid,
              metadata: %{"title" => task.title}
            )

            {:noreply, socket |> put_flash(:info, gettext("Task deleted.")) |> load_tasks()}

          {:error, _} ->
            Activity.log_failed("projects.task_deleted",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "task",
              resource_uuid: task.uuid,
              metadata: %{"title" => task.title}
            )

            {:noreply, put_flash(socket, :error, gettext("Could not delete task."))}
        end
    end
  end

  defp format_duration(task) do
    PhoenixKitProjects.Schemas.Task.format_duration(
      task.estimated_duration,
      task.estimated_duration_unit
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-4">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">{gettext("Task Library")}</h1>
          <p class="text-sm text-base-content/60">{gettext("Reusable task templates.")}</p>
        </div>
        <.link navigate={Paths.new_task()} class="btn btn-primary btn-sm">
          <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New task")}
        </.link>
      </div>

      <%= if @tasks == [] do %>
        <div class="text-center py-16 text-base-content/60">
          <.icon name="hero-rectangle-stack" class="w-12 h-12 mx-auto mb-2 opacity-40" />
          <p>{gettext("No tasks yet.")}</p>
          <.link navigate={Paths.new_task()} class="link link-primary text-sm">{gettext("Create your first")}</.link>
        </div>
      <% else %>
        <div class="card bg-base-100 shadow">
          <div class="card-body p-0">
            <table class="table">
              <thead>
                <tr>
                  <th>{gettext("Title")}</th>
                  <th>{gettext("Duration")}</th>
                  <th class="text-right">{gettext("Actions")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={task <- @tasks} class="hover">
                  <td>
                    <div class="font-medium">{task.title}</div>
                    <div :if={task.description} class="text-xs text-base-content/60 truncate max-w-md">
                      {task.description}
                    </div>
                  </td>
                  <td>{format_duration(task)}</td>
                  <td class="text-right">
                    <.link navigate={Paths.edit_task(task.uuid)} class="btn btn-ghost btn-xs">
                      <.icon name="hero-pencil" class="w-3.5 h-3.5" />
                    </.link>
                    <button
                      type="button"
                      phx-click="delete"
                      phx-value-uuid={task.uuid}
                      phx-disable-with={gettext("Deleting…")}
                      data-confirm={gettext("Delete task \"%{title}\"? Assignments using it will also be removed.", title: task.title)}
                      class="btn btn-ghost btn-xs text-error"
                    >
                      <.icon name="hero-trash" class="w-3.5 h-3.5" />
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
