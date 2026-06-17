defmodule PhoenixKitProjects.Web.ProjectsLive do
  @moduledoc "List projects."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKitProjects.{Activity, L10n, Paths, Projects, Statuses}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  require Logger

  # Default wrapper class for the standalone admin page. Embedders can
  # override via `live_render(... session: %{"wrapper_class" => "..."})`.
  @default_wrapper_class "flex flex-col w-full px-4 py-6 gap-4"

  # How many rows the list loads at first, and how many more "Load more"
  # appends per click. Hardcoded for now (matches Activity Feed's 50);
  # bump or make session-configurable when a real consumer pushes back.
  @per_batch 50

  # Pagination mode for this LV. `"load_more"` (default) caps the
  # loaded set at @per_batch and shows a footer that bumps the cap
  # on click. Embedders can override via
  # `live_render(... session: %{"pagination" => "off"})` to load
  # every matching row (the original behavior, for hosts that want
  # a one-shot render).
  @default_pagination "load_more"

  @impl true
  def mount(_params, session, socket) do
    WebHelpers.maybe_put_locale(session)

    if connected?(socket), do: ProjectsPubSub.subscribe(ProjectsPubSub.topic_all())

    wrapper_class = Map.get(session, "wrapper_class", @default_wrapper_class)
    pagination = Map.get(session, "pagination", @default_pagination)

    socket =
      socket
      |> assign(
        page_title: gettext("Projects"),
        wrapper_class: wrapper_class,
        pagination: pagination,
        sort_by: :position,
        sort_dir: :asc,
        # Load-more pagination state. `loaded_count` is the current
        # cap on visible rows, bumped by @per_batch on each "Load
        # more" click. `total_count` is the DB total matching the
        # current filter, refreshed on every load. Reset to @per_batch
        # on sort change (NOT on DnD reorder — that would snap the
        # user away from what they just dragged). Both ignored when
        # `pagination == "off"`.
        loaded_count: @per_batch,
        total_count: 0,
        projects: [],
        bulk_enabled?: true,
        # `captured_uuids` is the snapshot taken from the DOM at the
        # moment the user clicks an action button (Reorder, etc.). The
        # live selection lives client-side in the BulkSelectScope hook.
        captured_uuids: [],
        show_reorder_modal: false,
        # Workflow-status filter. Options come from the shared catalog
        # (without provisioning it); `nil` = no filter. Hidden when
        # entities is unavailable or the shared list has no statuses yet.
        statuses_available: Statuses.available?(),
        status_filter: nil,
        status_options: status_filter_options()
      )
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.assign_embed_user(session)
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
    status_slug = socket.assigns[:status_filter]

    base_opts = [
      archived: false,
      current_status_slug: status_slug || :all,
      sort_by: socket.assigns.sort_by,
      sort_dir: socket.assigns.sort_dir
    ]

    list_opts =
      case socket.assigns.pagination do
        "load_more" -> Keyword.put(base_opts, :limit, socket.assigns.loaded_count)
        _ -> base_opts
      end

    projects = Projects.list_projects(list_opts)

    assign(socket,
      projects: projects,
      total_count:
        Projects.count_projects(archived: false, current_status_slug: status_slug || :all),
      # Per-row current status for the list badge, batched to avoid N+1.
      workflow_status_by_project:
        if(socket.assigns.statuses_available,
          do: Statuses.statuses_for_projects(projects),
          else: %{}
        )
    )
  end

  # Shared-catalog statuses as `{label, slug}` for the filter select.
  # Reads only — never provisions the shared entity.
  defp status_filter_options do
    Statuses.shared_catalog_statuses() |> Enum.map(&{&1.label, &1.slug})
  end

  # The workflow-status filter dropdown, shown in the toolbar. Hidden when
  # the entities module is unavailable or the shared list has no statuses
  # yet. A self-contained form so its phx-change doesn't entangle with the
  # sort selector's form.
  defp status_filter_control(assigns) do
    ~H"""
    <form
      :if={@statuses_available and @status_options != []}
      phx-change="filter_status"
      class="flex items-center"
    >
      <.select
        name="status_slug"
        value={@status_filter}
        options={@status_options}
        prompt={gettext("All statuses")}
        class="select-sm"
      />
    </form>
    """
  end

  @sort_fields ~w(position name inserted_at updated_at)a
  @sort_field_strs Enum.map(@sort_fields, &Atom.to_string/1)

  defp sort_options do
    [
      {:position, gettext("Manual")},
      {:name, gettext("Name")},
      {:inserted_at, gettext("Date created")},
      {:updated_at, gettext("Last updated")}
    ]
  end

  @impl true

  # Sort selector fires `sort_form` for both field changes (via the
  # form's phx-change) and direction toggles (via the button's
  # phx-click). One event, two shapes — derive the missing half from
  # current state.
  def handle_event("sort_form", params, socket) do
    field_str = params["sort_by"] || Atom.to_string(socket.assigns.sort_by)
    dir_str = params["sort_dir"] || Atom.to_string(socket.assigns.sort_dir)

    field =
      if field_str in @sort_field_strs,
        do: String.to_existing_atom(field_str),
        else: socket.assigns.sort_by

    dir =
      case dir_str do
        "desc" -> :desc
        _ -> :asc
      end

    {:noreply, apply_sort(socket, field, dir)}
  end

  # Workflow-status filter. Empty value clears it. Reset `loaded_count`
  # (same reasoning as a sort change) so the filtered view starts at the
  # first batch rather than keeping a stale deep page.
  def handle_event("filter_status", %{"status_slug" => slug}, socket) do
    slug = if slug in [nil, ""], do: nil, else: slug
    {:noreply, socket |> assign(status_filter: slug, loaded_count: @per_batch) |> load_projects()}
  end

  # Header-click sort: clicking the active column flips direction,
  # clicking a different column switches to it with :asc.
  def handle_event("toggle_sort", %{"by" => field_str}, socket)
      when field_str in @sort_field_strs do
    field = String.to_existing_atom(field_str)

    dir =
      if field == socket.assigns.sort_by do
        if socket.assigns.sort_dir == :asc, do: :desc, else: :asc
      else
        :asc
      end

    {:noreply, apply_sort(socket, field, dir)}
  end

  def handle_event("toggle_sort", _params, socket), do: {:noreply, socket}

  def handle_event("load_more", _params, socket) do
    {:noreply,
     socket
     |> assign(loaded_count: socket.assigns.loaded_count + @per_batch)
     |> load_projects()}
  end

  # The bulk toolbar's Reorder button pushes this event with the
  # currently-selected UUIDs (gathered from the DOM by the
  # BulkSelectScope hook). Empty (or single-row) selection collapses
  # to :all — the button label is "Reorder all" in those states, and
  # a single-row permute is a no-op, so treating it as :all matches
  # both the visible UI promise and the only sensible action.
  def handle_event("open_reorder_modal", params, socket) do
    uuids =
      case sanitize_uuids(params) do
        list when length(list) < 2 -> []
        list -> list
      end

    {:noreply, assign(socket, show_reorder_modal: true, captured_uuids: uuids)}
  end

  def handle_event("close_reorder_modal", _params, socket) do
    {:noreply, assign(socket, show_reorder_modal: false, captured_uuids: [])}
  end

  # Map gates atom coercion: a crafted payload can't smuggle in an
  # unknown atom (which would crash `String.to_existing_atom` on a
  # garbage string and otherwise leak a fresh atom slot).
  @reorder_strategies %{
    "name_asc" => :name_asc,
    "name_desc" => :name_desc,
    "created_asc" => :created_asc,
    "created_desc" => :created_desc,
    "reverse" => :reverse
  }

  def handle_event("apply_reorder", %{"strategy" => strategy_str}, socket)
      when is_map_key(@reorder_strategies, strategy_str) do
    strategy = Map.fetch!(@reorder_strategies, strategy_str)

    scope =
      case socket.assigns.captured_uuids do
        [] -> :all
        uuids -> uuids
      end

    case Projects.reorder_projects_by(strategy, scope, actor_uuid: Activity.actor_uuid(socket)) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Projects reordered."))
         |> assign(show_reorder_modal: false, captured_uuids: [])
         |> load_projects()}

      {:error, :wrong_scope} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Selection no longer valid; please reselect."))
         |> assign(show_reorder_modal: false, captured_uuids: [])
         |> load_projects()}

      {:error, :duplicate_positions} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Selected rows share positions. Apply \"Reorder all\" first to normalise.")
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not reorder projects."))}
    end
  end

  # Empty submit (no radio chosen) or a forged strategy string. The
  # form has `required` on the radios so this is the fallback for
  # defense in depth.
  def handle_event("apply_reorder", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Pick a strategy before applying."))}
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

  # Sort change resets the load-more cap (otherwise a switch from
  # Name back to Manual would still show only the first @per_batch
  # rows of the new sort, leaving the user confused).
  defp apply_sort(socket, field, dir) do
    socket
    |> assign(sort_by: field, sort_dir: dir, loaded_count: @per_batch)
    |> load_projects()
  end

  defp sanitize_uuids(%{"uuids" => uuids}) when is_list(uuids) do
    Enum.filter(uuids, &is_binary/1)
  end

  defp sanitize_uuids(_), do: []

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

      <%= if @projects == [] do %>
        <.empty_state icon="hero-clipboard-document-list" title={gettext("No projects match.")} />
      <% else %>
        <%!-- DnD applies only in "manual" sort (sort_by=:position).
             Sorting by name / date is a *view* — it doesn't rewrite
             positions, so dragging would be lossy and the handle is
             hidden. Switching back to manual restores the drag handle
             and the position-driven order. --%>
        <% lang = L10n.current_content_lang() %>
        <% draggable? = @sort_by == :position %>

        <.bulk_select_scope
          :if={@bulk_enabled?}
          id="projects-bulk-scope"
          total_count={length(@projects)}
          class="flex flex-col gap-2"
        >
          <%!-- Sort selector lives in the toolbar's leading slot so
               the two read as one control row. Reorder-button gating:
               manual sort → always shown ("Reorder all" / "Reorder N
               selected"); other sorts → only when more than one row
               is selected (a one-row reorder is a no-op, and the
               view's order doesn't reflect positions anyway). --%>
          <.bulk_actions_toolbar
            on_open_reorder="open_reorder_modal"
            reorder_dialog_id="reorder-modal"
            noun_singular={gettext("project")}
            noun_plural={gettext("projects")}
            allow_delete={false}
            reorder_gate={if @sort_by == :position, do: :always, else: :multi}
          >
            <:leading>
              <.sort_selector
                sort_by={@sort_by}
                sort_dir={@sort_dir}
                options={sort_options()}
                manual_field={:position}
              />
              {status_filter_control(assigns)}
            </:leading>
          </.bulk_actions_toolbar>

          {render_projects_table(assigns, draggable?, lang)}
        </.bulk_select_scope>

        <%!-- When bulk-select is disabled, render just the sort
             selector + table (no toolbar wrapper). --%>
        <%= if not @bulk_enabled? do %>
          <div class="flex items-center gap-2">
            <.sort_selector
              sort_by={@sort_by}
              sort_dir={@sort_dir}
              options={sort_options()}
              manual_field={:position}
            />
            {status_filter_control(assigns)}
          </div>
          {render_projects_table(assigns, @sort_by == :position, lang)}
        <% end %>
      <% end %>

      <.reorder_modal
        show={@show_reorder_modal}
        on_close="close_reorder_modal"
        on_apply="apply_reorder"
        selected_count={length(@captured_uuids)}
        total_count={@total_count}
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

  # Extracted because the table is rendered both inside the
  # bulk-select scope and (when bulk is disabled) bare.
  defp render_projects_table(assigns, draggable?, lang) do
    assigns = assign(assigns, draggable?: draggable?, lang: lang)

    ~H"""
    <.table_default id="projects-list" size="sm">
      <.table_default_header>
        <.table_default_row>
          <.drag_handle_header_cell :if={@draggable?} />
          <.bulk_select_header_cell
            :if={@bulk_enabled?}
            id="projects-select-all"
            aria_label={gettext("Select all projects")}
          />
          <.sort_header_cell field={:name} sort={%{by: @sort_by, dir: @sort_dir}}>
            {gettext("Name")}
          </.sort_header_cell>
          <.table_default_header_cell>{gettext("Status")}</.table_default_header_cell>
          <.table_default_header_cell class="text-right whitespace-nowrap">{gettext("Actions")}</.table_default_header_cell>
        </.table_default_row>
      </.table_default_header>
      <.sortable_tbody
        id="projects-list-body"
        enabled={@draggable?}
        event="reorder_projects"
      >
        <.sortable_row :for={p <- @projects} item_id={p.uuid}>
          <.drag_handle_cell :if={@draggable?} />
          <.bulk_select_cell :if={@bulk_enabled?} value={p.uuid} />
          <.table_default_cell class="font-medium">
            <.smart_link
              navigate={Paths.project(p.uuid)}
              emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => p.uuid}}}
              embed_mode={@embed_mode}
              class="link link-hover"
            >
              {Project.localized_name(p, @lang)}
            </.smart_link>
            <% desc = Project.localized_description(p, @lang) %>
            <div :if={desc} class="text-xs text-base-content/60 truncate max-w-md">{desc}</div>
          </.table_default_cell>
          <.table_default_cell>
            <div class="flex flex-wrap items-center gap-1">
              <.project_status_badge project={p} />
              <.workflow_status_badge
                :if={@statuses_available}
                status={Map.get(@workflow_status_by_project, p.uuid)}
              />
            </div>
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
                data-confirm={gettext("Delete project \"%{name}\"? All assignments will be removed.", name: Project.localized_name(p, @lang))}
                icon="hero-trash"
                label={gettext("Delete")}
                variant="error"
              />
            </.table_row_menu>
          </.table_default_cell>
        </.sortable_row>
      </.sortable_tbody>
    </.table_default>

    <.load_more
      :if={@pagination == "load_more"}
      loaded={length(@projects)}
      total={@total_count}
      noun_plural={gettext("projects")}
    />
    """
  end
end
