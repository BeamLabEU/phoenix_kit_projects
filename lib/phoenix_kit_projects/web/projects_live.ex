defmodule PhoenixKitProjects.Web.ProjectsLive do
  @moduledoc "List projects."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKitProjects.{Activity, L10n, Paths, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Project

  require Logger

  # Default wrapper class for the standalone admin page. Embedders can
  # override via `live_render(... session: %{"wrapper_class" => "..."})`.
  @default_wrapper_class "flex flex-col mx-auto max-w-5xl px-4 py-6 gap-4"

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: ProjectsPubSub.subscribe(ProjectsPubSub.topic_all())

    wrapper_class = Map.get(session, "wrapper_class", @default_wrapper_class)

    socket =
      assign(socket,
        page_title: gettext("Projects"),
        wrapper_class: wrapper_class,
        show: "visible",
        projects: []
      )

    # Skeleton defaults keep the disconnected render cheap; the actual
    # list loads on connected mount. `handle_params/3` is intentionally
    # absent — see dev_docs/embedding_audit.md.
    {:ok, if(connected?(socket), do: load_projects(socket), else: socket)}
  end

  @impl true
  def handle_info({:projects, _event, _payload}, socket), do: {:noreply, load_projects(socket)}

  def handle_info(msg, socket) do
    Logger.debug("[ProjectsLive] unexpected handle_info: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp load_projects(socket) do
    assign(socket, projects: Projects.list_projects(archived: archived_opt(socket.assigns.show)))
  end

  defp archived_opt("archived"), do: true
  defp archived_opt("all"), do: :all
  defp archived_opt(_visible), do: false

  @impl true
  def handle_event("filter", %{"show" => s}, socket) do
    {:noreply, socket |> assign(show: s) |> load_projects()}
  end

  def handle_event("reorder_projects", %{"ordered_ids" => ordered_ids} = params, socket)
      when is_list(ordered_ids) do
    moved_id = params["moved_id"]

    case Projects.reorder_projects(ordered_ids, actor_uuid: Activity.actor_uuid(socket)) do
      :ok ->
        {:noreply,
         socket
         |> push_event("sortable:flash", %{uuid: moved_id, status: "ok"})
         |> load_projects()}

      {:error, :too_many_uuids} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Too many projects to reorder at once."))
         |> push_event("sortable:flash", %{uuid: moved_id, status: "error"})
         |> load_projects()}

      {:error, :wrong_scope} ->
        # The user dropped a row from a list that isn't a regular
        # project bucket — usually a stale view racing a flag flip.
        # Reload to snap back to truth.
        {:noreply,
         socket
         |> put_flash(:error, gettext("Project list changed; please try again."))
         |> push_event("sortable:flash", %{uuid: moved_id, status: "error"})
         |> load_projects()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Could not reorder projects."))
         |> push_event("sortable:flash", %{uuid: moved_id, status: "error"})
         |> load_projects()}
    end
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

  defp log_and_flash_deleted(socket, project) do
    # Activity log captures the primary-language name (audit trail is
    # locale-agnostic; primary is the canonical identifier for the row).
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
    <div class={@wrapper_class}>
      <.page_header title={gettext("Projects")} description={gettext("All projects.")}>
        <:actions>
          <.link navigate={Paths.new_project()} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New project")}
          </.link>
        </:actions>
      </.page_header>

      <div class="bg-base-200 rounded-lg p-3">
        <.form for={%{}} phx-change="filter" class="flex gap-3 items-end">
          <.select
            name="show"
            label={gettext("Show")}
            value={@show}
            options={[
              {gettext("Active only"), "visible"},
              {gettext("Archived only"), "archived"},
              {gettext("All"), "all"}
            ]}
          />
        </.form>
      </div>

      <%= if @projects == [] do %>
        <.empty_state icon="hero-clipboard-document-list" title={gettext("No projects match.")} />
      <% else %>
        <%!-- DnD only applies when the user is viewing the visible
             (non-archived) bucket — reordering a filtered subset
             would write inconsistent positions for the projects that
             aren't currently visible. The hook is gated on
             `@show == "visible"`; archived/all views render without
             the SortableGrid hook (drag handle hidden too). --%>
        <% lang = L10n.current_content_lang() %>
        <.sortable_table
          id="projects-list-body"
          rows={@projects}
          row_id={& &1.uuid}
          event="reorder_projects"
          draggable={@show == "visible"}
        >
          <:col :let={p} label={gettext("Name")}>
            <.link navigate={Paths.project(p.uuid)} class="link link-hover font-medium">
              {Project.localized_name(p, lang)}
            </.link>
            <% desc = Project.localized_description(p, lang) %>
            <div :if={desc} class="text-xs text-base-content/60 truncate max-w-md">{desc}</div>
          </:col>
          <:col :let={p} label={gettext("Status")}>
            <.project_status_badge project={p} />
          </:col>
          <:col :let={p} label={gettext("Actions")} class="text-right">
            <div class="flex items-center justify-end gap-1">
              <.link navigate={Paths.edit_project(p.uuid)} class="btn btn-ghost btn-xs">
                <.icon name="hero-pencil" class="w-3.5 h-3.5" />
              </.link>
              <button
                type="button"
                phx-click="delete"
                phx-value-uuid={p.uuid}
                phx-disable-with={gettext("Deleting…")}
                data-confirm={gettext("Delete project \"%{name}\"? All assignments will be removed.", name: Project.localized_name(p, lang))}
                class="btn btn-ghost btn-xs text-error"
              >
                <.icon name="hero-trash" class="w-3.5 h-3.5" />
              </button>
            </div>
          </:col>
        </.sortable_table>
      <% end %>
    </div>
    """
  end
end
