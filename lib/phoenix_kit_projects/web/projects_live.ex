defmodule PhoenixKitProjects.Web.ProjectsLive do
  @moduledoc "List projects."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitProjects.{Activity, Paths, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: ProjectsPubSub.subscribe(ProjectsPubSub.topic_all())
    {:ok, assign(socket, page_title: gettext("Projects"), status: "") |> load_projects()}
  end

  @impl true
  def handle_info({:projects, _event, _payload}, socket), do: {:noreply, load_projects(socket)}

  def handle_info(msg, socket) do
    Logger.debug("[ProjectsLive] unexpected handle_info: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp load_projects(socket) do
    assign(socket, projects: Projects.list_projects(status: socket.assigns.status))
  end

  @impl true
  def handle_event("filter", %{"status" => s}, socket) do
    {:noreply, socket |> assign(status: s) |> load_projects()}
  end

  def handle_event("delete", %{"uuid" => uuid}, socket) do
    case Projects.get_project(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Project not found."))}

      project ->
        case Projects.delete_project(project) do
          {:ok, _} ->
            log_and_flash_deleted(socket, project)

          {:error, _} ->
            Activity.log_failed("projects.project_deleted",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "project",
              resource_uuid: project.uuid,
              metadata: %{"name" => project.name}
            )

            {:noreply, put_flash(socket, :error, gettext("Could not delete project."))}
        end
    end
  end

  defp project_status_label("active"), do: gettext("active")
  defp project_status_label("archived"), do: gettext("archived")
  defp project_status_label(other), do: other

  defp log_and_flash_deleted(socket, project) do
    Activity.log("projects.project_deleted",
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: "project",
      resource_uuid: project.uuid,
      metadata: %{"name" => project.name}
    )

    {:noreply, socket |> put_flash(:info, gettext("Project deleted.")) |> load_projects()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-4">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">{gettext("Projects")}</h1>
          <p class="text-sm text-base-content/60">{gettext("All projects.")}</p>
        </div>
        <.link navigate={Paths.new_project()} class="btn btn-primary btn-sm">
          <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New project")}
        </.link>
      </div>

      <div class="bg-base-200 rounded-lg p-3">
        <.form for={%{}} phx-change="filter" class="flex gap-3 items-end">
          <.select
            name="status"
            label={gettext("Status")}
            value={@status}
            options={[{gettext("All"), ""}, {gettext("Active"), "active"}, {gettext("Archived"), "archived"}]}
          />
        </.form>
      </div>

      <%= if @projects == [] do %>
        <div class="text-center py-16 text-base-content/60">
          <.icon name="hero-clipboard-document-list" class="w-12 h-12 mx-auto mb-2 opacity-40" />
          <p>{gettext("No projects match.")}</p>
        </div>
      <% else %>
        <div class="card bg-base-100 shadow">
          <div class="card-body p-0">
            <table class="table">
              <thead>
                <tr>
                  <th>{gettext("Name")}</th>
                  <th>{gettext("Status")}</th>
                  <th class="text-right">{gettext("Actions")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={p <- @projects} class="hover">
                  <td>
                    <.link navigate={Paths.project(p.uuid)} class="link link-hover font-medium">
                      {p.name}
                    </.link>
                    <%= if p.completed_at do %>
                      <span class="badge badge-success badge-xs ml-2">
                        <.icon name="hero-check-circle" class="w-3 h-3" /> {gettext("completed")}
                      </span>
                    <% end %>
                    <div :if={p.description} class="text-xs text-base-content/60 truncate max-w-md">
                      {p.description}
                    </div>
                  </td>
                  <td>
                    <span class={"badge badge-sm #{if p.status == "active", do: "badge-success", else: "badge-ghost"}"}>
                      {project_status_label(p.status)}
                    </span>
                  </td>
                  <td class="text-right">
                    <.link navigate={Paths.edit_project(p.uuid)} class="btn btn-ghost btn-xs">
                      <.icon name="hero-pencil" class="w-3.5 h-3.5" />
                    </.link>
                    <button
                      type="button"
                      phx-click="delete"
                      phx-value-uuid={p.uuid}
                      phx-disable-with={gettext("Deleting…")}
                      data-confirm={gettext("Delete project \"%{name}\"? All assignments will be removed.", name: p.name)}
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
