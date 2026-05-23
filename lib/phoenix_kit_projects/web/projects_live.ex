defmodule PhoenixKitProjects.Web.ProjectsLive do
  @moduledoc "List projects."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKitProjects.{Activity, L10n, Paths, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  require Logger

  # Default wrapper class for the standalone admin page. Embedders can
  # override via `live_render(... session: %{"wrapper_class" => "..."})`.
  @default_wrapper_class "flex flex-col w-full px-4 py-6 gap-4"

  @impl true
  def mount(_params, session, socket) do
    WebHelpers.maybe_put_locale(session)

    if connected?(socket), do: ProjectsPubSub.subscribe(ProjectsPubSub.topic_all())

    wrapper_class = Map.get(session, "wrapper_class", @default_wrapper_class)

    socket =
      socket
      |> assign(
        page_title: gettext("Projects"),
        wrapper_class: wrapper_class,
        show: "visible",
        projects: [],
        bulk_enabled?: true,
        selected_uuids: MapSet.new(),
        show_reorder_modal: false
      )
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.attach_open_embed_hook()

    # Load on both disconnected + connected mount so the first paint has
    # real content. `handle_params/3` is intentionally absent — see
    # dev_docs/embedding_audit.md.
    {:ok, load_projects(socket)}
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
    # Selection is scoped to the current view — switching filters
    # clears it so a user can't accidentally apply a bulk action to
    # rows they can no longer see.
    {:noreply,
     socket
     |> assign(show: s, selected_uuids: MapSet.new())
     |> load_projects()}
  end

  def handle_event("toggle_select", %{"uuid" => uuid}, socket) do
    selected =
      if MapSet.member?(socket.assigns.selected_uuids, uuid) do
        MapSet.delete(socket.assigns.selected_uuids, uuid)
      else
        MapSet.put(socket.assigns.selected_uuids, uuid)
      end

    {:noreply, assign(socket, selected_uuids: selected)}
  end

  def handle_event("toggle_select_all", _params, socket) do
    visible_uuids = Enum.map(socket.assigns.projects, & &1.uuid)
    all_selected? = MapSet.size(socket.assigns.selected_uuids) == length(visible_uuids)

    selected =
      if all_selected? do
        MapSet.new()
      else
        MapSet.new(visible_uuids)
      end

    {:noreply, assign(socket, selected_uuids: selected)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, selected_uuids: MapSet.new())}
  end

  def handle_event("open_reorder_modal", _params, socket) do
    {:noreply, assign(socket, show_reorder_modal: true)}
  end

  def handle_event("close_reorder_modal", _params, socket) do
    {:noreply, assign(socket, show_reorder_modal: false)}
  end

  def handle_event("apply_reorder", %{"strategy" => strategy_str}, socket) do
    strategy = String.to_existing_atom(strategy_str)

    scope =
      case MapSet.size(socket.assigns.selected_uuids) do
        0 -> :all
        _ -> MapSet.to_list(socket.assigns.selected_uuids)
      end

    case Projects.reorder_projects_by(strategy, scope,
           actor_uuid: Activity.actor_uuid(socket)
         ) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Projects reordered."))
         |> assign(show_reorder_modal: false)
         |> load_projects()}

      {:error, :invalid_strategy} ->
        {:noreply, put_flash(socket, :error, gettext("Unknown reorder strategy."))}

      {:error, :wrong_scope} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Selection no longer valid; please reselect."))
         |> assign(show_reorder_modal: false, selected_uuids: MapSet.new())
         |> load_projects()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not reorder projects."))}
    end
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

    {:noreply,
     socket
     |> WebHelpers.notify_deleted(:project, project.uuid)
     |> put_flash(:info, gettext("Project deleted."))
     |> load_projects()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <.page_header title={gettext("Projects")} description={gettext("All projects.")}>
        <:actions>
          <.smart_link
            navigate={Paths.new_project()}
            emit={{PhoenixKitProjects.Web.ProjectFormLive, %{"live_action" => "new"}}}
            embed_mode={@embed_mode}
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New project")}
          </.smart_link>
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

      <%!-- Bulk toolbar: opt-in via `@bulk_enabled?`. Reorder-all is
           always available while the table is non-empty (the modal
           treats "0 selected" as "rewrite everything"). Bulk delete
           is suppressed for now — per-row Delete still lives in the
           row menu. --%>
      <.bulk_actions_toolbar
        :if={@bulk_enabled? and @projects != []}
        selected_count={MapSet.size(@selected_uuids)}
        total_count={length(@projects)}
        on_open_reorder="open_reorder_modal"
        on_bulk_delete="bulk_delete"
        on_clear_selection="clear_selection"
        noun_plural={gettext("projects")}
        allow_delete={false}
      />

      <%= if @projects == [] do %>
        <.empty_state icon="hero-clipboard-document-list" title={gettext("No projects match.")} />
      <% else %>
        <%!-- DnD only applies when the user is viewing the visible
             (non-archived) bucket — reordering a filtered subset
             would write inconsistent positions for the projects that
             aren't currently visible. The hook is gated on
             `@show == "visible"`; archived/all views render the
             same `<.table_default>` without the SortableGrid hook
             (drag handle column hidden too). Mirrors catalogue's
             `<.table_default>` + hand-wired `<tbody>` DnD pattern
             — see `phoenix_kit_catalogue/lib/.../catalogues_live.ex`. --%>
        <% lang = L10n.current_content_lang() %>
        <% draggable? = @show == "visible" %>
        <.table_default id="projects-list" size="sm">
          <.table_default_header>
            <.table_default_row>
              <.table_default_header_cell :if={@bulk_enabled?} class="w-8">
                <.bulk_select_header_checkbox
                  id="projects-select-all"
                  selected_count={MapSet.size(@selected_uuids)}
                  total_count={length(@projects)}
                  on_toggle="toggle_select_all"
                  aria_label={gettext("Select all projects")}
                />
              </.table_default_header_cell>
              <.table_default_header_cell :if={draggable?} class="w-8" />
              <.table_default_header_cell>{gettext("Name")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Status")}</.table_default_header_cell>
              <.table_default_header_cell class="text-right whitespace-nowrap">{gettext("Actions")}</.table_default_header_cell>
            </.table_default_row>
          </.table_default_header>
          <tbody
            id="projects-list-body"
            phx-hook={if draggable?, do: "SortableGrid"}
            data-sortable={if draggable?, do: "true"}
            data-sortable-event="reorder_projects"
            data-sortable-items=".sortable-item"
            data-sortable-handle=".pk-drag-handle"
          >
            <.table_default_row :for={p <- @projects} class="sortable-item" data-id={p.uuid}>
              <.table_default_cell :if={@bulk_enabled?} class="w-8">
                <input
                  type="checkbox"
                  class="checkbox checkbox-sm"
                  checked={MapSet.member?(@selected_uuids, p.uuid)}
                  phx-click="toggle_select"
                  phx-value-uuid={p.uuid}
                />
              </.table_default_cell>
              <.table_default_cell
                :if={draggable?}
                class="pk-drag-handle cursor-grab active:cursor-grabbing text-base-content/40"
                title={gettext("Drag to reorder")}
              >
                <.icon name="hero-bars-3" class="w-4 h-4" />
              </.table_default_cell>
              <.table_default_cell class="font-medium">
                <.smart_link
                  navigate={Paths.project(p.uuid)}
                  emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => p.uuid}}}
                  embed_mode={@embed_mode}
                  class="link link-hover"
                >
                  {Project.localized_name(p, lang)}
                </.smart_link>
                <% desc = Project.localized_description(p, lang) %>
                <div :if={desc} class="text-xs text-base-content/60 truncate max-w-md">{desc}</div>
              </.table_default_cell>
              <.table_default_cell>
                <.project_status_badge project={p} />
              </.table_default_cell>
              <.table_default_cell class="text-right whitespace-nowrap">
                <.table_row_menu id={"project-menu-#{p.uuid}"}>
                  <.smart_menu_link
                    navigate={Paths.edit_project(p.uuid)}
                    emit={{PhoenixKitProjects.Web.ProjectFormLive, %{"live_action" => "edit", "id" => p.uuid}}}
                    embed_mode={@embed_mode}
                    icon="hero-pencil"
                    label={gettext("Edit")}
                  />
                  <.table_row_menu_divider />
                  <.table_row_menu_button
                    phx-click="delete"
                    phx-value-uuid={p.uuid}
                    phx-disable-with={gettext("Deleting…")}
                    data-confirm={gettext("Delete project \"%{name}\"? All assignments will be removed.", name: Project.localized_name(p, lang))}
                    icon="hero-trash"
                    label={gettext("Delete")}
                    variant="error"
                  />
                </.table_row_menu>
              </.table_default_cell>
            </.table_default_row>
          </tbody>
        </.table_default>
      <% end %>

      <.reorder_modal
        show={@show_reorder_modal}
        on_close="close_reorder_modal"
        on_apply="apply_reorder"
        selected_count={MapSet.size(@selected_uuids)}
        total_count={length(@projects)}
        strategies={[
          {"name_asc", gettext("A → Z by name")},
          {"name_desc", gettext("Z → A by name")},
          {"created_desc", gettext("Newest first")},
          {"created_asc", gettext("Oldest first")},
          {"reverse", gettext("Reverse current order")}
        ]}
        noun_singular={gettext("project")}
        noun_plural={gettext("projects")}
      />
    </div>
    """
  end
end
